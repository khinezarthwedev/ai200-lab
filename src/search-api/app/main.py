"""Search API (runs in Azure Container Apps).

Two jobs, like the Proseware backend API:
  1. Answer users:  GET /search  -> Redis cache -> Cosmos DB vector search
  2. Process work:  background receiver on the Service Bus 'index-updates' queue
                    (Container Apps scales replicas on this queue with KEDA messageCount)

Exam topics: OpenTelemetry tracing to Azure Monitor, Cosmos DB VectorDistance with a metadata filter,
cache-aside with a 10-minute TTL and invalidation on update, liveness/readiness probes, Service Bus
receive/complete/dead-letter.
"""

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import settings
from .embeddings import embed

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("search-api")

# ---------- OpenTelemetry: instrument + export to Azure Monitor in one call ----------
# Instrumenting = the app RECORDS traces; the exporter SENDS them to Application Insights.
# Trace context (traceparent) is propagated automatically to outgoing HTTP / Service Bus calls.
if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="search-api")

from opentelemetry import trace  # noqa: E402  (import after configure_azure_monitor)

tracer = trace.get_tracer("search-api")

COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT", "")
REDIS_HOST = os.getenv("REDIS_HOST", "")
SERVICEBUS_FQDN = os.getenv("SERVICEBUS_FQDN", "")

_container = None
_redis = None


def cosmos_container():
    global _container
    if _container is None and COSMOS_ENDPOINT:
        from azure.cosmos import CosmosClient

        client = CosmosClient(COSMOS_ENDPOINT, credential=settings.credential)
        _container = client.get_database_client("kb").get_container_client("documents")
    return _container


def redis_client():
    """Azure Managed Redis with Microsoft Entra ID auth (no access keys)."""
    global _redis
    if _redis is None and REDIS_HOST:
        import redis
        from redis_entraid.cred_provider import create_from_default_azure_credential

        provider = create_from_default_azure_credential(("https://redis.azure.com/.default",))
        _redis = redis.Redis(host=REDIS_HOST, port=10000, ssl=True, credential_provider=provider, decode_responses=True)
    return _redis


def cache_key(query: str, category: str) -> str:
    return f"search:{category}:{query.lower().strip()}"


# ---------- Background Service Bus receiver ----------
async def process_index_updates(stop: asyncio.Event):
    """The Python SDK has no 'processor' class like .NET's ServiceBusProcessor
    (create client -> create processor -> register handlers -> start). In Python you loop on a receiver."""
    if not SERVICEBUS_FQDN:
        return
    from azure.identity.aio import DefaultAzureCredential
    from azure.servicebus.aio import ServiceBusClient

    async with DefaultAzureCredential() as cred, ServiceBusClient(SERVICEBUS_FQDN, cred) as client:
        async with client.get_queue_receiver("index-updates") as receiver:
            while not stop.is_set():
                messages = await receiver.receive_messages(max_message_count=10, max_wait_time=5)
                for msg in messages:
                    try:
                        body = json.loads(str(msg))
                        with tracer.start_as_current_span("index-update"):
                            # Data freshness: drop cached results for this category (reactive invalidation).
                            r = redis_client()
                            if r is not None:
                                for key in r.scan_iter(f"search:{body.get('category', '*')}:*"):
                                    r.delete(key)
                            log.info("Index update processed for %s", body.get("id"))
                        await receiver.complete_message(msg)  # done -> removed from the queue
                    except (ValueError, KeyError):
                        # Malformed payload: retrying won't help, so move it aside for inspection.
                        await receiver.dead_letter_message(msg, reason="MalformedPayload")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.load_settings()
    stop = asyncio.Event()
    task = asyncio.create_task(process_index_updates(stop))
    yield
    stop.set()
    task.cancel()


app = FastAPI(title="AI-200 lab search API", lifespan=lifespan)


@app.middleware("http")
async def refresh_config(request, call_next):
    settings.refresh()  # cheap: only checks App Configuration every 30 s
    return await call_next(request)


@app.get("/healthz")
def healthz():
    """Liveness probe: is the process alive? Failing -> the container is restarted."""
    return {"status": "alive"}


@app.get("/ready")
def ready():
    """Readiness probe: can I serve traffic? Failing -> removed from the load balancer, NOT restarted.
    In Kubernetes, failures show up in `kubectl get events` / `kubectl describe pod`."""
    if not settings.is_loaded():
        raise HTTPException(status_code=503, detail="configuration not loaded")
    return {"status": "ready", "modelVersion": settings.get("AI:ModelVersion")}


class Document(BaseModel):
    title: str
    text: str
    category: str


@app.post("/documents")
def add_document(doc: Document):
    """Write a document WITHOUT an embedding. The Function's Cosmos DB change feed trigger
    notices it, generates the embedding, and sends an 'index-updates' message."""
    container = cosmos_container()
    if container is None:
        raise HTTPException(503, "Cosmos DB not configured")
    item = {"id": str(uuid.uuid4()), **doc.model_dump()}
    container.upsert_item(item)
    return item


@app.get("/search")
def search(q: str, category: str):
    ttl = int(settings.get("Search:CacheTtlSeconds") or 600)
    top_k = int(settings.get("Search:TopK") or 5)
    r = redis_client()
    key = cache_key(q, category)

    # Cache-aside pattern: 1) try the cache
    if r is not None and (cached := r.get(key)):
        return {"source": "cache", "results": json.loads(cached)}

    # 2) cache miss -> vector search, filtered by metadata FIRST so fewer vectors are compared (fewer RUs)
    container = cosmos_container()
    if container is None:
        raise HTTPException(503, "Cosmos DB not configured")
    with tracer.start_as_current_span("cosmos-vector-search"):
        results = list(
            container.query_items(
                query=(
                    f"SELECT TOP {top_k} c.id, c.title, c.category, "
                    "VectorDistance(c.embedding, @v) AS score "
                    "FROM c WHERE c.category = @cat AND IS_DEFINED(c.embedding) "
                    "ORDER BY VectorDistance(c.embedding, @v)"
                ),
                parameters=[{"name": "@v", "value": embed(q)}, {"name": "@cat", "value": category}],
                partition_key=category,  # single-partition query: cheaper than cross-partition
            )
        )

    # 3) store in the cache with a TTL (entries expire automatically after 10 minutes)
    if r is not None:
        r.set(key, json.dumps(results), ex=ttl)
    return {"source": "cosmos", "results": results}
