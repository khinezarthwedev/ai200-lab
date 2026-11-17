"""Service Bus patterns, one by one.  python 01_servicebus_patterns.py

  A. Queue: one sender -> one receiver; complete removes the message
  B. Dead-letter queue: a bad message is moved aside and can be inspected        (Q79, Q81)
  C. Topic + subscriptions: every subscription gets ITS OWN COPY (fan-out)       (Q83)
     plus a subscription RULE that filters which messages arrive
  D. Sessions: guaranteed FIFO order per SessionId                               (Q79)
  E. Reply trail: MessageId -> CorrelationId, SessionId -> ReplyToSessionId      (Q87)
"""

import json
import time

from azure.servicebus import ServiceBusClient, ServiceBusMessage, ServiceBusSubQueue

from common import banner, credential, load_env, need

load_env()
client = ServiceBusClient(need("SERVICEBUS_FQDN"), credential())

with client:
    banner("A. Queue: send 1 message, receive it, complete it")
    with client.get_queue_sender("ai-jobs") as sender:
        sender.send_messages(ServiceBusMessage(json.dumps({"job": 1}), message_id="job-1"))
    with client.get_queue_receiver("ai-jobs", max_wait_time=5) as receiver:
        for msg in receiver.receive_messages(max_message_count=10):
            print("received:", str(msg), "| delivery count:", msg.delivery_count)
            receiver.complete_message(msg)  # done -> removed from the queue

    banner("B. Dead-letter a malformed message, then read the $DeadLetterQueue sub-queue")
    with client.get_queue_sender("ai-jobs") as sender:
        sender.send_messages(ServiceBusMessage("this is not json", message_id="bad-1"))
    with client.get_queue_receiver("ai-jobs", max_wait_time=5) as receiver:
        for msg in receiver.receive_messages(max_message_count=10):
            try:
                json.loads(str(msg))
                receiver.complete_message(msg)
            except ValueError:
                receiver.dead_letter_message(msg, reason="MalformedPayload", error_description="not JSON")
                print("dead-lettered:", msg.message_id)
    with client.get_queue_receiver("ai-jobs", sub_queue=ServiceBusSubQueue.DEAD_LETTER, max_wait_time=5) as dlq:
        for msg in dlq.receive_messages(max_message_count=10):
            print("in DLQ:", msg.message_id, "| reason:", msg.dead_letter_reason)
            dlq.complete_message(msg)  # clean up after inspecting

    banner("C. Topic fan-out: publish ONCE, every subscription gets a copy")
    with client.get_topic_sender("inference-results") as sender:
        for score in (0.95, 0.40):
            sender.send_messages(
                ServiceBusMessage(
                    json.dumps({"result": "cat", "confidenceScore": score}),
                    application_properties={"confidenceScore": score},  # rules filter on properties
                )
            )
    time.sleep(2)
    for sub in ("audit", "dashboard", "alerts"):
        with client.get_subscription_receiver("inference-results", sub, max_wait_time=5) as receiver:
            got = receiver.receive_messages(max_message_count=10)
            print(f"subscription '{sub}' received {len(got)} message(s):", [str(m) for m in got])
            for m in got:
                receiver.complete_message(m)
    print("-> 'alerts' has the rule confidenceScore > 0.8, so it only got the 0.95 message.")

    banner("D. Sessions: messages with the same SessionId are delivered in order (FIFO)")
    with client.get_queue_sender("alarm-signals") as sender:
        for step in ("start siren", "start lights", "stop siren"):
            sender.send_messages(ServiceBusMessage(step, session_id="zone-5", reply_to_session_id="zone-5"))
    print("Sent 3 alarm signals in session zone-5.")
    print("If the Function app is deployed, process_alarm handles them and replies (part E).")
    print("Otherwise we read them here:")
    try:
        with client.get_queue_receiver("alarm-signals", session_id="zone-5", max_wait_time=5) as receiver:
            for msg in receiver.receive_messages(max_message_count=10):
                print("  seq", msg.sequence_number, "->", str(msg))
                receiver.complete_message(msg)
    except Exception as exc:  # session already locked by the Function app
        print("  (session is being processed by the Function app:", type(exc).__name__, ")")

    banner("E. Reply trail on 'alarm-replies' (only if the Function app is deployed)")
    try:
        with client.get_queue_receiver("alarm-replies", session_id="zone-5", max_wait_time=10) as receiver:
            for msg in receiver.receive_messages(max_message_count=10):
                print(f"  reply id={msg.message_id} correlation_id={msg.correlation_id} session={msg.session_id}")
                receiver.complete_message(msg)
    except Exception as exc:
        print("  no replies yet:", type(exc).__name__)
