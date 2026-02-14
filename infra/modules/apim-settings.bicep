targetScope = 'resourceGroup'

@description('Existing APIM service name to configure')
param apimName string

@description('Menu Function base URL (e.g. https://<app>.azurewebsites.net)')
param menuFunctionBaseUrl string

@description('Orders Function base URL (e.g. https://<app>.azurewebsites.net)')
param ordersFunctionBaseUrl string

@description('Subscription key header name (defaults to APIM standard)')
param subscriptionKeyHeaderName string = 'Ocp-Apim-Subscription-Key'

@description('Subscription key query parameter name (defaults to APIM standard)')
param subscriptionKeyQueryName string = 'subscription-key'

// -----------------------------------------------------------------------------
// Constants (IDs / paths)
// -----------------------------------------------------------------------------
var menuMcpApiId = 'menu-list-mcp'
var menuMcpApiDisplayName = 'Menu List MCP'
var menuMcpApiDescription = 'このレストランのメニューの一覧や詳細、現在の注文制限を参照できます'
var menuMcpApiPath = 'menu-mcp'

var ordersApiId = 'restaurant-orders-api'
var ordersApiDisplayName = 'Restaurant Orders API'
var ordersApiDescription = 'Minimal REST API for creating and reading orders.\n\nThis OpenAPI document is derived from docs/SPECS.md in this repository.\n'
var ordersApiPath = 'api'

var ordersMcpApiId = 'restaurant-order-mcp'
var ordersMcpApiDisplayName = 'Restaurant Order MCP'
var ordersMcpApiPath = 'restaurant-order-mcp'

var menuPolicyXml = loadTextContent('./policies/menu-mcp-api-policy.xml')
var ordersMcpPolicyXml = loadTextContent('./policies/orders-mcp-api-policy.xml')

// For Existing MCP server, APIM should call the Functions MCP Streamable HTTP endpoint directly.
var menuFunctionMcpUrl = '${menuFunctionBaseUrl}/runtime/webhooks/mcp'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
	name: apimName
}

// -----------------------------------------------------------------------------
// Backends
// -----------------------------------------------------------------------------
// Existing MCP server (Functions MCP extension endpoint) is forwarded via policy.
resource menuBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
	parent: apim
	name: 'menu-mcp-backend'
	properties: {
		url: menuFunctionMcpUrl
		protocol: 'http'
	}
}

// -----------------------------------------------------------------------------
// API 1: Existing MCP server (proxy to Functions MCP extension)
// -----------------------------------------------------------------------------
resource menuMcpApi 'Microsoft.ApiManagement/service/apis@2025-03-01-preview' = {
	parent: apim
	name: menuMcpApiId
	properties: {
		displayName: menuMcpApiDisplayName
		apiRevision: '1'
		description: menuMcpApiDescription
		subscriptionRequired: false
		backendId: menuBackend.id
		path: menuMcpApiPath
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
		menuBackend
	]
}


resource menuMcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
	parent: menuMcpApi
	name: 'policy'
	properties: {
		value: menuPolicyXml
		format: 'xml'
	}
}
/*
// -----------------------------------------------------------------------------
// API 2: REST API (orders)
// -----------------------------------------------------------------------------
// The Functions app exposes routes under /api/* by default.
// By setting serviceUrl to {functionBaseUrl}/api and APIM API path to 'api',
// the public gateway URL becomes /api/orders and the backend URL becomes /api/orders.
var ordersApiServiceUrl = '${ordersFunctionBaseUrl}/api'

resource ordersApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
	parent: apim
	name: ordersApiId
	properties: {
		displayName: ordersApiDisplayName
		apiRevision: '1'
		description: ordersApiDescription
		subscriptionRequired: false
		serviceUrl: ordersApiServiceUrl
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
		path: ordersApiPath
	}
}

resource createOrderOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
	parent: ordersApi
	name: 'createOrder'
	properties: {
		displayName: 'Create an order'
		method: 'POST'
		urlTemplate: '/orders'
		templateParameters: []
		description: 'Create a new order.'
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
								menuVersion: 'v1'
								items: [
									{
										menuItemId: 'ramen-shoyu'
										quantity: 1
									}
								]
								note: 'No onions'
								pickupTime: '2026-02-04T13:30:00+09:00'
							}
						}
					}
				}
			]
		}
		responses: [
			{
				statusCode: 200
				description: 'Order created'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							example: {
								value: {
									orderId: 'ord_xxxxxxxx'
									status: 'confirmed'
									total: 900
									currency: 'JPY'
									createdAt: '2026-02-04T13:00:00+09:00'
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
				description: 'Bad Request (invalid menuItemId, invalid quantity, etc.)'
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
			{
				statusCode: 409
				description: 'Conflict (menuVersion mismatch)'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							default: {
								value: {
									error: {
										code: 'Conflict'
										message: 'Menu version mismatch'
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

resource getOrderOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
	parent: ordersApi
	name: 'getOrder'
	properties: {
		displayName: 'Get an order'
		method: 'GET'
		urlTemplate: '/orders/{orderId}'
		templateParameters: [
			{
				name: 'orderId'
				description: 'Order identifier (e.g., ord_xxxxxxxx)'
				type: 'string'
				required: true
				values: []
			}
		]
		description: 'Get an existing order by id.'
		responses: [
			{
				statusCode: 200
				description: 'Order'
				representations: [
					{
						contentType: 'application/json'
						examples: {
							default: {
								value: {
									orderId: 'ord_xxxxxxxx'
									status: 'confirmed'
									items: [
										{
											menuItemId: 'ramen-shoyu'
											quantity: 1
											lineTotal: 900
										}
									]
									total: 900
									currency: 'JPY'
									createdAt: '2026-02-04T13:00:00+09:00'
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
										message: 'Order not found'
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
resource ordersMcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
	parent: apim
	name: ordersMcpApiId
	properties: {
		displayName: ordersMcpApiDisplayName
		apiRevision: '1'
		subscriptionRequired: false
		path: ordersMcpApiPath
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
		ordersApi
		createOrderOp
		getOrderOp
	]
}

resource ordersMcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
	parent: ordersMcpApi
	name: 'policy'
	properties: {
		value: ordersMcpPolicyXml
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

