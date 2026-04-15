targetScope = 'resourceGroup'

@description('Name of the existing APIM instance')
param apimName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// Retrieve the built-in all-access subscription key
resource builtInSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' existing = {
  name: 'master'
  parent: apim
}

@description('APIM gateway base URL')
output apimGatewayUrl string = apim.properties.gatewayUrl

@description('APIM service name')
output apimName string = apim.name

@description('APIM subscription key (built-in all-access)')
@secure()
output apimSubscriptionKey string = builtInSubscription.listSecrets().primaryKey
