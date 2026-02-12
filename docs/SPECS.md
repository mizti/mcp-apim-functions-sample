# APIMでMCPサーバー(①)とREST API(②)を同時ゲートウェイする最小サンプル仕様書

> 本ドキュメントはこのプロジェクトにおいて実装をおこないたいMCPサーバーサンプルの仕様について規定するものである
> 出力成果物は **Azure Developer CLI (azd)** 形式のサンプルで、`azd up` により Azure インフラとアプリケーションを一括デプロイできる。
> 実装言語は **Azure Functions Python プログラミングモデル v2** とする。

---

## 1. 背景と目的

生成AI / エージェント連携において、

* **①文脈・参照情報を提供する MCP サーバー**
* **②状態変更を担う既存 REST API**

を分離しつつ、**単一の API Gateway (Azure API Management)** でMCPサーバーとして統合公開する構成を提供するサンプル実装である。

本サンプルは以下を同時に満たす最小構成を示す：

* ① **ネイティブ MCP サーバーとして動作する Azure Functions**
* ② **シンプルな REST API として動作する Azure Functions**
* 両者を **1つの APIM** で Gateway
* **azd up 一発でデプロイ可能**

教育・検証用途のため、機能は極力シンプルにする。エラー処理等は最小限で可能な限りシンプルなコードを保つこと。

---

## 2. シナリオ概要（レストラン）

* ① MCP サーバー

  * メニュー一覧
  * メニュー詳細
  * 注文に関する制約（営業時間など）
  * → **参照系（読む・理解する）**

* ② REST API

  * 注文作成
  * 注文参照
  * → **更新系（状態を変える）**

想定フロー：

1. クライアント / エージェントが ① MCP からメニューと制約を取得
2. 注文内容を構築
3. ② REST API に注文を送信

---

## 3. 非機能要件と割り切り

### 3.1 実装すること

* `azd up` による完全自動デプロイ
* APIM を唯一の公開エンドポイントとする
* MCP は **Tools 中心**で実装
* REST API は **最小エンドポイント**のみ
* Application Insights にログ出力
* Azure Functions は **Flex Consumption** を前提とする（VNet 等は不要）* Functions の既定ホストストレージ（`AzureWebJobsStorage`）を用意する

### 3.2 実装しないこと

* 本番向けの厳密な認証認可（サンプルでは APIM Subscription Key のみ）
* 複雑な DB 永続化（まずはインメモリ or 簡易実装）
* MCP Resources / Prompts の高度な設計

---

## 4. 全体アーキテクチャ

### 4.1 コンポーネント

* Function App A：MCP サーバー（①）
* Function App B：REST API（②）
* Azure API Management（Gateway）
* Application Insights

### 4.2 公開パス（APIM）

| 種別   | パス                      | 説明                   |
| ---- | ----------------------- | -------------------- |
| MCP  | `/mcp`                  | MCP エンドポイント（Streamable HTTP） |
| REST | `/api/orders`           | 注文作成                 |
| REST | `/api/orders/{orderId}` | 注文参照                 |

---

## 5. API仕様

## 5.1 ① MCPサーバー（Function App A）

### 5.1.1 通信方式

* HTTP
* JSON-RPC 2.0
* 単一エンドポイント（Streamable HTTP）：`POST /runtime/webhooks/mcp`

補足：Azure Functions MCP extension は、Streamable HTTP と SSE の両 transport を提供する。

* Streamable HTTP: `/runtime/webhooks/mcp`（推奨）
* SSE: `/runtime/webhooks/mcp/sse`（新しいプロトコルでは非推奨。クライアント都合がある場合のみ）

本サンプルでは **推奨の Streamable HTTP** を採用する。

* Functions の MCP エンドポイント：`/runtime/webhooks/mcp`
* APIM の外向け公開パス：`/mcp`

APIM は受信した `/mcp` リクエストをバックエンドの `/runtime/webhooks/mcp` に **URI Rewrite** して中継する。

### 5.1.2 実装する MCP Tools一覧

* メニュー一覧の取得（`get_list_menus`）
* メニュー詳細の取得（`get_menu_details`）
* 注文制約の取得（`get_constraints`）

### 5.1.3 Tools 定義（入出力）

#### Tool: `get_list_menus`

* Input: なし
* Output 例：

```json
{
  "menuVersion": "v1",
  "categories": ["ramen", "side"],
  "items": [
    {
      "id": "ramen-shoyu",
      "name": "醤油ラーメン",
      "category": "ramen",
      "basePrice": 900,
      "available": true
    }
  ]
}
```

#### Tool: `get_menu_details`

* Input 例：

```json
{
  "itemId": "ramen-shoyu"
}
```

* Output 例：

```json
{
  "id": "ramen-shoyu",
  "name": "醤油ラーメン",
  "description": "定番の醤油ラーメン",
  "basePrice": 900,
  "allergens": ["wheat", "soy"],
  "options": []
}
```

#### Tool: `get_constraints`

* Input: なし
* Output 例：

```json
{
  "openHours": "11:00-21:00",
  "maxItemsPerOrder": 10,
  "notes": ["混雑時は提供が遅れる場合があります"]
}
```

### 5.1.4 データ

* メニューは **固定 JSON** をコード内で保持
* `menuVersion` は固定値で可

---

## 5.2 ② REST API（Function App B）

### 5.2.1 注文作成

* `POST /api/orders`

#### Request

```json
{
  "menuVersion": "v1",
  "items": [
    { "menuItemId": "ramen-shoyu", "quantity": 1 }
  ],
  "note": "No onions",
  "pickupTime": "2026-02-04T13:30:00+09:00"
}
```

* Header（任意）：
 
  * `Idempotency-Key: <uuid>`

#### Response

```json
{
  "orderId": "ord_xxxxxxxx",
  "status": "confirmed",
  "total": 900,
  "currency": "JPY",
  "createdAt": "2026-02-04T13:00:00+09:00",
  "validationWarnings": []
}
```

#### バリデーション

* `menuVersion` 不一致 → `409 Conflict`
* 不正な `menuItemId` → `400 Bad Request`
* `quantity <= 0` → `400 Bad Request`

### 5.2.2 注文参照

* `GET /api/orders/{orderId}`

```json
{
  "orderId": "ord_xxxxxxxx",
  "status": "confirmed",
  "items": [
    { "menuItemId": "ramen-shoyu", "quantity": 1, "lineTotal": 900 }
  ],
  "total": 900,
  "currency": "JPY",
  "createdAt": "..."
}
```

---

## 6. APIM 設定方針

* MCP API

  * Public path: `POST /mcp`
  * Backend path: `POST /runtime/webhooks/mcp`
  * Policy: inbound で `/mcp` → `/runtime/webhooks/mcp` に URI Rewrite

  補足：Streamable HTTP はレスポンスがストリーミングされる場合があるため、APIM 側でバッファリング等によりストリームが阻害されないことを前提とする。

* REST API

  * Public paths:

    * `POST /api/orders`
    * `GET /api/orders/{orderId}`

補足：REST 側は `/api/*` としてそのまま中継し、MCP 側のみ APIM で URI Rewrite して `/runtime/webhooks/mcp` に転送する。

### セキュリティ

* APIM Subscription Key を必須
* Functions 側の認証は最小限
  * MCP extension の既定では Functions の system key（`mcp_extension`）が要求されるが、本サンプルでは APIM Subscription Key のみに寄せるため、Functions 側は `host.json` の `extensions.mcp.system.webhookAuthorizationLevel` を `Anonymous` にして key 要求を無効化する

注意：上記により Functions の MCP エンドポイント自体は匿名アクセス可能になるため、**APIM を唯一の公開エンドポイント**に厳密にしたい場合は、Function App 側のアクセス制限（IP 制限など）で直接アクセスを抑止すること（本サンプルでは必須としない）。

---

## 7. リポジトリ構成（例）

```
/
  azure.yaml
  infra/
    main.bicep
    modules/
      apim.bicep
      functions.bicep
  src/
    mcp_function/
      function_app.py
      rpc.py
      menu.json
    rest_function/
      function_app.py
      orders.py
      menu.json
  README.md
```

---

## 8. azd 要件

* `azd up` で以下を実施

  * Resource Group 作成
  * Function Apps (2つ) 作成・デプロイ（Flex Consumption）
  * Storage Account 作成（Functions のホストストレージ）
  * APIM 作成・API登録
  * Application Insights 作成

### 出力

* APIM Gateway URL
* MCP Endpoint URL
* REST API URL
* Subscription Key（デモ用途）

---

## 9. 受け入れ条件

* `azd up` のみで環境構築可能
* APIM 経由で以下が成功する

  * MCP `tools/list`
  * MCP `tools/call get_list_menus`
  * REST `POST /api/orders`
* メニュー定義が ①②で一致している

---

## 10. Copilot 実装ガイド

* Functions上のアプリは Python プログラミングモデルv2 を使用すること
* MCP は Tools 中心で実装
* REST API は状態変更のみに集中
* 過剰な機能拡張を行わない
* 教育用サンプルであることを常に意識する

---

## 11. 注意

本サンプルは教育・検証目的であり、本番利用時は以下を別途検討すること：

* 認証・認可
* シークレット管理
* 監査ログ
* 入力検証の強化
* MCP 仕様拡張への追従
