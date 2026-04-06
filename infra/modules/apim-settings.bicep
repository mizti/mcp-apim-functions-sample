targetScope = 'resourceGroup'

@description('Existing APIM service name to configure')
param apimName string

@description('Shipment MCP Function base URL (e.g. https://<app>.azurewebsites.net)')
param shipmentMcpFunctionBaseUrl string

@description('Shipment REST Function base URL (e.g. https://<app>.azurewebsites.net)')
param shipmentRestFunctionBaseUrl string

@description('Subscription key header name (defaults to APIM standard)')
param subscriptionKeyHeaderName string = 'Ocp-Apim-Subscription-Key'

@description('Subscription key query parameter name (defaults to APIM standard)')
param subscriptionKeyQueryName string = 'subscription-key'

// -----------------------------------------------------------------------------
// Constants (IDs / paths)
// -----------------------------------------------------------------------------
var shipmentMcpApiId = 'shipment-tracking-mcp'
var shipmentMcpApiDisplayName = 'Shipment Tracking MCP'
var shipmentMcpApiDescription = '配送の追跡、配送詳細の参照、配送ルールの確認ができます'
var shipmentMcpApiPath = 'shipment-mcp'

var shipmentsApiId = 'shipment-api'
var shipmentsApiDisplayName = 'Shipment API'
var shipmentsApiDescription = 'Minimal REST API for creating and reading shipments.\n\nThis OpenAPI document is derived from docs/SPECS.md in this repository.\n'
var shipmentsApiPath = 'api'

var shipmentsMcpApiId = 'shipment-rest-mcp'
var shipmentsMcpApiDisplayName = 'Shipment REST MCP'
var shipmentsMcpApiPath = 'shipment-rest-mcp'

var shipmentMcpPolicyXml = loadTextContent('./policies/menu-mcp-api-policy.xml')
var shipmentsMcpPolicyXml = loadTextContent('./policies/orders-mcp-api-policy.xml')

// For Existing MCP server, APIM should call the Functions MCP Streamable HTTP endpoint directly.
var shipmentMcpFunctionUrl = '${shipmentMcpFunctionBaseUrl}/runtime/webhooks/mcp'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
	name: apimName
}

// -----------------------------------------------------------------------------
// Backends
// -----------------------------------------------------------------------------
// Existing MCP server (Functions MCP extension endpoint) is forwarded via policy.
resource shipmentMcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
	parent: apim
	name: 'shipment-mcp-backend'
	properties: {
		url: shipmentMcpFunctionUrl
		protocol: 'http'
	}
}

// -----------------------------------------------------------------------------
// API 1: Existing MCP server (proxy to Functions MCP extension)
// -----------------------------------------------------------------------------
resource shipmentMcpApi 'Microsoft.ApiManagement/service/apis@2025-03-01-preview' = {
	parent: apim
	name: shipmentMcpApiId
	properties: {
		displayName: shipmentMcpApiDisplayName
		apiRevision: '1'
		description: shipmentMcpApiDescription
		subscriptionRequired: false
		backendId: shipmentMcpBackend.id
		path: shipmentMcpApiPath
		protocols: [
			'https'
		]
		authenticationSettings: {
			oAuth2AuthenticationSettings: []
			openidAuthenticationSettings: []
		}
		subscriptionKeyParameterNames: {
			header: subscriptionKeyHeaderName
			query: subscriptionKeyQueryName
		}
		type: 'mcp'
		isCurrent: true
	}
	dependsOn: [
		shipmentMcpBackend
	]
}


resource shipmentMcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
	parent: shipmentMcpApi
	name: 'policy'
	properties: {
		value: shipmentMcpPolicyXml
		format: 'xml'
	}
}
/*
// -----------------------------------------------------------------------------
// API 2: REST API (shipments)
// -----------------------------------------------------------------------------
// The Functions app exposes routes under /api/* by default.
// By setting serviceUrl to {functionBaseUrl}/api and APIM API path to 'api',
// the public gateway URL becomes /api/shipments and the backend URL becomes /api/shipments.
var shipmentsApiServiceUrl = '${shipmentRestFunctionBaseUrl}/api'

resource shipmentsApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
	parent: apim
	name: shipmentsApiId
	properties: {
		displayName: shipmentsApiDisplayName
		apiRevision: '1'
		description: shipmentsApiDescription
		subscriptionRequired: false
		serviceUrl: shipmentsApiServiceUrl
		protocols: [
			'http'
			'https'
		]
		authenticationSettings: {
			oAuth2AuthenticationSettings: []
			openidAuthenticationSettings: []
		}
		subscriptionKeyParameterNames: {
			header: subscriptionKeyHeaderName
			query: subscriptionKeyQueryName
		}
		isCurrent: true
		path: shipmentsApiPath
	}
}

resource createShipmentOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
	parent: shipmentsApi
	name: 'createShipment'
	properties: {
		displayName: 'Create a shipment'
		method: 'POST'
		urlTemplate: '/shipments'
		templateParameters: []
		description: 'Register a new shipment for delivery.'
		request: {
			queryParameters: []
			headers: [
				{
					name: 'Idempotency-Key'
					description: 'Optional idempotency key (UUID recommended).'
					type: 'string'
					values: []
				}
			]
			representations: [
				{
					contentType: 'application/json'
					examples: {
						example: {
							value: {
								senderName: '田中太郎'
								recipientName: '佐藤花子'
								from: '東京都千代田区'
								to: '大阪府大阪市'
								weightKg: 10
								sizeCm: '40x30x20'
								note: '割れ物注意'
							}
						}
					}
				}
			]
		}
		responses: [
			{
				statusCode: 200
				description: 'Shipment created'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							example: {
								value: {
									trackingId: 'QS-xxxxxxxx'
									status: 'pending'
									createdAt: '2026-04-03T10:00:00+09:00'
									validationWarnings: []
								}
							}
						}
					}
				]
				headers: []
			}
			{
				statusCode: 400
				description: 'Bad Request (missing required fields, weight over limit, etc.)'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							default: {
								value: {
									error: {
										code: 'BadRequest'
										message: 'Invalid request'
									}
								}
							}
						}
					}
				]
				headers: []
			}
		]
	}
}

resource getShipmentOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
	parent: shipmentsApi
	name: 'getShipment'
	properties: {
		displayName: 'Get a shipment'
		method: 'GET'
		urlTemplate: '/shipments/{trackingId}'
		templateParameters: [
			{
				name: 'trackingId'
				description: 'Tracking identifier (e.g., QS-001)'
				type: 'string'
				required: true
				values: []
			}
		]
		description: 'Get an existing shipment by tracking ID.'
		responses: [
			{
				statusCode: 200
				description: 'Shipment'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							default: {
								value: {
									trackingId: 'QS-001'
									status: 'delivered'
									senderName: '田中太郎'
									recipientName: '佐藤花子'
									from: '東京都千代田区'
									to: '大阪府大阪市'
									weightKg: 10
									sizeCm: '40x30x20'
									note: '割れ物注意'
									createdAt: '2026-04-01T09:00:00+09:00'
								}
							}
						}
					}
				]
				headers: []
			}
			{
				statusCode: 404
				description: 'Not Found'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							default: {
								value: {
									error: {
										code: 'NotFound'
										message: 'Shipment not found'
									}
								}
							}
						}
					}
				]
				headers: []
			}
		]
	}
}

// -----------------------------------------------------------------------------
// API 3: REST API as MCP server (APIM-side MCP tools mapped to REST operations)
// -----------------------------------------------------------------------------
resource shipmentsMcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
	parent: apim
	name: shipmentsMcpApiId
	properties: {
		displayName: shipmentsMcpApiDisplayName
		apiRevision: '1'
		subscriptionRequired: false
		path: shipmentsMcpApiPath
		protocols: [
			'https'
		]
		authenticationSettings: {
			oAuth2AuthenticationSettings: []
			openidAuthenticationSettings: []
		}
		subscriptionKeyParameterNames: {
			header: subscriptionKeyHeaderName
			query: subscriptionKeyQueryName
		}
		type: 'mcp'
		isCurrent: true
	}
	dependsOn: [
		shipmentsApi
		createShipmentOp
		getShipmentOp
	]
}

resource shipmentsMcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
	parent: shipmentsMcpApi
	name: 'policy'
	properties: {
		value: shipmentsMcpPolicyXml
		format: 'xml'
	}
}

// MCP Tools (mapping to REST operations). The operationId must be /apis/{apiId}/operations/{operationId}
resource createOrderTool 'Microsoft.ApiManagement/service/apis/tools@2025-03-01-preview' = {
	parent: ordersMcpApi
	name: 'createOrder'
	properties: {
		displayName: 'createOrder'
		description: 'Create an order'
		operationId: '/apis/${ordersApi.name}/operations/${createOrderOp.name}'
	}
}

resource getOrderTool 'Microsoft.ApiManagement/service/apis/tools@2025-03-01-preview' = {
	parent: ordersMcpApi
	name: 'getOrder'
	properties: {
		displayName: 'getOrder'
		description: 'Get an order'
		operationId: '/apis/${ordersApi.name}/operations/${getOrderOp.name}'
	}
}
*/
// Outputs can be used by azd/tests to print or compose endpoints.
//output ordersApiPath string = ordersApi.properties.path
output menuMcpApiPath string = menuMcpApi.properties.path
//output ordersMcpApiPath string = ordersMcpApi.properties.path

