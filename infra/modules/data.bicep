// Data services for AI workloads.
// Exam topics: Cosmos DB for NoSQL (vector search, indexing, consistency, change feed),
// PostgreSQL + pgvector, Azure Managed Redis (cache, TTL, invalidation).

param location string
param prefix string
param suffix string
param tags object
param appIdentityPrincipalId string
param deployerPrincipalId string
param userPrincipalId string = ''
param keyVaultName string

param deployPostgres bool = true
param deployRedis bool = true

@secure()
@description('PostgreSQL admin password. The workflow generates a random one and stores it in Key Vault.')
param postgresAdminPassword string = ''

@description('Your public IP, so you can run the pgvector sample from your PC. Leave empty to skip.')
param clientIp string = ''

// ---------------- Cosmos DB for NoSQL ----------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: 'cosmos-${prefix}-${suffix}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [ { locationName: location, failoverPriority: 0 } ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session' // default; strong costs more RUs, eventual is cheapest
    }
    capabilities: [
      { name: 'EnableServerless' } // pay per RU used: cheapest for a lab
      { name: 'EnableNoSQLVectorSearch' }
    ]
    disableLocalAuth: true // data access with Microsoft Entra ID RBAC only
  }
}

resource db 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmos
  name: 'kb'
  properties: { resource: { id: 'kb' } }
}

resource documents 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: db
  name: 'documents'
  properties: {
    resource: {
      id: 'documents'
      partitionKey: { paths: [ '/category' ], kind: 'Hash' }
      vectorEmbeddingPolicy: {
        vectorEmbeddings: [
          { path: '/embedding', dataType: 'float32', distanceFunction: 'cosine', dimensions: 64 }
        ]
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [ { path: '/*' } ]
        // Excluding the raw vector from the normal index saves RUs on writes (RU optimisation topic).
        excludedPaths: [ { path: '/embedding/*' }, { path: '/"_etag"/?' } ]
        vectorIndexes: [ { path: '/embedding', type: 'flat' } ]
      }
    }
  }
}

resource leases 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: db
  name: 'leases' // used by the change feed processor / Functions Cosmos DB trigger
  properties: {
    resource: {
      id: 'leases'
      partitionKey: { paths: [ '/id' ], kind: 'Hash' }
    }
  }
}

// Cosmos DB has its OWN data-plane RBAC (not Azure RBAC). Built-in Data Contributor:
var cosmosDataContributor = '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'

resource cosmosApp 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, appIdentityPrincipalId, 'contributor')
  properties: {
    principalId: appIdentityPrincipalId
    roleDefinitionId: cosmosDataContributor
    scope: cosmos.id
  }
}

resource cosmosDeployer 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, deployerPrincipalId, 'contributor')
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: cosmosDataContributor
    scope: cosmos.id
  }
}

resource cosmosUser 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (!empty(userPrincipalId)) {
  parent: cosmos
  name: guid(cosmos.id, userPrincipalId, 'contributor')
  properties: {
    principalId: userPrincipalId
    roleDefinitionId: cosmosDataContributor
    scope: cosmos.id
  }
}

// ---------------- PostgreSQL flexible server + pgvector ----------------
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (deployPostgres) {
  name: 'psql-${prefix}-${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard_B1ms', tier: 'Burstable' } // smallest size; real vector workloads need more RAM
  properties: {
    version: '16'
    administratorLogin: 'pgadmin'
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: 32, autoGrow: 'Disabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    authConfig: { activeDirectoryAuth: 'Disabled', passwordAuth: 'Enabled' }
  }
}

// pgvector must be allow-listed before CREATE EXTENSION vector works.
resource pgExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = if (deployPostgres) {
  parent: pg
  name: 'azure.extensions'
  properties: { value: 'VECTOR', source: 'user-override' }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = if (deployPostgres) {
  parent: pg
  name: 'kb'
  dependsOn: [ pgExtensions ]
}

resource pgAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = if (deployPostgres) {
  parent: pg
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
  dependsOn: [ pgDb ]
}

resource pgAllowClient 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = if (deployPostgres && !empty(clientIp)) {
  parent: pg
  name: 'AllowMyIp'
  properties: { startIpAddress: clientIp, endIpAddress: clientIp }
  dependsOn: [ pgAllowAzure ]
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// The connection string lives ONLY in Key Vault; apps read it at runtime via managed identity.
resource pgSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (deployPostgres) {
  parent: kv
  name: 'postgres-connection-string'
  properties: {
    value: deployPostgres ? 'host=${pg!.properties.fullyQualifiedDomainName} port=5432 dbname=kb user=pgadmin password=${postgresAdminPassword} sslmode=require' : ''
  }
}

// ---------------- Azure Managed Redis ----------------
resource redis 'Microsoft.Cache/redisEnterprise@2025-04-01' = if (deployRedis) {
  name: 'redis-${prefix}-${suffix}'
  location: location
  tags: tags
  sku: { name: 'Balanced_B0' } // smallest Azure Managed Redis size
  properties: {
    minimumTlsVersion: '1.2'
  }
}

resource redisDb 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = if (deployRedis) {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'VolatileLRU' // evict keys that have a TTL first
    accessKeysAuthentication: 'Disabled' // Microsoft Entra ID only
  }
}

resource redisAppAccess 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-04-01' = if (deployRedis) {
  parent: redisDb
  name: 'appidentity'
  properties: {
    accessPolicyName: 'default'
    user: { objectId: appIdentityPrincipalId }
  }
}

resource redisUserAccess 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-04-01' = if (deployRedis && !empty(userPrincipalId)) {
  parent: redisDb
  name: 'me'
  properties: {
    accessPolicyName: 'default'
    user: { objectId: userPrincipalId }
  }
  dependsOn: [ redisAppAccess ] // one assignment at a time
}

output cosmosEndpoint string = cosmos.properties.documentEndpoint
output cosmosName string = cosmos.name
output postgresHost string = deployPostgres ? pg!.properties.fullyQualifiedDomainName : ''
output redisHost string = deployRedis ? redis!.properties.hostName : ''
