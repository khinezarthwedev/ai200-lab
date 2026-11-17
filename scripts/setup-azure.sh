#!/usr/bin/env bash
# ONE-TIME Azure setup. Paste into Azure Cloud Shell (Bash) at https://shell.azure.com
# Creates: resource group, an app registration that GitHub Actions signs in as (OIDC, no secret),
# least-privilege roles on the resource group, and registers the resource providers.
set -euo pipefail

SUB="9784e0ae-4980-4e72-8797-59eaa055cab1"
RG="rg-ai200-lab"
LOC="australiaeast"
REPO="khinezarthwedev/ai200-lab"
APP_NAME="gh-ai200-lab"

az account set --subscription "$SUB"
TENANT=$(az account show --query tenantId -o tsv)

echo "== 1. Register resource providers (a NEW subscription must do this first - remember Q77)"
for p in Microsoft.EventGrid Microsoft.ServiceBus Microsoft.DocumentDB Microsoft.DBforPostgreSQL \
         Microsoft.Cache Microsoft.App Microsoft.ContainerRegistry Microsoft.ContainerService \
         Microsoft.Web Microsoft.OperationalInsights Microsoft.Insights Microsoft.AppConfiguration \
         Microsoft.KeyVault Microsoft.Storage Microsoft.ManagedIdentity; do
  az provider register --namespace "$p" --output none
done

echo "== 2. Resource group"
az group create --name "$RG" --location "$LOC" --tags project=ai200-lab --output none

echo "== 3. App registration + service principal for GitHub Actions"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
fi
az ad sp show --id "$APP_ID" --output none 2>/dev/null || az ad sp create --id "$APP_ID" --output none
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo "== 4. Federated credential: trust GitHub's OIDC token for this repo's 'lab' environment (no secret)"
az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"github-lab-environment\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${REPO}:environment:lab\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}" --output none 2>/dev/null || echo "   (federated credential already exists)"

echo "== 5. Least-privilege roles, scoped to the resource group only"
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"
# Contributor: create resources. RBAC Administrator: create the role assignments in the Bicep files.
# (Owner would also work but grants more than needed.)
for ROLE in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
    --role "$ROLE" --scope "$SCOPE" --output none
done
# Key Vault Contributor at subscription level only so the teardown workflow can PURGE the soft-deleted
# vault (purge is a subscription-level operation). Remove this line if you prefer to purge by hand.
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Contributor" --scope "/subscriptions/$SUB" --output none

USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

cat <<OUT

==========================================================================================
Done. Add these in GitHub: repo > Settings > Secrets and variables > Actions

  SECRETS tab  (New repository secret)
    AZURE_CLIENT_ID        = $APP_ID
    AZURE_TENANT_ID        = $TENANT
    AZURE_SUBSCRIPTION_ID  = $SUB

  VARIABLES tab  (New repository variable)
    AZURE_RESOURCE_GROUP      = $RG
    AZURE_LOCATION            = $LOC
    AZURE_DEPLOYER_OBJECT_ID  = $SP_OBJECT_ID
    AZURE_USER_OBJECT_ID      = $USER_OBJECT_ID

None of these are passwords: OIDC means GitHub never stores an Azure secret.
==========================================================================================
OUT
