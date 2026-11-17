// Entry point. Deploy with GitHub Actions (.github/workflows/deploy.yml) into one resource group.
// Turn modules on/off to control cost. Everything is deleted together by the teardown workflow.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
@maxLength(8)
param prefix string = 'ai200'

param deployerPrincipalId string
param userPrincipalId string = ''

param deployMessaging bool = true
param deployData bool = true
param deployPostgres bool = false
param deployRedis bool = false
param deployContainers bool = false
param deployFunctions bool = false
param deployAks bool = false

@allowed([ 'Standard', 'Premium' ])
param serviceBusSku string = 'Standard'

@secure()
param postgresAdminPassword string = ''
param clientIp string = ''

param searchApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param webhookImage string = 'mcr.microsoft.com/appsvc/staticsite:latest'
param useAcrImages bool = false

@allowed([ 'test', 'staging', 'production' ])
param appEnv string = 'test'

var suffix = take(uniqueString(resourceGroup().id), 6)
var tags = { project: 'ai200-lab', purpose: 'exam-practice' }

module core 'modules/core.bicep' = {
  name: 'core'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    deployerPrincipalId: deployerPrincipalId
    userPrincipalId: userPrincipalId
  }
}

module messaging 'modules/messaging.bicep' = if (deployMessaging || deployContainers || deployFunctions) {
  name: 'messaging'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    appIdentityPrincipalId: core.outputs.identityPrincipalId
    deployerPrincipalId: deployerPrincipalId
    userPrincipalId: userPrincipalId
    storageId: core.outputs.storageId
    serviceBusSku: serviceBusSku
  }
}

module data 'modules/data.bicep' = if (deployData || deployFunctions) {
  name: 'data'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    appIdentityPrincipalId: core.outputs.identityPrincipalId
    deployerPrincipalId: deployerPrincipalId
    userPrincipalId: userPrincipalId
    keyVaultName: core.outputs.keyVaultName
    deployPostgres: deployPostgres
    deployRedis: deployRedis
    postgresAdminPassword: postgresAdminPassword
    clientIp: clientIp
  }
}

module containers 'modules/containers.bicep' = if (deployContainers) {
  name: 'containers'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    identityId: core.outputs.identityId
    identityClientId: core.outputs.identityClientId
    logAnalyticsId: core.outputs.logAnalyticsId
    acrLoginServer: core.outputs.acrLoginServer
    appConfigEndpoint: core.outputs.appConfigEndpoint
    appInsightsConnectionString: core.outputs.appInsightsConnectionString
    keyVaultName: core.outputs.keyVaultName
    serviceBusFqdn: messaging!.outputs.serviceBusFqdn
    cosmosEndpoint: (deployData || deployFunctions) ? data!.outputs.cosmosEndpoint : ''
    redisHost: (deployData || deployFunctions) ? data!.outputs.redisHost : ''
    searchApiImage: searchApiImage
    webhookImage: webhookImage
    useAcrImages: useAcrImages
    appEnv: appEnv
  }
}

module functions 'modules/functions.bicep' = if (deployFunctions) {
  name: 'functions'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    identityId: core.outputs.identityId
    identityClientId: core.outputs.identityClientId
    storageName: core.outputs.storageName
    blobEndpoint: core.outputs.blobEndpoint
    appInsightsConnectionString: core.outputs.appInsightsConnectionString
    serviceBusFqdn: messaging!.outputs.serviceBusFqdn
    cosmosEndpoint: data!.outputs.cosmosEndpoint
    eventGridTopicEndpoint: messaging!.outputs.eventGridTopicEndpoint
  }
}

module aks 'modules/aks.bicep' = if (deployAks) {
  name: 'aks'
  params: {
    location: location
    prefix: prefix
    suffix: suffix
    tags: tags
    logAnalyticsId: core.outputs.logAnalyticsId
    acrName: core.outputs.acrName
  }
}

// Outputs are written to lab.env by the workflow so you can run the samples.
output AZURE_CLIENT_ID string = core.outputs.identityClientId
output ACR_NAME string = core.outputs.acrName
output ACR_LOGIN_SERVER string = core.outputs.acrLoginServer
output KEY_VAULT_NAME string = core.outputs.keyVaultName
output KEY_VAULT_URI string = core.outputs.keyVaultUri
output AZURE_APPCONFIG_ENDPOINT string = core.outputs.appConfigEndpoint
output STORAGE_ACCOUNT string = core.outputs.storageName
output BLOB_ENDPOINT string = core.outputs.blobEndpoint
output SERVICEBUS_FQDN string = (deployMessaging || deployContainers || deployFunctions) ? messaging!.outputs.serviceBusFqdn : ''
output EVENTGRID_TOPIC_ENDPOINT string = (deployMessaging || deployContainers || deployFunctions) ? messaging!.outputs.eventGridTopicEndpoint : ''
output COSMOS_ENDPOINT string = (deployData || deployFunctions) ? data!.outputs.cosmosEndpoint : ''
output POSTGRES_HOST string = (deployData || deployFunctions) ? data!.outputs.postgresHost : ''
output REDIS_HOST string = (deployData || deployFunctions) ? data!.outputs.redisHost : ''
output SEARCH_API_URL string = deployContainers ? containers!.outputs.searchApiUrl : ''
output SEARCH_API_NAME string = deployContainers ? containers!.outputs.searchApiName : ''
output WEBHOOK_URL string = deployContainers ? containers!.outputs.webhookUrl : ''
output WEBHOOK_NAME string = deployContainers ? containers!.outputs.webhookName : ''
output FUNCTION_APP_NAME string = deployFunctions ? functions!.outputs.functionAppName : ''
output AKS_NAME string = deployAks ? aks!.outputs.aksName : ''
