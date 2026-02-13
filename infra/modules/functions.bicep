targetScope = 'resourceGroup'

@description('Deployment location')
param location string

@description('Environment name used for naming (dev/test/prod)')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

@description('Prefix for resource names')
param namePrefix string

@description('Short name used in the Function App name (for example: menu, orders)')
param appRole string

@description('Application Insights connection string (from monitoring module)')
param appInsightsConnectionString string

@description('Deterministic token (from subscription/env/location) to avoid global name collisions across resource groups')
param resourceToken string

@description('Functions runtime name for Flex Consumption')
@allowed([
  'python'
])
param functionRuntimeName string = 'python'

@description('Functions runtime version for Flex Consumption')
param functionRuntimeVersion string = '3.11'

@description('Maximum instance count for Flex Consumption scale-out')
@minValue(40)
@maxValue(1000)
param functionMaximumInstanceCount int = 100

@description('Instance memory size in MB for Flex Consumption')
@allowed([
  2048
  4096
])
param functionInstanceMemoryMB int = 2048

var abbrs = loadJsonContent('../abbreviations.json')

// Include both the deterministic subscription/env/location token and the RG id to guarantee uniqueness
// even when deploying multiple resource groups with the same environmentName/location.
var nameToken = toLower(uniqueString(resourceToken, resourceGroup().id, appRole))
var token7 = take(nameToken, 7)

var functionName = toLower('${abbrs.webSitesFunctions}${namePrefix}-${environmentName}-${appRole}-${token7}')
var planName = toLower('${abbrs.webServerFarms}${namePrefix}-${environmentName}-${appRole}-${token7}')

resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

// Create a dedicated storage account per Function App.
// NOTE: storage account names must be 3-24 chars and globally unique.
var storageBaseName = toLower('${abbrs.storageStorageAccounts}${namePrefix}${environmentName}${appRole}${take(nameToken, 24)}')
var storageAccountName = take(storageBaseName, 24)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

var deploymentContainerName = 'deployment'

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storage
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: deploymentContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: functionRuntimeName
        version: functionRuntimeVersion
      }
      scaleAndConcurrency: {
        maximumInstanceCount: functionMaximumInstanceCount
        instanceMemoryMB: functionInstanceMemoryMB
      }
    }
  }
}

// Allow the Function App identity to access the deployment storage container.
// Least-privilege: Blob Data Contributor is sufficient for reading/writing blobs.
var storageBlobDataContributorRoleDefinitionId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleDefinitionId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleDefinitionId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

resource deploymentStorageRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, storageBlobDataContributorRoleDefinitionId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefinitionId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource hostStorageQueueRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, storageQueueDataContributorRoleDefinitionId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleDefinitionId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource hostStorageTableRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, storageTableDataContributorRoleDefinitionId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleDefinitionId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  name: 'appsettings'
  parent: functionApp
  properties: {
    AzureWebJobsStorage__accountName: storage.name
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
  }
}

@description('Function hostname (direct)')
output functionHostname string = functionApp.properties.defaultHostName

@description('Function base URL (direct). This is not APIM-gatewayed yet.')
output functionBaseUrl string = 'https://${functionApp.properties.defaultHostName}'

@description('Function MCP endpoint (direct). This is not APIM-gatewayed yet.')
output functionMcpEndpoint string = 'https://${functionApp.properties.defaultHostName}/runtime/webhooks/mcp'

@description('Storage account name for this Function App')
output storageAccountName string = storage.name
