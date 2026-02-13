# mcp-apim-functions-sample
Azure reference implementation of MCP server with API Management and Functions

### Architecture

![alt text](images/architecture.png)

### What this repo provides

This is a minimal Azure sample that exposes, through a single Azure API Management (APIM) gateway:

- An MCP server hosted on Azure Functions (Python programming model v2) exposing **Tools** (read-only, restaurant menu scenario)
- A small REST API hosted on Azure Functions for **state-changing** operations (create/read orders), additionally exposed by APIM as **MCP tools**

It is designed for learning and validation, and can be deployed end-to-end with Azure Developer CLI:

- One command deployment: `azd up`
- APIM is the only intended public entrypoint
- Azure Functions on **Flex Consumption**
- Application Insights enabled

Endpoints (APIM public):

- MCP server (menu/constraints, Streamable HTTP): APIM **Existing MCP server** endpoint URL (shown in `azd up` output)
- MCP server (orders, Streamable HTTP): APIM **Expose REST API as MCP server** endpoint URL (shown in `azd up` output)

Authentication (sample): APIM subscription key.

### How to use

Prerequisites:

- An Azure subscription
- Azure Developer CLI (`azd`)
- Azure CLI (`az`)

Deploy:

```bash
azd auth login
azd env set APIM_PUBLISHER_EMAIL "you@example.com"
azd env set APIM_PUBLISHER_NAME "Your Name"
azd up
```

Note: Resource naming uses `AZURE_ENV_NAME` via `infra/main.parameters.json` so the Azure environment name you enter for `azd` is reflected in provisioned resource names.

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
- For VS Code / GitHub Copilot, configure the server URL(s) printed by `azd up` and include the `Ocp-Apim-Subscription-Key` header.

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

- MCP server（参照系: メニュー/制約。Streamable HTTP）: APIM の **Existing MCP server** の Server URL（`azd up` 出力に表示）
- MCP server（注文系: orders 操作を tools として公開。Streamable HTTP）: APIM の **REST API as MCP server** の Server URL（`azd up` 出力に表示）

認証（サンプル）: APIM Subscription Key。

### このリポジトリの利用方法

前提:

- Azure サブスクリプション
- Azure Developer CLI（`azd`）
- Azure CLI（`az`）

デプロイ:

```bash
azd auth login
azd env set APIM_PUBLISHER_EMAIL "you@example.com"
azd env set APIM_PUBLISHER_NAME "Your Name"
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
- VS Code / GitHub Copilot の場合は `azd up` の出力に表示される MCP Server URL をサーバー URL に設定し、ヘッダーに `Ocp-Apim-Subscription-Key` を付与します。

削除:

```bash
azd down
```
