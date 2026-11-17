// Core resources shared by every module.
// Exam topics: managed identity, Key Vault (RBAC), App Configuration (labels, Key Vault references,
// sentinel key), Azure Container Registry, Log Analytics + Application Insights (KQL, OpenTelemetry).

param location string
param prefix string
param suffix string
@description('Object ID of the GitHub Actions service principal (needs data-plane roles to seed values).')
param deployerPrincipalId string
@description('Object ID of your own Microsoft Entra user, so you can run the samples locally. Leave empty to skip.')
param userPrincipalId string = ''
param tags object

// ---------- Built-in role definition IDs (least privilege) ----------
var roles = {
  acrPull: '7f951dff-4ed7-4c3b-9b02-e4ae9f6bbd6d'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  appConfigDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
  appConfigDataOwner: '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

// ---------- User-assigned managed identity used by every app ----------
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${prefix}-apps'
  location: location
  tags: tags
}

// ---------- Monitoring ----------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${prefix}-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 } // cost guard for pay-as-you-go
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${prefix}-${suffix}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------- Container registry (ACR Tasks run inside the registry) ----------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${prefix}${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false // use managed identity + AcrPull, never admin keys
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, appIdentity.id, roles.acrPull)
  scope: acr
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
  }
}

// ---------- Key Vault (RBAC model) ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${prefix}-${suffix}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource kvAppReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, appIdentity.id, roles.keyVaultSecretsUser)
  scope: kv
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
  }
}

resource kvDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, deployerPrincipalId, roles.keyVaultSecretsOfficer)
  scope: kv
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
  }
}

resource kvUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(kv.id, userPrincipalId, roles.keyVaultSecretsOfficer)
  scope: kv
  properties: {
    principalId: userPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
  }
}

// A demo secret. In real life this value would never be in a template; here it is a harmless sample.
resource partnerKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'partner-api-key'
  properties: {
    value: 'demo-${uniqueString(kv.id, 'partner')}'
  }
}

// ---------- App Configuration ----------
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: 'appcs-${prefix}-${suffix}'
  location: location
  tags: tags
  sku: { name: 'free' } // one free store per subscription; switch to 'standard' if you already have one
  properties: {
    disableLocalAuth: false // ARM seeds key-values below; apps still use managed identity
  }
}

resource appConfigAppReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, appIdentity.id, roles.appConfigDataReader)
  scope: appConfig
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appConfigDataReader)
  }
}

resource appConfigUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(appConfig.id, userPrincipalId, roles.appConfigDataOwner)
  scope: appConfig
  properties: {
    principalId: userPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appConfigDataOwner)
  }
}

// Same key, different value per environment = LABELS (Q99). Name format is 'key$label'.
var labelledSettings = [
  { key: 'AI:ModelVersion', label: 'test', value: 'v1-test' }
  { key: 'AI:ModelVersion', label: 'staging', value: 'v2-rc' }
  { key: 'AI:ModelVersion', label: 'production', value: 'v2' }
  { key: 'Search:TopK', label: '', value: '5' } // no label = shared default
  { key: 'Search:CacheTtlSeconds', label: '', value: '600' } // Redis entries expire after 10 minutes
  { key: 'Sentinel', label: '', value: '1' } // bump this LAST to trigger dynamic refresh (Q98)
]

resource settings 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-05-01' = [for s in labelledSettings: {
  parent: appConfig
  name: empty(s.label) ? s.key : '${s.key}$${s.label}'
  properties: {
    value: s.value
  }
}]

// Feature flag
resource newRanking 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-05-01' = {
  parent: appConfig
  name: '.appconfig.featureflag~2FNewRanking'
  properties: {
    contentType: 'application/vnd.microsoft.appconfig.ff+json;charset=utf-8'
    value: '{"id":"NewRanking","description":"Use the new ranking logic","enabled":false,"conditions":{"client_filters":[]}}'
  }
}

// Key Vault REFERENCE: App Configuration stores only a pointer, never the secret (Q98).
resource kvRef 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-05-01' = {
  parent: appConfig
  name: 'Partner:ApiKey'
  properties: {
    contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
    value: '{"uri":"${partnerKey.properties.secretUri}"}'
  }
}

// ---------- Storage (Functions host, blob input binding, Event Grid dead-letter) ----------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${prefix}${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // identity-based access only
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in [ 'config', 'eg-deadletter', 'func-deploy', 'uploads' ]: {
  parent: blobSvc
  name: c
}]

var storageRolesForApp = [ roles.storageBlobDataOwner, roles.storageQueueDataContributor, roles.storageTableDataContributor ]

resource storageAppRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for r in storageRolesForApp: {
  name: guid(storage.id, appIdentity.id, r)
  scope: storage
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', r)
  }
}]

resource storageDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, deployerPrincipalId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
  }
}

resource storageUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(storage.id, userPrincipalId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    principalId: userPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
  }
}

resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, appIdentity.id, roles.monitoringMetricsPublisher)
  scope: appInsights
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringMetricsPublisher)
  }
}

output identityId string = appIdentity.id
output identityClientId string = appIdentity.properties.clientId
output identityPrincipalId string = appIdentity.properties.principalId
output logAnalyticsId string = logs.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output appConfigName string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint
output storageName string = storage.name
output storageId string = storage.id
output blobEndpoint string = storage.properties.primaryEndpoints.blob
