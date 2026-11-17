// Messaging: Service Bus + Event Grid.
// Exam topics: queues vs topics/subscriptions, sessions (FIFO), dead-letter queue, max delivery count,
// subscription rules/filters, Event Grid custom topic, advanced filters, retry policy, dead-letter destination.

param location string
param prefix string
param suffix string
param tags object
param appIdentityPrincipalId string
param deployerPrincipalId string
param userPrincipalId string = ''
param storageId string

@allowed([ 'Standard', 'Premium' ])
@description('Standard is cheap. Premium (~hundreds of USD/month) is only needed for the Service Bus -> Event Grid integration (Q86).')
param serviceBusSku string = 'Standard'

var roles = {
  sbDataReceiver: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
  sbDataSender: '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
  sbDataOwner: '090c5cfd-751d-490a-894a-3ce6f1109419'
  egDataSender: 'd5a91429-5739-47e2-a06b-3470a27159e7'
}

// ---------------- Service Bus ----------------
resource sb 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: 'sb-${prefix}-${suffix}'
  location: location
  tags: tags
  sku: {
    name: serviceBusSku
    tier: serviceBusSku
    capacity: serviceBusSku == 'Premium' ? 1 : null
  }
  properties: {
    // Our apps and samples only use Microsoft Entra ID (managed identity / az login), never SAS keys.
    // Local auth is left on so the Event Grid -> Service Bus delivery below works without extra setup.
    disableLocalAuth: false
  }
}

// Point-to-point work queue. Failed messages -> $DeadLetterQueue after 5 tries (Q81).
resource jobsQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'ai-jobs'
  properties: {
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    lockDuration: 'PT1M'
  }
}

// Queue that drives KEDA scaling of the search API (messageCount) (Q96).
resource indexQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'index-updates'
  properties: {
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
  }
}

// Session-enabled queues = guaranteed FIFO per SessionId (Q79, Q87).
resource alarmQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'alarm-signals'
  properties: {
    requiresSession: true
    maxDeliveryCount: 5
  }
}

resource alarmReplies 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'alarm-replies'
  properties: {
    requiresSession: true
  }
}

// Queue that receives high-confidence events routed by Event Grid (Q76-78).
resource highConfidenceQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: sb
  name: 'high-confidence'
}

// Topic + subscriptions = fan-out: each subscription gets its own copy (Q83).
resource topic 'Microsoft.ServiceBus/namespaces/topics@2024-01-01' = {
  parent: sb
  name: 'inference-results'
}

resource subAudit 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2024-01-01' = {
  parent: topic
  name: 'audit'
  properties: {
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
  }
}

resource subDashboard 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2024-01-01' = {
  parent: topic
  name: 'dashboard'
  properties: {
    maxDeliveryCount: 5
  }
}

// Subscription RULE (SQL filter): this subscription only receives high-confidence results.
// A rule decides WHICH messages a subscription gets; it does not control ORDER.
resource subAlerts 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2024-01-01' = {
  parent: topic
  name: 'alerts'
  properties: {
    maxDeliveryCount: 5
  }
}

resource subAlertsRule 'Microsoft.ServiceBus/namespaces/topics/subscriptions/rules@2024-01-01' = {
  parent: subAlerts
  name: 'HighConfidenceOnly'
  properties: {
    filterType: 'SqlFilter'
    sqlFilter: {
      sqlExpression: 'confidenceScore > 0.8'
    }
  }
}

// Role assignments: the app identity both sends and receives; you get Data Owner for the samples.
resource sbAppReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sb.id, appIdentityPrincipalId, roles.sbDataReceiver)
  scope: sb
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sbDataReceiver)
  }
}

resource sbAppSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sb.id, appIdentityPrincipalId, roles.sbDataSender)
  scope: sb
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sbDataSender)
  }
}

// The KEDA Service Bus scaler reads queue runtime info (message count), which is a management operation.
// KEDA's docs ask for Data Owner for this. In production you would give the scaler its OWN identity
// with this role, and keep the app identity at Sender/Receiver (least privilege).
resource sbScalerOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sb.id, appIdentityPrincipalId, roles.sbDataOwner)
  scope: sb
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sbDataOwner)
  }
}

resource sbUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(sb.id, userPrincipalId, roles.sbDataOwner)
  scope: sb
  properties: {
    principalId: userPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sbDataOwner)
  }
}

// ---------------- Event Grid ----------------
// CUSTOM topic = your own app publishes events (Q77). System topics are created by Azure services.
resource egTopic 'Microsoft.EventGrid/topics@2025-02-15' = {
  name: 'egt-${prefix}-inference-${suffix}'
  location: location
  tags: tags
  properties: {
    inputSchema: 'CloudEventSchemaV1_0'
    disableLocalAuth: true // publish with Microsoft Entra ID, not access keys
  }
}

resource egAppSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(egTopic.id, appIdentityPrincipalId, roles.egDataSender)
  scope: egTopic
  properties: {
    principalId: appIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.egDataSender)
  }
}

resource egUserSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(egTopic.id, userPrincipalId, roles.egDataSender)
  scope: egTopic
  properties: {
    principalId: userPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.egDataSender)
  }
}

resource egDeployerSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(egTopic.id, deployerPrincipalId, roles.egDataSender)
  scope: egTopic
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.egDataSender)
  }
}

// Event subscription with:
//  - ADVANCED filter on a payload value (data.confidenceScore > 0.8)   (Q76, Q78)
//  - retry policy: max delivery attempts + event TTL                    (Q76)
//  - dead-letter destination: a blob container                         (Q76)
resource egSub 'Microsoft.EventGrid/topics/eventSubscriptions@2025-02-15' = {
  parent: egTopic
  name: 'high-confidence-to-servicebus'
  properties: {
    eventDeliverySchema: 'CloudEventSchemaV1_0'
    destination: {
      endpointType: 'ServiceBusQueue'
      properties: {
        resourceId: highConfidenceQueue.id
      }
    }
    filter: {
      includedEventTypes: [ 'AI.InferenceCompleted' ]
      advancedFilters: [
        {
          operatorType: 'NumberGreaterThan'
          key: 'data.confidenceScore'
          value: json('0.8')
        }
      ]
    }
    retryPolicy: {
      maxDeliveryAttempts: 5
      eventTimeToLiveInMinutes: 60
    }
    deadLetterDestination: {
      endpointType: 'StorageBlob'
      properties: {
        resourceId: storageId
        blobContainerName: 'eg-deadletter'
      }
    }
  }
}

output serviceBusName string = sb.name
output serviceBusFqdn string = '${sb.name}.servicebus.windows.net'
output serviceBusId string = sb.id
output eventGridTopicEndpoint string = egTopic.properties.endpoint
output eventGridTopicName string = egTopic.name
