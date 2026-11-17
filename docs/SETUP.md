# Setup (one time, about 15 minutes)

You do three things: run one script in Azure Cloud Shell, add a few values in GitHub, and click **Run workflow**.
No passwords or keys are stored anywhere: GitHub signs in to Azure with **OpenID Connect (federated credential)**.

## 0. Protect your wallet first (pay-as-you-go)

Azure portal → **Cost Management + Billing** → **Budgets** → **Add**:
scope = your subscription, amount = e.g. **NZD 50 / month**, alert at **50% and 90%** to your email.
A budget only *alerts*; it does not stop resources. The **teardown** workflow is what stops the spending.

## 1. Run the setup script in Azure Cloud Shell

1. Open <https://shell.azure.com> and choose **Bash**.
2. Copy the whole of [`scripts/setup-azure.sh`](../scripts/setup-azure.sh), paste it, press Enter.
3. At the end it prints 3 **secrets** and 4 **variables**. Keep that window open.

What the script does, and the exam idea behind each step:

| Step | Why | Exam link |
|---|---|---|
| Registers resource providers | A new subscription must register `Microsoft.EventGrid` etc. before use | Q77 |
| Creates `rg-ai200-lab` | Everything lives in one group, so it is easy to clean up | |
| App registration + service principal | The identity GitHub Actions signs in as | Q85 |
| Federated credential (OIDC) | GitHub proves who it is with a short-lived token: no client secret to leak | Q85, Q105 |
| Contributor + RBAC Administrator on the **resource group only** | Least privilege: enough to deploy and to create role assignments | Q86 |

## 2. Add the values in GitHub

Repo → **Settings** → **Secrets and variables** → **Actions**

- **Secrets** tab → *New repository secret*: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- **Variables** tab → *New repository variable*: `AZURE_RESOURCE_GROUP`, `AZURE_LOCATION`,
  `AZURE_DEPLOYER_OBJECT_ID`, `AZURE_USER_OBJECT_ID`

The first workflow run creates a GitHub **environment** called `lab`; the federated credential trusts only that environment.

## 3. Deploy

Repo → **Actions** → **deploy** → **Run workflow**. Start with the defaults (messaging + Cosmos DB serverless:
cheap). Turn on more modules later, one at a time (see [MODULES.md](MODULES.md)).

When the run finishes, open it and download the **lab-env** artifact. It contains `lab.env` with resource
names and endpoints (nothing secret).

## 4. Run the samples

Easiest place: **Azure Cloud Shell**. Cloud Shell's automatic sign-in can NOT get tokens for
Service Bus, Cosmos DB or App Configuration ("AudienceNotSupported"), so sign in once yourself:

```bash
az login --use-device-code          # open the link, enter the code, pick your account
az account set --subscription <your-subscription-id>
git clone https://github.com/khinezarthwedev/ai200-lab.git
cd ai200-lab/samples
# upload lab.env with the Cloud Shell "Upload" button, then:
mv ~/lab.env .
pip install --user -r requirements.txt
python 01_servicebus_patterns.py
```

On your own PC: install Python 3.11+ and the Azure CLI, run `az login`, then the same commands.
Role assignments can take **a few minutes** to apply after a deploy. If you see `AuthorizationFailed`
or `403`, wait 5 minutes and try again.

## 5. Stop paying: teardown

Repo → **Actions** → **teardown** → **Run workflow** → type `DELETE`.
It deletes every resource in `rg-ai200-lab` (the empty group and its role assignments stay, so you can
deploy again later) and purges the soft-deleted Key Vault.

Do this **every time you finish practising**, especially after deploying PostgreSQL, Redis,
containers, AKS or Service Bus Premium.
