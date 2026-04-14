#!/bin/sh

# =============================================================================
# API Center REST API テストスクリプト（コントロールプレーン）
# =============================================================================
# Azure API Center の管理プレーン REST API を使って、
# 登録済み API 定義・MCP ツール定義を読み出すテストを行います。
#
# Usage:
#   ./tests/apic_rest_api_test.sh
#
# Prerequisites:
#   - az CLI でログイン済み（az login）
#   - azd 環境 apimmcp0403 が存在すること
#   - API Center が作成済みで APIM と連携済みであること
#   - jq がインストール済み（整形出力用、なくても動作可）
#
# Environment variables (auto-detected from azd, or override manually):
#   AZURE_SUBSCRIPTION_ID  - Azure サブスクリプションID
#   APIC_RESOURCE_GROUP    - API Center のリソースグループ
#   APIC_SERVICE_NAME      - API Center のサービス名
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Color output (POSIX)
# ---------------------------------------------------------------------------
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
CYAN=$(printf '\033[0;36m')
NC=$(printf '\033[0m')

PASSED=0
FAILED=0

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"; }
success() { printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; PASSED=$((PASSED + 1)); }
error()   { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1"; FAILED=$((FAILED + 1)); }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }
header()  { printf '\n%s━━━ %s ━━━%s\n' "$CYAN" "$1" "$NC"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

pretty_json() {
  if has_cmd jq; then
    jq '.' 2>/dev/null || cat
  else
    cat
  fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AZD_ENV="${AZD_ENV:-apimmcp0403}"
API_VERSION="2024-03-01"

info "azd 環境 ($AZD_ENV) から設定を読み込み中..."
if has_cmd azd; then
  eval "$(azd env get-values -e "$AZD_ENV" 2>/dev/null)" || true
fi

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
RESOURCE_GROUP="${APIC_RESOURCE_GROUP:-rg-${AZD_ENV}}"
SERVICE_NAME="${APIC_SERVICE_NAME:-}"

# azd env から取得した subscription を az CLI に設定
if [ -n "$SUBSCRIPTION_ID" ]; then
  az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || true
fi

# Auto-detect API Center service name if not set
# API Center は IaC 構築対象外のため azd env には含まれない。
# リソースグループ内の Microsoft.ApiCenter/services を検索して取得する。
if [ -z "$SERVICE_NAME" ]; then
  info "API Center サービス名を自動検出中 (RG: $RESOURCE_GROUP)..."
  SERVICE_NAME=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.ApiCenter/services" \
    --query "[0].name" -o tsv 2>/dev/null) || true
fi

if [ -z "$SUBSCRIPTION_ID" ] || [ -z "$SERVICE_NAME" ]; then
  error "必要な設定が見つかりません。以下を確認してください:"
  printf '  AZURE_SUBSCRIPTION_ID=%s\n' "$SUBSCRIPTION_ID"
  printf '  RESOURCE_GROUP=%s\n' "$RESOURCE_GROUP"
  printf '  APIC_SERVICE_NAME=%s\n' "$SERVICE_NAME"
  exit 1
fi

BASE_URI="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiCenter/services/${SERVICE_NAME}/workspaces/default"

info "API Center: $SERVICE_NAME (RG: $RESOURCE_GROUP)"
info "Base URI: $BASE_URI"

# ---------------------------------------------------------------------------
# Helper: az rest wrapper
# ---------------------------------------------------------------------------
apic_get() {
  # Usage: apic_get <relative_path>
  # Example: apic_get "/apis"
  local path="$1"
  az rest --method get \
    --uri "${BASE_URI}${path}?api-version=${API_VERSION}" \
    2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: API 一覧の取得
# ═══════════════════════════════════════════════════════════════════════════
header "Test 1: API 一覧の取得 (GET .../apis)"

APIS_RESPONSE=$(apic_get "/apis")

if printf '%s' "$APIS_RESPONSE" | grep -q '"value"'; then
  API_COUNT=$(printf '%s' "$APIS_RESPONSE" | jq '.value | length' 2>/dev/null || echo "?")
  success "API 一覧を取得しました (${API_COUNT} 件)"

  # 一覧表示
  printf '%s' "$APIS_RESPONSE" | jq -r '.value[] | "  [\(.properties.kind)] \(.properties.title) (name: \(.name), stage: \(.properties.lifecycleStage))"' 2>/dev/null || true
else
  error "API 一覧の取得に失敗しました"
  printf '%s\n' "$APIS_RESPONSE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: MCP API のみフィルタ
# ═══════════════════════════════════════════════════════════════════════════
header "Test 2: MCP API のフィルタリング"

MCP_APIS=$(printf '%s' "$APIS_RESPONSE" | jq '[.value[] | select(.properties.kind == "mcp")]' 2>/dev/null)
MCP_COUNT=$(printf '%s' "$MCP_APIS" | jq 'length' 2>/dev/null || echo "0")

if [ "$MCP_COUNT" -gt 0 ] 2>/dev/null; then
  success "MCP API を ${MCP_COUNT} 件検出しました"
  printf '%s' "$MCP_APIS" | jq -r '.[] | "  ・\(.properties.title): \(.properties.description // "(説明なし)")"' 2>/dev/null || true
else
  warn "MCP API が見つかりませんでした"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: REST API のみフィルタ
# ═══════════════════════════════════════════════════════════════════════════
header "Test 3: REST API のフィルタリング"

REST_APIS=$(printf '%s' "$APIS_RESPONSE" | jq '[.value[] | select(.properties.kind == "rest")]' 2>/dev/null)
REST_COUNT=$(printf '%s' "$REST_APIS" | jq 'length' 2>/dev/null || echo "0")

if [ "$REST_COUNT" -gt 0 ] 2>/dev/null; then
  success "REST API を ${REST_COUNT} 件検出しました"
  printf '%s' "$REST_APIS" | jq -r '.[] | "  ・\(.properties.title): \(.properties.description // "(説明なし)" | split("\n")[0])"' 2>/dev/null || true
else
  warn "REST API が見つかりませんでした"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: 各 MCP API のバージョン・定義・デプロイメント読み出し
# ═══════════════════════════════════════════════════════════════════════════
header "Test 4: MCP API 詳細 (バージョン / 定義 / デプロイメント)"

MCP_API_NAMES=$(printf '%s' "$MCP_APIS" | jq -r '.[].name' 2>/dev/null)

for API_NAME in $MCP_API_NAMES; do
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .properties.title' 2>/dev/null)
  printf '\n  %s--- %s (id: %s) ---%s\n' "$YELLOW" "$API_TITLE" "$API_NAME" "$NC"

  # 4a. バージョン一覧
  VERSIONS_RESPONSE=$(apic_get "/apis/${API_NAME}/versions")
  if printf '%s' "$VERSIONS_RESPONSE" | grep -q '"value"'; then
    VER_COUNT=$(printf '%s' "$VERSIONS_RESPONSE" | jq '.value | length' 2>/dev/null || echo "?")
    success "  バージョン一覧取得 (${VER_COUNT} 件)"
    printf '%s' "$VERSIONS_RESPONSE" | jq -r '.value[] | "    version: \(.name) / title: \(.properties.title) / stage: \(.properties.lifecycleStage)"' 2>/dev/null || true
  else
    error "  バージョン一覧の取得に失敗: $API_TITLE"
  fi

  # 4b. 各バージョンの定義一覧
  VERSION_NAMES=$(printf '%s' "$VERSIONS_RESPONSE" | jq -r '.value[].name' 2>/dev/null)
  for VER_NAME in $VERSION_NAMES; do
    DEFS_RESPONSE=$(apic_get "/apis/${API_NAME}/versions/${VER_NAME}/definitions")
    if printf '%s' "$DEFS_RESPONSE" | grep -q '"value"'; then
      DEF_COUNT=$(printf '%s' "$DEFS_RESPONSE" | jq '.value | length' 2>/dev/null || echo "?")
      success "  定義一覧取得 [version=${VER_NAME}] (${DEF_COUNT} 件)"
      printf '%s' "$DEFS_RESPONSE" | jq -r '.value[] | "    definition: \(.name) / title: \(.properties.title // "N/A")"' 2>/dev/null || true
    else
      error "  定義一覧の取得に失敗 [version=${VER_NAME}]"
    fi
  done

  # 4c. デプロイメント一覧（MCPサーバーURLを含む）
  DEPLOY_RESPONSE=$(apic_get "/apis/${API_NAME}/deployments")
  if printf '%s' "$DEPLOY_RESPONSE" | grep -q '"value"'; then
    DEP_COUNT=$(printf '%s' "$DEPLOY_RESPONSE" | jq '.value | length' 2>/dev/null || echo "?")
    success "  デプロイメント取得 (${DEP_COUNT} 件)"
    printf '%s' "$DEPLOY_RESPONSE" | jq -r '.value[] | "    deployment: \(.name)\n    server URL: \(.properties.server.runtimeUri // ["(未設定)"] | join(", "))\n    environment: \(.properties.environmentId // "(未設定)")"' 2>/dev/null || true
  else
    error "  デプロイメント取得に失敗: $API_TITLE"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: REST API の OpenAPI 仕様エクスポート
# ═══════════════════════════════════════════════════════════════════════════
header "Test 5: REST API の定義エクスポート (OpenAPI仕様)"

REST_API_NAMES=$(printf '%s' "$REST_APIS" | jq -r '.[].name' 2>/dev/null)

for API_NAME in $REST_API_NAMES; do
  API_TITLE=$(printf '%s' "$REST_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .properties.title' 2>/dev/null)
  printf '\n  %s--- %s (id: %s) ---%s\n' "$YELLOW" "$API_TITLE" "$API_NAME" "$NC"

  # バージョン取得
  VERSIONS_RESPONSE=$(apic_get "/apis/${API_NAME}/versions")
  VERSION_NAMES=$(printf '%s' "$VERSIONS_RESPONSE" | jq -r '.value[].name' 2>/dev/null)

  for VER_NAME in $VERSION_NAMES; do
    # 定義一覧
    DEFS_RESPONSE=$(apic_get "/apis/${API_NAME}/versions/${VER_NAME}/definitions")
    DEF_NAMES=$(printf '%s' "$DEFS_RESPONSE" | jq -r '.value[].name' 2>/dev/null)

    for DEF_NAME in $DEF_NAMES; do
      SPEC_FILE="/tmp/apic_spec_${API_NAME}_${DEF_NAME}.json"

      # az apic コマンドで仕様をエクスポート
      if az apic api definition export-specification \
          --resource-group "$RESOURCE_GROUP" \
          --service-name "$SERVICE_NAME" \
          --api-id "$API_NAME" \
          --version-id "$VER_NAME" \
          --definition-id "$DEF_NAME" \
          --file-name "$SPEC_FILE" >/dev/null 2>&1; then
        SPEC_LINES=$(wc -l < "$SPEC_FILE")
        SPEC_FORMAT=$(grep -q '"openapi"' "$SPEC_FILE" && echo "OpenAPI" || echo "不明")
        success "  仕様エクスポート成功: $SPEC_FILE ($SPEC_LINES 行, $SPEC_FORMAT)"

        # OpenAPI の場合パス一覧を表示
        if [ "$SPEC_FORMAT" = "OpenAPI" ]; then
          info "  エンドポイント一覧:"
          jq -r '.paths | keys[] | "    " + .' "$SPEC_FILE" 2>/dev/null || true
        fi
      else
        warn "  仕様エクスポートをスキップ (定義に仕様が未添付: ${API_TITLE}/${DEF_NAME})"
      fi
    done
  done
done

# ═══════════════════════════════════════════════════════════════════════════
# Test 6: 環境 (Environment) 一覧の取得
# ═══════════════════════════════════════════════════════════════════════════
header "Test 6: 環境 (Environment) 一覧の取得"

ENV_RESPONSE=$(apic_get "/environments")
if printf '%s' "$ENV_RESPONSE" | grep -q '"value"'; then
  ENV_COUNT=$(printf '%s' "$ENV_RESPONSE" | jq '.value | length' 2>/dev/null || echo "?")
  success "環境一覧を取得しました (${ENV_COUNT} 件)"
  printf '%s' "$ENV_RESPONSE" | jq -r '.value[] | "  [\(.properties.kind)] \(.properties.title) (type: \(.properties.server.type // "N/A"))"' 2>/dev/null || true
else
  error "環境一覧の取得に失敗しました"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 7: MCP サーバー URL の抽出（エージェント接続用）
# ═══════════════════════════════════════════════════════════════════════════
header "Test 7: MCP サーバー URL の抽出（エージェント接続用）"

MCP_SERVER_FOUND=0
for API_NAME in $MCP_API_NAMES; do
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .properties.title' 2>/dev/null)

  DEPLOY_RESPONSE=$(apic_get "/apis/${API_NAME}/deployments")
  RUNTIME_URIS=$(printf '%s' "$DEPLOY_RESPONSE" | jq -r '.value[].properties.server.runtimeUri[]?' 2>/dev/null)

  for URI in $RUNTIME_URIS; do
    MCP_SERVER_FOUND=$((MCP_SERVER_FOUND + 1))
    info "  ${API_TITLE}"
    printf '    MCP Server URL: %s%s%s\n' "$GREEN" "${URI}" "$NC"
  done
done

if [ "$MCP_SERVER_FOUND" -gt 0 ]; then
  success "MCP サーバー URL を ${MCP_SERVER_FOUND} 件抽出しました"
else
  warn "MCP サーバー URL が見つかりませんでした（デプロイメントが未設定の可能性）"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 8: MCP サーバーへの疎通確認（tools/list）
# ═══════════════════════════════════════════════════════════════════════════
header "Test 8: MCP サーバーへの疎通確認 (tools/list)"

for API_NAME in $MCP_API_NAMES; do
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .properties.title' 2>/dev/null)

  DEPLOY_RESPONSE=$(apic_get "/apis/${API_NAME}/deployments")
  RUNTIME_URIS=$(printf '%s' "$DEPLOY_RESPONSE" | jq -r '.value[].properties.server.runtimeUri[]?' 2>/dev/null)

  for BASE_URL in $RUNTIME_URIS; do
    # APIM MCP endpoint convention:
    #   runtimeUri from API Center = APIM base path (e.g., .../shipment-mcp)
    #   Actual MCP endpoint = runtimeUri + /mcp  or  runtimeUri + /runtime/webhooks/mcp
    # Try known suffixes to find the working MCP endpoint.
    MCP_SUFFIXES="/mcp /runtime/webhooks/mcp"
    MCP_ENDPOINT=""

    printf '\n  %s--- %s: %s ---%s\n' "$YELLOW" "$API_TITLE" "$BASE_URL" "$NC"
    info "  runtimeUri (API Center): ${BASE_URL}"

    for SUFFIX in $MCP_SUFFIXES; do
      CANDIDATE="${BASE_URL%/}${SUFFIX}"
      info "  試行中: ${CANDIDATE}"
      # SSE responses (chunked/streaming) may keep the connection open.
      # Use a short timeout; if we get HTTP 200 or the body contains serverInfo, it's valid.
      PROBE_BODY_FILE="/tmp/apic_mcp_probe.tmp"
      rm -f "$PROBE_BODY_FILE"
      PROBE=$(curl -s --max-time 8 -w "%{http_code}" -X POST "$CANDIDATE" \
        -o "$PROBE_BODY_FILE" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"apic-probe","version":"1.0"}}}' 2>/dev/null) || PROBE="000"
      # Even on timeout (exit 28), the body may have been received correctly
      PROBE_OK="no"
      if [ "$PROBE" = "200" ]; then
        PROBE_OK="yes"
      elif [ -f "$PROBE_BODY_FILE" ] && grep -q "serverInfo\|protocolVersion" "$PROBE_BODY_FILE" 2>/dev/null; then
        PROBE_OK="yes"
      fi
      if [ "$PROBE_OK" = "yes" ]; then
        MCP_ENDPOINT="$CANDIDATE"
        info "  MCP エンドポイント検出: ${MCP_ENDPOINT} (HTTP ${PROBE})"
        break
      fi
    done

    if [ -z "$MCP_ENDPOINT" ]; then
      error "  MCP エンドポイントが見つかりません (試行: ${MCP_SUFFIXES})"
      continue
    fi

    # Initialize: use temp files for both headers and body to handle SSE properly
    INIT_HDR_FILE="/tmp/apic_mcp_init_hdr.txt"
    INIT_BODY_FILE="/tmp/apic_mcp_init_body.txt"
    rm -f "$INIT_HDR_FILE" "$INIT_BODY_FILE"

    curl -s -D "$INIT_HDR_FILE" --max-time 10 -X POST "$MCP_ENDPOINT" \
      -o "$INIT_BODY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"apic-test","version":"1.0"}}}' 2>/dev/null || true

    SESSION_ID=""
    if [ -f "$INIT_HDR_FILE" ]; then
      SESSION_ID=$(grep -i "mcp-session-id" "$INIT_HDR_FILE" 2>/dev/null | head -1 | sed 's/.*: *//;s/\r//' || true)
    fi
    INIT_BODY=""
    if [ -f "$INIT_BODY_FILE" ]; then
      INIT_BODY=$(cat "$INIT_BODY_FILE" 2>/dev/null || true)
    fi

    # Check if initialize succeeded (look for serverInfo in SSE data or direct JSON)
    if printf '%s' "$INIT_BODY" | grep -q "serverInfo\|protocolVersion" 2>/dev/null; then
      success "  initialize 成功 (session: ${SESSION_ID:-N/A})"
    else
      error "  initialize 失敗"
      info "  Response: $(printf '%s' "$INIT_BODY" | head -c 500)"
      continue
    fi

    # Send initialized notification (fire-and-forget, short timeout)
    curl -s --max-time 5 -X POST "$MCP_ENDPOINT" \
      -o /dev/null \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      ${SESSION_ID:+-H "mcp-session-id: $SESSION_ID"} \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true

    # tools/list (write to temp file to handle SSE)
    TOOLS_BODY_FILE="/tmp/apic_mcp_tools.txt"
    rm -f "$TOOLS_BODY_FILE"
    curl -s --max-time 10 -X POST "$MCP_ENDPOINT" \
      -o "$TOOLS_BODY_FILE" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      ${SESSION_ID:+-H "mcp-session-id: $SESSION_ID"} \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null || true

    TOOLS_RAW=""
    if [ -f "$TOOLS_BODY_FILE" ]; then
      TOOLS_RAW=$(cat "$TOOLS_BODY_FILE" 2>/dev/null || true)
    fi

    # Parse tools from SSE or direct JSON
    TOOLS_JSON=""
    if printf '%s' "$TOOLS_RAW" | grep -q '^data: ' 2>/dev/null; then
      # SSE format: extract JSON from "data:" lines containing "tools"
      TOOLS_JSON=$(printf '%s' "$TOOLS_RAW" | grep '^data: ' | sed 's/^data: //' | grep '"tools"' | head -1 || true)
    else
      TOOLS_JSON="$TOOLS_RAW"
    fi

    if printf '%s' "$TOOLS_JSON" | grep -q '"tools"'; then
      TOOL_COUNT=$(printf '%s' "$TOOLS_JSON" | jq '.result.tools | length' 2>/dev/null || echo "?")
      success "  tools/list 成功 (ツール数: ${TOOL_COUNT})"
      printf '%s' "$TOOLS_JSON" | jq -r '.result.tools[] | "    ・\(.name): \(.description // "(説明なし)" | split("\n")[0])"' 2>/dev/null || true
    else
      error "  tools/list 失敗"
      info "  Response: $(printf '%s' "$TOOLS_RAW" | head -c 500)"
    fi
  done
done

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
header "テスト結果サマリー"

printf '  %sPASSED: %d%s\n' "$GREEN" "$PASSED" "$NC"
if [ "$FAILED" -gt 0 ]; then
  printf '  %sFAILED: %d%s\n' "$RED" "$FAILED" "$NC"
else
  printf '  %sFAILED: %d%s\n' "$GREEN" "$FAILED" "$NC"
fi
printf '\n'

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
