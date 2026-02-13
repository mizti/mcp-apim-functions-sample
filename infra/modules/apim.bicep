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

@description('APIM publisher email')
param apimPublisherEmail string

@description('APIM publisher name')
param apimPublisherName string

@description('Application Insights instrumentation key used by APIM diagnostics')
param appInsightsInstrumentationKey string

@description('Deterministic token (from subscription/env/location) to avoid global name collisions across resource groups')
param resourceToken string

@description('APIM SKU. MCP Servers feature support depends on SKU, but this module only creates the APIM instance.')
@allowed([
  'Developer'
  'Basic'
  'BasicV2'
  'Standard'
  'StandardV2'
  'Premium'
])
param apimSkuName string = 'StandardV2'

@description('APIM capacity (units). For Developer/Basic/Standard: 1+. For Premium: 1+.')
param apimSkuCapacity int = 1

var abbrs = loadJsonContent('../abbreviations.json')
var token7 = take(toLower(resourceToken), 7)
var apimServiceName = toLower('${abbrs.apiManagementService}${namePrefix}-${environmentName}-${token7}')

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  sku: {
    name: apimSkuName
    capacity: apimSkuCapacity
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

// Send APIM gateway/backend telemetry to the shared Application Insights.
resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  name: 'appinsights'
  parent: apim
  properties: {
    loggerType: 'applicationInsights'
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    isBuffered: true
  }
}

resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  name: 'applicationinsights'
  parent: apim
  properties: {
    loggerId: appInsightsLogger.id
    httpCorrelationProtocol: 'W3C'
    operationNameFormat: 'Name'
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
  }
}

@description('APIM gateway base URL')
output apimGatewayUrl string = apim.properties.gatewayUrl

@description('APIM service name')
output apimName string = apim.name
