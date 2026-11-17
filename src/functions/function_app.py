"""Azure Functions (Python v2 programming model, Flex Consumption plan).

Every connection uses the managed identity: settings named "<Connection>__fullyQualifiedNamespace",
"<Connection>__accountEndpoint", ... instead of connection strings (see infra/modules/functions.bicep).

Functions in this app and the exam questions they practise:
  generate_embeddings  Cosmos DB trigger (change feed) -> embedding -> Service Bus   (Proseware case)
  get_settings         HTTP trigger + BLOB INPUT binding (read a JSON file)          (Q82)
  submit_inference     HTTP trigger + SERVICE BUS OUTPUT binding                     (triggers vs bindings)
  process_alarm        Service Bus trigger on a SESSION queue + reply with
                       CorrelationId / ReplyToSessionId                              (Q79, Q87)
  on_servicebus_event  EVENT GRID trigger: "messages waiting, no listener"           (Q86, needs Premium)
"""

import json
import logging
import os

import azure.functions as func
from azure.identity import DefaultAzureCredential

from embeddings import embed

if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    # host.json sets "telemetryMode": "OpenTelemetry"; this exports the worker's traces.
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor()

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
credential = DefaultAzureCredential()
SERVICEBUS_FQDN = os.getenv("SERVICEBUS_FQDN", "")


def _cosmos_documents():
    from azure.cosmos import CosmosClient

    endpoint = os.environ["CosmosConnection__accountEndpoint"]
    return CosmosClient(endpoint, credential).get_database_client("kb").get_container_client("documents")


def _servicebus():
    from azure.servicebus import ServiceBusClient

    return ServiceBusClient(SERVICEBUS_FQDN, credential)


# 1) Cosmos DB change feed: new/updated documents get embeddings automatically ------------------
@app.cosmos_db_trigger(
    arg_name="docs",
    connection="CosmosConnection",
    database_name="kb",
    container_name="documents",
    lease_container_name="leases",
)
def generate_embeddings(docs: func.DocumentList):
    from azure.servicebus import ServiceBusMessage

    container = _cosmos_documents()
    updates = []
    for doc in docs:
        item = dict(doc)
        if "embedding" in item:
            continue  # our own write-back also appears in the change feed: skip it (avoid a loop)
        item["embedding"] = embed(f"{item.get('title', '')} {item.get('text', '')}")
        for system_field in ("_rid", "_self", "_etag", "_attachments", "_ts", "_lsn"):
            item.pop(system_field, None)
        container.upsert_item(item)
        updates.append(
            ServiceBusMessage(
                json.dumps({"id": item["id"], "category": item["category"]}),
                message_id=f"index-{item['id']}",
                content_type="application/json",
            )
        )
    if updates:
        with _servicebus() as sb, sb.get_queue_sender("index-updates") as sender:
            sender.send_messages(updates)  # the search API (and KEDA) react to this queue
        logging.info("Embedded %d documents", len(updates))


# 2) HTTP trigger + blob INPUT binding: the runtime reads the blob for you -----------------------
@app.route(route="settings", methods=["GET"])
@app.blob_input(arg_name="settings_blob", path="config/settings.json", connection="ConfigStorage")
def get_settings(req: func.HttpRequest, settings_blob: str) -> func.HttpResponse:
    if settings_blob is None:
        return func.HttpResponse("Upload config/settings.json first (see samples/README.md)", status_code=404)
    return func.HttpResponse(settings_blob, mimetype="application/json")


# 3) HTTP trigger + Service Bus OUTPUT binding: return value -> message on the queue --------------
@app.route(route="inference", methods=["POST"])
@app.service_bus_queue_output(arg_name="job", connection="ServiceBusConnection", queue_name="ai-jobs")
def submit_inference(req: func.HttpRequest, job: func.Out[str]) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse("Send a JSON body", status_code=400)
    job.set(json.dumps(body))
    return func.HttpResponse("queued", status_code=202)


# 4) Session queue (FIFO per SessionId) + request/reply audit trail ------------------------------
@app.service_bus_queue_trigger(
    arg_name="msg",
    connection="ServiceBusConnection",
    queue_name="alarm-signals",
    is_sessions_enabled=True,
)
def process_alarm(msg: func.ServiceBusMessage):
    from azure.servicebus import ServiceBusMessage

    body = msg.get_body().decode()
    logging.info("Alarm in session %s: %s", msg.session_id, body)
    reply = ServiceBusMessage(
        json.dumps({"ack": True, "alarm": json.loads(body)}),
        correlation_id=msg.message_id,  # "I am the reply to THIS message"        (Q87, F)
        session_id=msg.reply_to_session_id or msg.session_id,  # back into the SAME session (Q87, A)
    )
    with _servicebus() as sb, sb.get_queue_sender("alarm-replies") as sender:
        sender.send_messages(reply)
    # SequenceNumber and DeliveryCount are set by Service Bus and are read-only: we never assign them.


# 5) Event Grid trigger: Service Bus (Premium) says "messages are waiting and nobody is listening" --
@app.event_grid_trigger(arg_name="event")
def on_servicebus_event(event: func.EventGridEvent):
    """The EVENT is only a wake-up call. The real messages stay in the queue until we receive them,
    which is why this function's identity needs 'Azure Service Bus Data Receiver'."""
    data = event.get_json()
    queue = data.get("queueName")
    logging.info("Event %s for queue %s", event.event_type, queue)
    if not queue:
        return
    with _servicebus() as sb, sb.get_queue_receiver(queue) as receiver:
        for message in receiver.receive_messages(max_message_count=20, max_wait_time=5):
            logging.info("Drained message %s", message.message_id)
            receiver.complete_message(message)
