"""Partner webhook (runs on Azure App Service as a container).

Partners POST documents here. We check their API key and put the job on the Service Bus 'ai-jobs' queue.

Exam topics:
- PARTNER_API_KEY comes from an App Service setting that is a KEY VAULT REFERENCE:
      @Microsoft.KeyVault(VaultName=...;SecretName=partner-api-key)
  App Service resolves it at runtime with the managed identity. No secret in the image, code or repo.
- Sending to Service Bus with managed identity (needs the 'Azure Service Bus Data Sender' role).
"""

import json
import os
import secrets
import uuid

from azure.identity import DefaultAzureCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    configure_azure_monitor(logger_name="webhook")

app = FastAPI(title="AI-200 lab partner webhook")
sb = ServiceBusClient(os.environ.get("SERVICEBUS_FQDN", "localhost"), DefaultAzureCredential())


class PartnerDocument(BaseModel):
    title: str
    text: str
    category: str


@app.get("/")
def home():
    # Shows whether the Key Vault reference resolved. If it did NOT, App Service passes the raw
    # "@Microsoft.KeyVault(...)" text through, which is a handy troubleshooting signal.
    value = os.getenv("PARTNER_API_KEY", "")
    return {"keyVaultReferenceResolved": bool(value) and not value.startswith("@Microsoft.KeyVault")}


@app.post("/partner/documents", status_code=202)
def submit(doc: PartnerDocument, x_api_key: str = Header(default="")):
    expected = os.getenv("PARTNER_API_KEY", "")
    if not expected or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="invalid API key")
    job_id = str(uuid.uuid4())
    with sb.get_queue_sender("ai-jobs") as sender:
        sender.send_messages(
            ServiceBusMessage(
                json.dumps({"jobId": job_id, **doc.model_dump()}),
                message_id=job_id,  # unique id: enables duplicate detection and reply correlation
                content_type="application/json",
                subject="partner-document",
            )
        )
    return {"jobId": job_id, "status": "queued"}
