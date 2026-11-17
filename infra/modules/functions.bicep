// Azure Functions (Flex Consumption, Python).
// Exam topics: triggers and bindings, identity-based connections (no connection strings),
// Cosmos DB change feed trigger, Service Bus trigger with sessions, Event Grid trigger, blob input binding.

param location string
param prefix string
param suffix string
param tags object
param identityId string
param identityClientId string
param storageName string
param blobEndpoint string
param appInsightsConnectionString string
param serviceBusFqdn string
param cosmosEndpoint string
param eventGridTopicEndpoint string

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${prefix}-func-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' } // pay per execution, scales to zero
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: 'func-${prefix}-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${blobEndpoint}func-deploy'
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: identityId }
        }
      }
      scaleAndConcurrency: { instanceMemoryMB: 2048, maximumInstanceCount: 10 }
      runtime: { name: 'python', version: '3.11' }
    }
    siteConfig: {
      appSettings: [
        // Identity-based connections: "<Name>__<property>" settings instead of connection strings.
        { name: 'AzureWebJobsStorage__accountName', value: storageName }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: identityClientId }
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: serviceBusFqdn }
        { name: 'ServiceBusConnection__credential', value: 'managedidentity' }
        { name: 'ServiceBusConnection__clientId', value: identityClientId }
        { name: 'CosmosConnection__accountEndpoint', value: cosmosEndpoint }
        { name: 'CosmosConnection__credential', value: 'managedidentity' }
        { name: 'CosmosConnection__clientId', value: identityClientId }
        { name: 'ConfigStorage__blobServiceUri', value: blobEndpoint }
        { name: 'ConfigStorage__credential', value: 'managedidentity' }
        { name: 'ConfigStorage__clientId', value: identityClientId }
        { name: 'AZURE_CLIENT_ID', value: identityClientId }
        { name: 'SERVICEBUS_FQDN', value: serviceBusFqdn }
        { name: 'EVENTGRID_TOPIC_ENDPOINT', value: eventGridTopicEndpoint }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'PYTHON_ENABLE_OPENTELEMETRY', value: 'true' } // with host.json "telemetryMode": "OpenTelemetry"
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'ClientId=${identityClientId};Authorization=AAD' }
      ]
    }
  }
}

output functionAppName string = func.name
output functionAppUrl string = 'https://${func.properties.defaultHostName}'
