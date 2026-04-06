---
name: shipment
description: "配送荷物の登録・参照・追跡・詳細確認・配送ルール参照を MCP 経由で行います。Use when: creating a new shipment, registering a delivery, looking up a shipment by tracking ID, tracking shipment status, checking delivery status, getting shipment details, viewing shipping rules and constraints, sending a package. Requires: Shipment Tracking MCP server and Shipment REST MCP server configured in VS Code."
argument-hint: "Create, look up, or track a shipment (e.g. QS-001), or ask about shipping rules"
---

# Shipment Operations (MCP)

Create, retrieve, and track shipments via two MCP servers exposed through Azure API Management.

## When to Use

- ユーザーが新しい配送荷物を登録・作成したい場合
- 既存の配送荷物を tracking ID で参照したい場合
- 配送状況を追跡したい場合
- 配送の詳細情報（差出人・宛先・重量等）を取得したい場合
- 配送ルール・制約（受付時間・重量制限・禁止物品等）を確認したい場合

## MCP Servers

| Server | APIM Base Path | Purpose |
|--------|---------------|---------|
| Shipment Tracking MCP | `/shipment-mcp` | 追跡・詳細・ルール参照（参照系） |
| Shipment REST MCP | `/shipment-rest-mcp` | 荷物の登録・参照（更新系） |

Both use Streamable HTTP transport.

## Available Tools

### Shipment Tracking MCP (参照系)

#### `track_shipment`
Track a shipment status by tracking ID.
- **Input**: `trackingId` (string, required) — e.g. `QS-001`
- **Output**: `trackingId`, `status`, `lastUpdated`

#### `get_shipment_details`
Get full details for a shipment by tracking ID.
- **Input**: `trackingId` (string, required) — e.g. `QS-001`
- **Output**: `trackingId`, `status`, `senderName`, `recipientName`, `from`, `to`, `weightKg`, `sizeCm`, `createdAt`, `lastUpdated`

#### `get_shipping_rules`
Get shipping rules and constraints.
- **Input**: none
- **Output**: `acceptanceHours`, `maxWeightKg`, `maxSizeCm`, `maxPackagesPerRequest`, `prohibitedItems`, `serviceArea`

### Shipment REST MCP (更新系)

#### `createAShipment` (POST /api/shipments)
Register a new shipment for delivery.
- **Input**:
  - `recipientName` (string, required) — 受取人名
  - `from` (string, required) — 発送元住所
  - `to` (string, required) — 送付先住所
  - `senderName` (string, optional) — 差出人名
  - `weightKg` (number, optional) — 重量 (kg)
  - `sizeCm` (string, optional) — サイズ (例: "40x30x20")
  - `note` (string, optional) — 備考 (例: "割れ物注意")
- **Output**: `trackingId`, `status`, `createdAt`, `validationWarnings`

#### `getAShipment` (GET /api/shipments/{trackingId})
Get an existing shipment by tracking ID.
- **Input**: `trackingId` (string, required)
- **Output**: `trackingId`, `status`, `senderName`, `recipientName`, `from`, `to`, `weightKg`, `sizeCm`, `note`, `createdAt`

## Procedure

1. ルール確認 → `get_shipping_rules` で受付時間・重量制限・禁止物品を確認
2. 荷物登録 → `createAShipment` で必須項目 (`recipientName`, `from`, `to`) を指定して作成。返却される `trackingId` を控える
3. 荷物参照 → `getAShipment` で tracking ID から荷物情報を取得
4. 追跡 → `track_shipment` でステータス確認、`get_shipment_details` で詳細取得

## Shipping Rules (Quick Reference)

- 受付時間: 08:00–20:00
- 最大重量: 30kg
- 最大サイズ: 3辺合計160cm以内
- 1回あたり最大個数: 5個
- 禁止物品: 危険物、動植物
- 対応地域: 全国（離島除く）

最新のルールは `get_shipping_rules` ツールで確認してください。

## Sample Tracking IDs

テスト用サンプルデータ: `QS-001`, `QS-002`, `QS-003`
