// Container hosting.
// Exam topics: Azure Container Apps (revisions, KEDA scaling on Service Bus messageCount, min replicas,
// secrets/env vars), App Service for containers (Key Vault references in app settings), ACR pull with
// managed identity.

param location string
param prefix string
param suffix string
param tags object
param identityId string
param identityClientId string
param logAnalyticsId string
param acrLoginServer string
param appConfigEndpoint string
param appInsightsConnectionString string
param keyVaultName string
param serviceBusFqdn string
param cosmosEndpoint string = ''
param redisHost string = ''

@description('Image for the search API. The workflow builds it with an ACR quick task and passes the tag here.')
param searchApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param webhookImage string = 'mcr.microsoft.com/appsvc/staticsite:latest'
param useAcrImages bool = false

@allowed([ 'test', 'staging', 'production' ])
param appEnv string = 'test'

// ---------------- Container Apps ----------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsId, '/'))
}

resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-${prefix}-${suffix}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics' // ContainerAppConsoleLogs_CL / ContainerAppSystemLogs_CL for KQL
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource searchApi 'Microsoft.App/containerApps@2025-01-01' = {
  name: 'ca-search-api'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Multiple' // lets you split traffic between revisions (blue/green)
      ingress: {
        external: true
        targetPort: useAcrImages ? 8000 : 80
        transport: 'auto'
      }
      registries: useAcrImages ? [
        { server: acrLoginServer, identity: identityId } // pull with managed identity, no admin password
      ] : []
      secrets: [
        { name: 'appinsights-conn', value: appInsightsConnectionString }
      ]
    }
    template: {
      containers: [
        {
          name: 'search-api'
          image: searchApiImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'APP_ENV', value: appEnv }
            { name: 'AZURE_APPCONFIG_ENDPOINT', value: appConfigEndpoint }
            { name: 'SERVICEBUS_FQDN', value: serviceBusFqdn }
            { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
            { name: 'REDIS_HOST', value: redisHost }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-conn' }
          ]
          probes: useAcrImages ? [
            { type: 'Liveness', httpGet: { path: '/healthz', port: 8000 }, periodSeconds: 30 }
            { type: 'Readiness', httpGet: { path: '/ready', port: 8000 }, periodSeconds: 10 }
          ] : []
        }
      ]
      scale: {
        // min 1 = no cold start for user searches (Proseware: "cold start delay must be minimized").
        // Use 0 when cost matters more than latency (scale to zero).
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-load'
            http: { metadata: { concurrentRequests: '50' } }
          }
          {
            // KEDA azure-servicebus scaler: messageCount (queueLength is the Azure Queue Storage scaler)
            name: 'index-updates-backlog'
            custom: {
              type: 'azure-servicebus'
              identity: identityId
              metadata: {
                namespace: split(serviceBusFqdn, '.')[0]
                queueName: 'index-updates'
                messageCount: '5'
              }
            }
          }
        ]
      }
    }
  }
}

// ---------------- App Service (partner webhook) ----------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${prefix}-${suffix}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: 'B1', tier: 'Basic' }
  properties: { reserved: true }
}

resource webhook 'Microsoft.Web/sites@2024-04-01' = {
  name: 'app-${prefix}-webhook-${suffix}'
  location: location
  tags: tags
  kind: 'app,linux,container'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: identityId // which identity resolves @Microsoft.KeyVault(...) references
    siteConfig: {
      linuxFxVersion: 'DOCKER|${webhookImage}'
      acrUseManagedIdentityCreds: useAcrImages
      acrUserManagedIdentityID: useAcrImages ? identityClientId : null
      minTlsVersion: '1.2'
      appSettings: [
        // Key Vault REFERENCE: App Service resolves the secret at runtime. Nothing secret is stored here.
        { name: 'PARTNER_API_KEY', value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=partner-api-key)' }
        { name: 'AZURE_CLIENT_ID', value: identityClientId }
        { name: 'SERVICEBUS_FQDN', value: serviceBusFqdn }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'WEBSITES_PORT', value: '8000' }
      ]
    }
  }
}

output searchApiUrl string = 'https://${searchApi.properties.configuration.ingress.fqdn}'
output searchApiName string = searchApi.name
output webhookUrl string = 'https://${webhook.properties.defaultHostName}'
output webhookName string = webhook.name
