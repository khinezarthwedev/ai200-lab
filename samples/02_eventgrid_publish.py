"""Publish your OWN events to an Event Grid CUSTOM topic.  python 02_eventgrid_publish.py

The event subscription (infra/modules/messaging.bicep) has:
  - an ADVANCED filter: data.confidenceScore > 0.8          (Q76, Q78)
  - a retry policy: max delivery attempts 5, TTL 60 minutes (Q76)
  - a dead-letter destination: blob container eg-deadletter (Q76)
It routes matching events to the Service Bus queue 'high-confidence'.
"""

import time

from azure.core.messaging import CloudEvent
from azure.eventgrid import EventGridPublisherClient
from azure.servicebus import ServiceBusClient

from common import banner, credential, load_env, need

load_env()
cred = credential()

banner("Publish two events to the custom topic (endpoint = topic name is in the URL)")
publisher = EventGridPublisherClient(need("EVENTGRID_TOPIC_ENDPOINT"), cred)  # Entra ID, no access key
publisher.send(
    [
        CloudEvent(source="/models/v1", type="AI.InferenceCompleted", data={"result": "cat", "confidenceScore": 0.95}),
        CloudEvent(source="/models/v1", type="AI.InferenceCompleted", data={"result": "dog", "confidenceScore": 0.40}),
    ]
)
print("Sent: confidence 0.95 and 0.40")

banner("Read the 'high-confidence' queue: only the 0.95 event should arrive")
time.sleep(10)  # Event Grid delivery is near-real-time, give it a moment
with ServiceBusClient(need("SERVICEBUS_FQDN"), cred) as sb:
    with sb.get_queue_receiver("high-confidence", max_wait_time=15) as receiver:
        for msg in receiver.receive_messages(max_message_count=10):
            print("delivered:", str(msg))
            receiver.complete_message(msg)
