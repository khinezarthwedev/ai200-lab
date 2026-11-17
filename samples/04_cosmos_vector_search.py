"""Cosmos DB for NoSQL: vector search with a metadata filter, RU charges, consistency.
python 04_cosmos_vector_search.py

Exam ideas: filter on metadata (and the partition key) BEFORE vector comparison = fewer RUs;
exclude the vector path from the normal index; single-partition queries are cheaper.
"""

import uuid

from azure.cosmos import CosmosClient

from common import banner, credential, load_env, need
from embeddings import embed

load_env()
container = CosmosClient(need("COSMOS_ENDPOINT"), credential()).get_database_client("kb").get_container_client("documents")


def ru() -> str:
    return container.client_connection.last_response_headers.get("x-ms-request-charge", "?")


banner("Insert documents WITH embeddings (the Function app would normally add them)")
docs = [
    ("Reset a router", "unplug the router wait thirty seconds and plug it back in", "support"),
    ("Wi-Fi is slow", "move the router closer and restart the wifi", "support"),
    ("Quarterly revenue", "revenue grew ten percent in the third quarter", "finance"),
]
for title, text, category in docs:
    container.upsert_item({"id": str(uuid.uuid4()), "title": title, "text": text, "category": category,
                           "embedding": embed(f"{title} {text}")})
    print(f"upserted '{title}' ({ru()} RU)")

banner("Vector search: TOP 2 closest to 'restart my wifi router' in category 'support'")
query = (
    "SELECT TOP 2 c.title, VectorDistance(c.embedding, @v) AS score FROM c "
    "WHERE c.category = @cat ORDER BY VectorDistance(c.embedding, @v)"
)
params = [{"name": "@v", "value": embed("restart my wifi router")}, {"name": "@cat", "value": "support"}]
for row in container.query_items(query, parameters=params, partition_key="support"):
    print(row)
print("request charge:", ru(), "RU  (single partition)")

banner("Same query across ALL partitions (no partition key) usually costs more")
list(container.query_items(query, parameters=params, enable_cross_partition_query=True))
print("request charge:", ru(), "RU  (cross-partition)")
