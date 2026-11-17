// OPTIONAL and the most expensive module: a tiny AKS cluster for the batch re-embedding job.
// Exam topics: AKS deployment with manifests, ACR pull via kubelet identity, Container Insights,
// troubleshooting with events / pod descriptions / container logs / service endpoints.
// Delete it as soon as you are done (the node VM is billed every hour it exists).

param location string
param prefix string
param suffix string
param tags object
param logAnalyticsId string
param acrName string

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: 'aks-${prefix}-${suffix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  sku: { name: 'Base', tier: 'Free' } // free control plane
  properties: {
    dnsPrefix: 'aks${prefix}${suffix}'
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: 1
        vmSize: 'Standard_B2s'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    workloadAutoScalerProfile: {
      keda: { enabled: true } // KEDA add-on: scale the batch job on queue length, down to zero
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    addonProfiles: {
      omsagent: {
        enabled: true // Container Insights -> KubePodInventory, KubeEvents, ContainerLogV2 tables for KQL
        config: { logAnalyticsWorkspaceResourceID: logAnalyticsId }
      }
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'acrpull')
  scope: acr
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

output aksName string = aks.name
