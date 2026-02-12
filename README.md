# mcp-apim-functions-sample
Azure reference implementation of MCP server with API Management and Functions

### Architecture

![alt text](images/architecture.png)

### What this repo provides

This is a minimal Azure sample that exposes, through a single Azure API Management (APIM) gateway:

- An MCP server hosted on Azure Functions (Python programming model v2) exposing **Tools** (read-only, restaurant menu scenario)
- A small REST API hosted on Azure Functions for **state-changing** operations (create/read orders)

It is designed for learning and validation, and can be deployed end-to-end with Azure Developer CLI:

- One command deployment: `azd up`
- APIM is the only intended public entrypoint
- Azure Functions on **Flex Consumption**
- Application Insights enabled

Endpoints (APIM public):

- MCP (Streamable HTTP): `POST /mcp` (APIM rewrites to the Functions MCP extension endpoint `/runtime/webhooks/mcp`)
- REST: `POST /api/orders`, `GET /api/orders/{orderId}`

Authentication (sample): APIM subscription ke

### How to use

Prerequisites:

- An Azure subscription
- Azure Developer CLI (`azd`)
- Azure CLI (`az`)

Deploy:

```bash
azd auth login
azd up
```

After `azd up`, note the printed APIM gateway base URL and subscription key.

Call the REST API (example):

```bash
curl -sS -X POST "${APIM_BASE_URL}/api/orders" \
	-H "Content-Type: application/json" \
	-H "Ocp-Apim-Subscription-Key: ${APIM_SUBSCRIPTION_KEY}" \
	-d '{"menuVersion":"v1","items":[{"menuItemId":"ramen-shoyu","quantity":1}],"note":"No onions"}'
```

Call the MCP server:

- Use any MCP client that supports **Streamable HTTP**.
- For VS Code / GitHub Copilot, configure the server URL as `${APIM_BASE_URL}/mcp` and include the `Ocp-Apim-Subscription-Key` header.

Clean up:

```bash
azd down
```

---

## 日本語

### このリポジトリが提供するもの

このリポジトリは、単一の Azure API Management（APIM）をゲートウェイとして、次を同時に公開する最小サンプルです。

- Azure Functions（Python プログラミングモデル v2）で動作する **MCP サーバー**（参照系の **Tools** を公開。レストランメニュー想定）
- Azure Functions で動作する **REST API**（注文の作成/参照など、状態変更系）

学習・検証用途のため、機能は最小限です。Azure Developer CLI により一括デプロイできます。

- `azd up` でインフラ + アプリをまとめてデプロイ
- 公開エンドポイントは APIM を想定
- Azure Functions は **Flex Consumption**
- Application Insights を有効化

エンドポイント（APIM 外向け公開）:

- MCP（Streamable HTTP）: `POST /mcp`（APIM が Functions 側の `/runtime/webhooks/mcp` へ URI Rewrite）
- REST: `POST /api/orders`, `GET /api/orders/{orderId}`

認証（サンプル）: APIM Subscription Key。

### このリポジトリの利用方法

前提:

- Azure サブスクリプション
- Azure Developer CLI（`azd`）
- Azure CLI（`az`）

デプロイ:

```bash
azd auth login
azd up
```

`azd up` の出力に表示される APIM のベース URL と Subscription Key を控えてください。

REST API 呼び出し例:

```bash
curl -sS -X POST "${APIM_BASE_URL}/api/orders" \
	-H "Content-Type: application/json" \
	-H "Ocp-Apim-Subscription-Key: ${APIM_SUBSCRIPTION_KEY}" \
	-d '{"menuVersion":"v1","items":[{"menuItemId":"ramen-shoyu","quantity":1}],"note":"No onions"}'
```

MCP サーバーの利用:

- **Streamable HTTP** に対応した MCP クライアントを使用してください。
- VS Code / GitHub Copilot の場合は `${APIM_BASE_URL}/mcp` をサーバー URL に設定し、ヘッダーに `Ocp-Apim-Subscription-Key` を付与します。

削除:

```bash
azd down
```
