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

## 2. シナリオ概要（運送業）

* ① MCP サーバー

  * 配送状況の追跡
  * 配送詳細の参照
  * 配送ルール・制約の参照
  * → **参照系（読む・理解する）**

* ② REST API

  * 配送荷物の登録
  * 配送情報の参照
  * → **更新系（状態を変える）**

想定フロー：

1. クライアント / エージェントが ① MCP から配送ルール・制約を取得
2. 配送依頼内容を構築
3. ② REST API に配送依頼を送信
4. ① MCP から配送状況を追跡・詳細を確認

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
* 複雑な DB 永続化（インメモリストア + サンプル固定データ）
* MCP Resources / Prompts の高度な設計

---

## 4. 全体アーキテクチャ

### 4.1 コンポーネント

* Function App A：MCP サーバー（①）
* Function App B：REST API（②）
* Azure API Management（Gateway / AI Gateway）
* Application Insights

### 4.2 公開方式（APIM）

本サンプルでは、クライアント/エージェントは **HTTP REST を直接呼び出さず**、APIM が提供する **MCP Servers 機能**を通じて **MCP Tools として**利用できることを主目的とする。

APIM は MCP Servers 機能として、以下 2 種類の MCP サーバー公開方法を併用する：

* **Existing MCP server**（既存の MCP サーバーを APIM 経由で公開）
  * Backend: Function App A（MCP extension の Streamable HTTP エンドポイント）
  * 提供ツール: 配送追跡/配送詳細/配送ルール（参照系）
* **REST API as MCP server**（APIM が管理する REST API を MCP サーバーとして公開）
  * Backend: Function App B（REST API）
  * 提供ツール: 配送登録/配送参照（更新系/参照系）

補足：APIM の MCP Server の具体的な URL（Server URL）は、作成した MCP server の名称/ベースパスに依存するため、`azd up` の出力として表示する。

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
* APIM の外向け公開：**Existing MCP server** として APIM に登録し、APIM が提供する MCP Server URL（Streamable HTTP）経由で利用する

### 5.1.2 実装する MCP Tools一覧

* 配送状況の追跡（`track_shipment`）
* 配送詳細の取得（`get_shipment_details`）
* 配送ルール・制約の取得（`get_shipping_rules`）

### 5.1.3 Tools 定義（入出力）

#### Tool: `track_shipment`

* Input 例：

```json
{
  "trackingId": "QS-001"
}
```

* Output 例：

```json
{
  "trackingId": "QS-001",
  "status": "delivered",
  "lastUpdated": "2026-04-02T14:30:00+09:00"
}
```

#### Tool: `get_shipment_details`

* Input 例：

```json
{
  "trackingId": "QS-001"
}
```

* Output 例：

```json
{
  "trackingId": "QS-001",
  "status": "delivered",
  "senderName": "田中太郎",
  "recipientName": "佐藤花子",
  "from": "東京都千代田区",
  "to": "大阪府大阪市",
  "weightKg": 10,
  "sizeCm": "40x30x20",
  "createdAt": "2026-04-01T09:00:00+09:00",
  "lastUpdated": "2026-04-02T14:30:00+09:00"
}
```

#### Tool: `get_shipping_rules`

* Input: なし
* Output 例：

```json
{
  "acceptanceHours": "08:00-20:00",
  "maxWeightKg": 30,
  "maxSizeCm": "3辺合計160cm以内",
  "maxPackagesPerRequest": 5,
  "prohibitedItems": ["危険物", "動植物"],
  "serviceArea": "全国（離島除く）"
}
```

### 5.1.4 データ

* 配送データはサンプル固定データを **JSON ファイル** でコード内に保持
* 配送ルールも同一 JSON に含める

---

## 5.2 ② REST API（Function App B）

本サンプルでは ② を「REST API として実装」するが、クライアント/エージェントからは **APIM が公開する MCP tools** として利用できることを要件とする。
APIM 側では ② を通常の REST API として取り込み（Managed API）、その API operations を選択して **REST API as MCP server** として公開する。

### 5.2.1 配送登録（REST API）

* `POST /api/shipments`

#### Request

```json
{
  "senderName": "田中太郎",
  "recipientName": "佐藤花子",
  "from": "東京都千代田区",
  "to": "大阪府大阪市",
  "weightKg": 10,
  "sizeCm": "40x30x20",
  "note": "割れ物注意"
}
```

* Header（任意）：
 
  * `Idempotency-Key: <uuid>`

#### Response

```json
{
  "trackingId": "QS-xxxxxxxx",
  "status": "pending",
  "createdAt": "2026-04-03T10:00:00+09:00",
  "validationWarnings": []
}
```

#### バリデーション

* `recipientName` 未指定 → `400 Bad Request`
* `from` または `to` 未指定 → `400 Bad Request`
* `weightKg` が上限超過 → `400 Bad Request`

### 5.2.2 配送参照

* `GET /api/shipments/{trackingId}`

```json
{
  "trackingId": "QS-001",
  "status": "delivered",
  "senderName": "田中太郎",
  "recipientName": "佐藤花子",
  "from": "東京都千代田区",
  "to": "大阪府大阪市",
  "weightKg": 10,
  "sizeCm": "40x30x20",
  "note": "割れ物注意",
  "createdAt": "2026-04-01T09:00:00+09:00"
}
```

---

## 6. APIM 設定方針

本サンプルの APIM は、以下の 2 つの MCP server を提供する：

1. **Existing MCP server**（①の公開）
   * Function App A（`/runtime/webhooks/mcp`）を、APIM の MCP Servers として登録して公開する
   * ① の tools は Function App A が定義する（APIM 側では tools を定義しない）
2. **REST API as MCP server**（②の公開）
   * Function App B の REST API を APIM に取り込み、操作（operations）を tools として公開する
   * 例：`POST /api/shipments`、`GET /api/shipments/{trackingId}` を tools として選択

補足：APIM の MCP server は Streamable HTTP を利用する。ポリシーでレスポンスボディを参照するとストリーミング挙動を阻害し得るため、MCP server スコープ/グローバルスコープの診断設定やポリシー設計に注意する。

補足：REST 側は `/api/*` としてそのまま中継し、MCP 側のみ APIM で URI Rewrite して `/runtime/webhooks/mcp` に転送する。

### セキュリティ

* APIM Subscription Key を（サンプルでは）利用する
  * APIM 側設定により Subscription Key を不要にすることも可能であるため、テストスクリプト等は **Key が無い環境でも動作できる**ようにしておく
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
      shipments.json
    rest_function/
      function_app.py
      shipments.py
      shipments.json
  README.md
```

---

## 8. azd 要件

* `azd up` で以下を実施

  * Resource Group 作成
  * Function Apps (2つ) 作成・デプロイ（Flex Consumption）
  * Storage Account 作成（Functions のホストストレージ）
  * APIM 作成・API登録
  * APIM の MCP Servers 作成
    * Existing MCP server（①）
    * REST API as MCP server（②）
  * Application Insights 作成

### 出力

* APIM Gateway URL
* MCP Server URL（①: 配送追跡/配送詳細/配送ルールなど参照系）
* MCP Server URL（②: 配送登録/配送参照を tools として公開）
* Subscription Key（デモ用途）

---

## 9. 受け入れ条件

* `azd up` のみで環境構築可能
* APIM 経由で以下が成功する（いずれも MCP tools として）

  * ① の MCP server に対して `tools/list`
  * ① の MCP server に対して `tools/call track_shipment`
  * ② の MCP server に対して `tools/list`（配送系 tools が列挙される）
  * ② の MCP server に対して 配送登録の tool 呼び出し
  * （任意）② の MCP server に対して 配送参照の tool 呼び出し
* 配送データ定義が ①②で一致している

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
