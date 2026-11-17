# Which part of the lab helps with which practice questions

Question numbers refer to the 140-question practice PDF. The mapping is based on the keywords in each
question, so treat it as a guide, not an exact list. Some questions cover several topics.

| Topic | Questions | Where in this lab |
|---|---|---|
| **Service Bus** (queues, topics, sessions, DLQ, processor, roles) | 3, 6, 33, 56, 59–63, 65–68, 70, 71, 73, 75, 79, 81, 83, 86–88, 92, 100 | `infra/modules/messaging.bicep`, `samples/01_servicebus_patterns.py`, `src/functions` (`process_alarm`) |
| **Event Grid** (custom/system/partner topics, domains, filters, retry, dead-letter) | 56, 60, 62, 63, 66, 67, 71, 76–78, 80, 86, 89–91 | `messaging.bicep` (event subscription), `samples/02_eventgrid_publish.py`, `on_servicebus_event` |
| **Azure Functions** (triggers, bindings, identity connections, deployment) | 19, 53, 56, 60–62, 64, 66, 69, 71–75, 82, 85, 86, 97, 105–107, 117, 118, 137 | `src/functions/function_app.py`, `infra/modules/functions.bicep` |
| **Cosmos DB** (vector search, indexing, RU, consistency, change feed) | 25, 27, 28, 32, 36, 37, 39–43, 45, 51, 52, 54–56, 122 | `infra/modules/data.bicep`, `samples/04_cosmos_vector_search.py`, `generate_embeddings` |
| **PostgreSQL + pgvector** | 16, 20–23, 26, 33, 38, 44, 46, 116 | `data.bicep`, `samples/05_pgvector.py` |
| **Azure Managed Redis** (cache-aside, TTL, invalidation) | 24, 29, 30, 34, 35, 46–50, 140 | `data.bicep`, `samples/06_redis_cache.py`, `src/search-api/app/main.py` |
| **Container Apps** (revisions, KEDA, scaling, probes) | 3, 5–7, 11, 12, 15, 17–19, 25, 35, 46, 59, 69, 73, 96, 101, 108, 119, 120, 137, 139 | `infra/modules/containers.bicep`, `src/search-api` |
| **AKS** (manifests, KEDA, troubleshooting) | 2, 3, 10, 14, 58, 59, 84, 93, 94, 121, 137 | `infra/modules/aks.bicep`, `k8s/`, `kql/queries.kql` (7–8) |
| **ACR** (quick tasks, source/base-image triggers, pull with identity) | 1, 4, 8, 9, 13, 14, 19, 42, 57, 69, 73, 84, 109–111, 138 | `deploy.yml` (`az acr build`), `acr-tasks.yml`, `core.bicep` |
| **App Service** (containers, Key Vault references) | 10, 102–104, 109–111, 136, 138 | `containers.bicep` (webhook), `src/webhook` |
| **Key Vault** (references, rotation, managed identity) | 15, 28, 64, 93, 97, 98, 100–102, 104–107, 117, 118, 128–130, 132, 138, 140 | `core.bicep`, `samples/08_keyvault_rotation.py` |
| **App Configuration** (labels, refresh, feature flags, Key Vault refs) | 63, 93, 98–100, 107, 113, 126, 128, 140 | `core.bicep`, `src/search-api/app/settings.py`, `samples/03_appconfig_labels_refresh.py` |
| **Monitoring** (OpenTelemetry, App Insights, KQL) | 2, 18, 26, 35, 41, 45, 46, 63, 80, 95, 111, 112, 114, 115, 119, 123–125, 127, 128, 131, 133–135, 137 | `configure_azure_monitor` in every app, `kql/queries.kql` |
| **Identity and RBAC** (managed identity, least privilege) | 15, 28, 62, 71, 86, 89–91, 98, 100, 101, 107, 113, 117, 122, 127, 130 | role assignments in every `infra/modules/*.bicep` file |
| **Pipelines and IaC** (Bicep, GitHub Actions, OIDC) | 79, 84, 85, 102–104, 119, 136, 138 | `infra/main.bicep`, `.github/workflows/`, `scripts/setup-azure.sh` |

## Answer-key notes from our review

Practice-dump answer keys are not always right. These are the ones we discussed:

| Q | PDF key | Our view | Why |
|---|---|---|---|
| 13 | Webhook + source-triggered task | agree, but debatable | some argue quick task; the webhook is what signals the commit |
| 79 | message sessions for FIFO | **queue** | "message sessions" is not an option on the real answer screen |
| 89 | Yes (partner topic) | **No** | partner topics receive events from SaaS partners; the scenario describes an event domain |
| 96 | min-replicas 0 | **1** | Proseware requires minimal cold start; scale-to-zero is a Fabrikam batch requirement |
| 105 | No | No (debatable) | literally meets both goals; the series only accepts Key Vault-based solutions |
