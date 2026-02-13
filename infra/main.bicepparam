using './main.bicep'

// Resource group to create and deploy into
param resourceGroupName = 'rg-mcp-dev'

param environmentName = 'dev'
param namePrefix = 'mcp'

// Set these before deploying
param apimPublisherEmail = 'you@example.com'
param apimPublisherName = 'Your Name'

// APIM SKU can be changed later; this template only provisions the APIM instance.
param apimSkuName = 'Developer'
param apimSkuCapacity = 1

param functionRuntimeVersion = '3.11'
param functionMaximumInstanceCount = 100
param functionInstanceMemoryMB = 2048
