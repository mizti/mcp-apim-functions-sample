targetScope = 'resourceGroup'

@description('Deployment location')
param location string

@description('Environment name used for naming')
param environmentName string

@description('Deterministic token (from subscription/env/location) to avoid global name collisions across resource groups')
param resourceToken string

var abbrs = loadJsonContent('../abbreviations.json')
var token7 = take(toLower(resourceToken), 7)
var appInsightsName = toLower('${abbrs.insightsComponents}${environmentName}-${token7}')

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

@description('Application Insights connection string')
output appInsightsConnectionString string = appInsights.properties.ConnectionString

@description('Application Insights instrumentation key (for APIM logger configuration)')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey

@description('Application Insights resource name')
output appInsightsName string = appInsights.name
