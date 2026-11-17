# Modules: what to deploy, what to try, what it costs

Costs are rough USD estimates for **australiaeast** while the resources exist. Check the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for current prices.
**Always run teardown when you are done.**

| Module (deploy input) | Approx. cost while it exists | What it practises |
|---|---|---|
| core (always) | ~USD 5/month (ACR Basic) + small logs | Managed identity, Key Vault, App Configuration, ACR, App Insights |
| `messaging` | ~USD 10/month (Service Bus Standard) | Queues, topics, sessions, DLQ, Event Grid |
| `data` | Cosmos DB serverless: cents when idle | Vector search, RU, change feed |
| `postgres` | ~USD 20/month | pgvector, HNSW index, metadata filters |
| `redis` | check pricing (Azure Managed Redis B0) | Cache-aside, TTL, invalidation |
| `containers` | ~USD 15-30/month (ACA min 1 replica + App Service B1) | ACA, KEDA, revisions, App Service Key Vault references |
| `functions` | pay per execution (near zero) | Triggers and bindings, identity-based connections |
| `aks` | **per hour** for the node VM | Manifests, probes, troubleshooting |
| `serviceBusSku=Premium` | **hundreds of USD/month** | Service Bus → Event Grid integration (Q86) |

---

## 1. Messaging (`messaging`)

Run `samples/01_servicebus_patterns.py` and `samples/02_eventgrid_publish.py`.

Then look in the portal:
- Service Bus namespace → **Queues** → `ai-jobs` → **Service Bus Explorer** → *Dead-letter* tab.
- Topic `inference-results` → subscription `alerts` → **Filters**: the SQL rule `confidenceScore > 0.8`.
- Event Grid topic → **Event Subscriptions** → `high-confidence-to-servicebus` → **Filters** (advanced filter)
  and **Additional features** (retry policy, dead-lettering).

Try: change the advanced filter to `NumberGreaterThan 0.3` and run sample 02 again.

## 2. Data (`data`, `postgres`, `redis`)

- `samples/04_cosmos_vector_search.py`: compare the RU charge of a single-partition vs cross-partition query.
- `samples/05_pgvector.py`: bulk load first, build the HNSW index after (Fabrikam requirement).
  Add your public IP in the `clientIp` input of the deploy workflow so your PC can connect.
- `samples/06_redis_cache.py`: TTL and invalidation.

Portal: Cosmos DB → **Data Explorer** → `kb/documents` → **Settings**: see the vector policy and the
`/embedding/*` excluded path.

## 3. Containers (`containers`)

The workflow builds both images **inside ACR** with a quick task (`az acr build`), then deploys:
- **Container Apps** `ca-search-api`: open **Scale** to see the HTTP rule and the KEDA `azure-servicebus`
  rule with `messageCount: 5`, min replicas 1. Open **Revisions** to see multiple revisions.
- **App Service** `app-ai200-webhook-…`: **Environment variables** shows `PARTNER_API_KEY` as a
  **Key Vault reference** (green tick = resolved). Browse to the site root: it reports whether it resolved.

Try:
```bash
URL=<SEARCH_API_URL from lab.env>
curl -X POST $URL/documents -H 'content-type: application/json' \
  -d '{"title":"Reset a router","text":"unplug it and wait","category":"support"}'
curl "$URL/search?q=router&category=support"     # first: source=cosmos
curl "$URL/search?q=router&category=support"     # second: source=cache (if redis is deployed)
```
The first search may return nothing until the Function app adds embeddings (deploy `functions` too).

ACR Tasks with triggers: run the **acr-tasks** workflow (needs the `ACR_TASK_GIT_PAT` secret, see the
comments at the top of `.github/workflows/acr-tasks.yml`). After that, every commit to `main` that changes
`src/search-api` builds a new image in ACR (Q13, Q84).

## 4. Functions (`functions`, needs `data` + `messaging`)

Portal → Function app → **Functions** shows 5 functions. Then:
- `samples/07_upload_blob_settings.py`, then call `/api/settings?code=<key>` (blob **input** binding, Q82).
- POST to `/api/inference?code=<key>`: the Service Bus **output** binding puts it on `ai-jobs`.
- Sample 01 part D/E: the session-triggered `process_alarm` replies with CorrelationId (Q87).
- `on_servicebus_event` only fires with **Service Bus Premium** plus an Event Grid subscription on the
  namespace (portal: Service Bus namespace → **Events** → **+ Event Subscription** → Azure Function).

## 5. Monitoring (any module with apps)

Application Insights → **Logs**, paste queries from [`kql/queries.kql`](../kql/queries.kql).
Application Insights → **Transaction search** → click a request → see the end-to-end trace across
Container Apps, Service Bus and Functions (trace correlation, Q95).

## 6. App Configuration and Key Vault (core)

- `samples/03_appconfig_labels_refresh.py`: labels per environment (Q99) and sentinel refresh (Q98).
- `samples/08_keyvault_rotation.py`: new secret version; versionless references pick it up (Q97).

## 7. AKS (`aks`, optional, expensive)

```bash
az aks get-credentials -g rg-ai200-lab -n <AKS_NAME>
sed -i "s#<ACR_LOGIN_SERVER>#<your ACR login server>#" k8s/batch-reembed.yaml
kubectl apply -f k8s/batch-reembed.yaml
kubectl get pods; kubectl get events --sort-by=.lastTimestamp
```
Then break things on purpose and find the cause (Q94):

| Break it | How to find it |
|---|---|
| Change `readinessProbe.path` to `/nope`, re-apply | `kubectl get events` → *Readiness probe failed: 404* |
| Change the Service `selector` to `app: wrong` | `kubectl get endpoints search-api` → no addresses |
| Change the image tag to one that doesn't exist | `kubectl describe pod` → *ErrImagePull* |
| Set `APP_ENV` to `production` and `AZURE_APPCONFIG_ENDPOINT` to a wrong URL | Pod restarts repeatedly: `kubectl logs <pod> --previous` shows the startup error |

**Run teardown afterwards.**
