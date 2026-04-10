targetScope = 'subscription'

@description('Resource group name to create and deploy into')
param resourceGroupName string = ''

@description('Tags applied to the resource group')
param tags object = {
  CostControl: 'Ignore'
  SecurityControl: 'Ignore'
}

param location string

@description('Environment name used for naming. This should match AZURE_ENV_NAME so azd can discover the environment resource group by tag/name.')
param environmentName string

@description('APIM publisher email')
param apimPublisherEmail string ='ks@example.com'

@description('APIM publisher name')
param apimPublisherName string ='KS Company'

@description('APIM SKU. MCP Servers feature support depends on SKU, but this template only creates the APIM instance.')
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

@description('Whether to deploy API Management. Set "yes" to deploy, "no" to skip.')
param deployApim string = 'yes'

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

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var token8 = take(resourceToken, 8)

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: union(tags, {
    'azd-env-name': environmentName
  })
}

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring-${environmentName}-${token8}'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    resourceToken: resourceToken
  }
}

module mcpFunction './modules/functions.bicep' = {
  name: 'function-mcp-${environmentName}-${token8}'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    appRole: 'mcp'
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    resourceToken: resourceToken
    functionRuntimeName: functionRuntimeName
    functionRuntimeVersion: functionRuntimeVersion
    functionMaximumInstanceCount: functionMaximumInstanceCount
    functionInstanceMemoryMB: functionInstanceMemoryMB
  }
}

module restFunction './modules/functions.bicep' = {
  name: 'function-rest-${environmentName}-${token8}'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    appRole: 'rest'
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    resourceToken: resourceToken
    functionRuntimeName: functionRuntimeName
    functionRuntimeVersion: functionRuntimeVersion
    functionMaximumInstanceCount: functionMaximumInstanceCount
    functionInstanceMemoryMB: functionInstanceMemoryMB
  }
}

module apim './modules/apim.bicep' = if (deployApim == 'yes') {
  name: 'apim-${environmentName}-${token8}'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    apimSkuName: apimSkuName
    apimSkuCapacity: apimSkuCapacity
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
    resourceToken: resourceToken
  }
}
/*
//MCPサーバーを登録するBicepの書き方が見つけられていない
module apimSettings './modules/apim-settings.bicep' = {
  name: 'apim-settings-${environmentName}-${token8}'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    shipmentMcpFunctionBaseUrl: mcpFunction.outputs.functionBaseUrl
    shipmentRestFunctionBaseUrl: restFunction.outputs.functionBaseUrl
  }
}
*/

@description('APIM gateway base URL')
output apimGatewayUrl string = apim.?outputs.apimGatewayUrl ?? ''

@description('APIM service name')
output apimName string = apim.?outputs.apimName ?? ''

@description('MCP Function (shipment tracking) hostname (direct)')
output mcpFunctionHostname string = mcpFunction.outputs.functionHostname

@description('REST Function (shipments) hostname (direct)')
output restFunctionHostname string = restFunction.outputs.functionHostname

@description('MCP Function endpoint (direct). This is not APIM-gatewayed yet.')
output mcpFunctionMcpEndpoint string = mcpFunction.outputs.functionMcpEndpoint

@description('REST Function base URL (direct). This is not APIM-gatewayed yet.')
output restFunctionBaseUrl string = restFunction.outputs.functionBaseUrl
