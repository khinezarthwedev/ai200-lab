# AI-200 lab: Developing AI Cloud Solutions on Azure

A small "AI document search" platform, built to practise the topics of Microsoft exam **AI-200**
(Azure AI Cloud Developer Associate). It follows the shape of the practice case studies
(Proseware and Fabrikam): containerised microservices, vector search, messaging, serverless processing,
secrets, monitoring and automated deployment.

```
Partner ──► App Service webhook ──► Service Bus queue "ai-jobs"
                 (Key Vault reference)

User ──► Container Apps search API ──► Redis cache (10-min TTL) ──► Cosmos DB vector search
              ▲   (KEDA scales on Service Bus messageCount)
              │
Cosmos DB change feed ──► Function: generate embeddings ──► Service Bus "index-updates" ──┘

Your app ──► Event Grid custom topic ──(advanced filter > 0.8, retry, dead-letter)──► Service Bus "high-confidence"

Everything: managed identity · Key Vault · App Configuration (labels, refresh) · OpenTelemetry → App Insights
Delivery: Bicep + GitHub Actions (OIDC, no secrets) · images built inside ACR (ACR Tasks)
```

## Start here

1. [docs/SETUP.md](docs/SETUP.md): one-time setup (Cloud Shell script + GitHub values)
2. [docs/MODULES.md](docs/MODULES.md): what to deploy, what to try, rough cost of each module
3. [QUESTIONS.md](QUESTIONS.md): which files help with which practice questions

## Cost warning (pay-as-you-go)

Defaults are cheap (Service Bus Standard, Cosmos DB serverless). PostgreSQL, Redis, containers, AKS and
**Service Bus Premium** cost money every hour they exist. Run the **teardown** workflow whenever you finish.

## Layout

| Path | What |
|---|---|
| `infra/` | Bicep: `main.bicep` + one file per module |
| `src/search-api/` | FastAPI search API (Container Apps) |
| `src/webhook/` | Partner webhook (App Service container) |
| `src/functions/` | Python Azure Functions (Flex Consumption) |
| `samples/` | Short scripts, one exam topic each |
| `k8s/` | Optional AKS manifests |
| `kql/` | Log queries for App Insights / Log Analytics |
| `.github/workflows/` | `ci`, `deploy`, `acr-tasks`, `teardown` |

## Simplifications (on purpose)

- **Embeddings** come from a small hashing function instead of a real model, so the lab needs no
  Azure OpenAI access and costs nothing extra. Swap `embed()` for a real model call later if you like.
- **PostgreSQL** uses a generated admin password stored only in Key Vault. Production would use
  Microsoft Entra authentication with a managed identity.
- The app identity has **Service Bus Data Owner** because the KEDA scaler needs it to read queue
  length. Production would give the scaler its own identity.
- Everything is in one resource group and one user-assigned identity, to keep it easy to follow.
