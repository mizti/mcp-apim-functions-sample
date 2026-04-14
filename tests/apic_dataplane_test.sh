#!/bin/sh

# =============================================================================
# API Center データプレーン REST API テストスクリプト
# =============================================================================
# Azure API Center のデータプレーン REST API を使って、
# 登録済み API 定義・MCP ツール定義を読み出すテストを行います。
# エージェントが API Center から MCP 等をディスカバリするシナリオを想定しています。
#
# Usage:
#   ./tests/apic_dataplane_test.sh
#
# Prerequisites:
#   - az CLI でログイン済み（az login）
#   - azd 環境が存在すること
#   - API Center が作成済みで APIM と連携済みであること
#   - API Center ポータルの Entra ID 認証がセットアップ済みであること
#     （Azure Portal > API Center > API Center portal > Settings > Configure Entra ID）
#   - 実行ユーザーに Azure API Center Data Reader ロールが付与済みであること
#   - jq がインストール済み
#
# Authentication:
#   データプレーン API は Entra ID アプリ登録経由でアクセスします。
#   ポータルセットアップで自動作成されるアプリ登録の Client ID を使って
#   デバイスコードフローで認証します。
#
# Environment variables (auto-detected from azd, or override manually):
#   APIC_SERVICE_NAME   - API Center のサービス名
#   APIC_REGION         - API Center のリージョン (例: japaneast, eastus)
#   APIC_CLIENT_ID      - Entra ID アプリ登録の Client ID (必須)
#   APIC_TENANT_ID      - Entra ID テナント ID
#   APIC_RESOURCE_GROUP - リソースグループ (自動検出用)
#   AZURE_SUBSCRIPTION_ID - サブスクリプション ID (自動検出用)
#
# Data Plane API reference:
#   https://learn.microsoft.com/en-us/rest/api/dataplane/apicenter/operation-groups
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

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
if ! has_cmd jq; then
  printf '%s[ERROR]%s jq が必要です。インストールしてください。\n' "$RED" "$NC"
  exit 1
fi

if ! has_cmd az; then
  printf '%s[ERROR]%s Azure CLI (az) が必要です。\n' "$RED" "$NC"
  exit 1
fi

# ---------------------------------------------------------------------------
# Temp files (cleaned up on exit)
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AZD_ENV="${AZD_ENV:-}"
DATA_API_VERSION="2024-02-01-preview"

if has_cmd azd; then
  if [ -z "$AZD_ENV" ]; then
    AZD_ENV=$(azd env list 2>/dev/null | grep -i "true" | awk '{print $1}') || true
  fi
  if [ -n "$AZD_ENV" ]; then
    info "azd 環境 ($AZD_ENV) から設定を読み込み中..."
    while IFS='=' read -r key value; do
      key=$(printf '%s' "$key" | tr -d '"' | tr -d "'")
      value=$(printf '%s' "$value" | sed "s/^[\"']//;s/[\"']$//")
      case "$key" in
        AZURE_SUBSCRIPTION_ID) AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$value}" ;;
        AZURE_LOCATION)        AZURE_LOCATION="${AZURE_LOCATION:-$value}" ;;
        AZURE_ENV_NAME)        AZURE_ENV_NAME="${AZURE_ENV_NAME:-$value}" ;;
      esac
    done <<EOF
$(azd env get-values -e "$AZD_ENV" 2>/dev/null || true)
EOF
  fi
fi

SERVICE_NAME="${APIC_SERVICE_NAME:-}"
REGION="${APIC_REGION:-${AZURE_LOCATION:-}}"
RESOURCE_GROUP="${APIC_RESOURCE_GROUP:-}"
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
CLIENT_ID="${APIC_CLIENT_ID:-}"
TENANT_ID="${APIC_TENANT_ID:-}"

# Fallback resource group name
if [ -z "$RESOURCE_GROUP" ] && [ -n "${AZURE_ENV_NAME:-${AZD_ENV:-}}" ]; then
  RESOURCE_GROUP="rg-${AZURE_ENV_NAME:-${AZD_ENV}}"
fi

# Auto-detect API Center service name if not set
# NOTE: API Center は IaC の構築対象外のため、サブスクリプション全体から検索する
if [ -z "$SERVICE_NAME" ] && [ -n "$SUBSCRIPTION_ID" ]; then
  info "API Center サービス名を自動検出中（サブスクリプション全体）..."
  APIC_RESOURCE_JSON=$(az resource list \
    --resource-type "Microsoft.ApiCenter/services" \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[0].{name:name, rg:resourceGroup, location:location}" -o json 2>/dev/null) || true
  if [ -n "$APIC_RESOURCE_JSON" ] && [ "$APIC_RESOURCE_JSON" != "null" ]; then
    SERVICE_NAME=$(printf '%s' "$APIC_RESOURCE_JSON" | jq -r '.name // empty')
    DETECTED_RG=$(printf '%s' "$APIC_RESOURCE_JSON" | jq -r '.rg // empty')
    DETECTED_REGION=$(printf '%s' "$APIC_RESOURCE_JSON" | jq -r '.location // empty')
    [ -n "$DETECTED_RG" ] && RESOURCE_GROUP="$DETECTED_RG"
    [ -z "$REGION" ] && [ -n "$DETECTED_REGION" ] && REGION="$DETECTED_REGION"
    info "検出: ${SERVICE_NAME} (RG: ${RESOURCE_GROUP}, Region: ${REGION})"
  fi
fi

# それでも見つからない場合は入力を求める
if [ -z "$SERVICE_NAME" ]; then
  warn "API Center サービスが自動検出できませんでした"
  printf '  APIC_SERVICE_NAME を入力してください: '
  read -r SERVICE_NAME
fi

# Auto-detect region from the API Center resource if not set
if [ -z "$REGION" ] && [ -n "$SERVICE_NAME" ] && [ -n "$RESOURCE_GROUP" ] && [ -n "$SUBSCRIPTION_ID" ]; then
  info "API Center リージョンを自動検出中..."
  REGION=$(az resource show \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.ApiCenter/services" \
    --name "$SERVICE_NAME" \
    --subscription "$SUBSCRIPTION_ID" \
    --query "location" -o tsv 2>/dev/null) || true
fi

# Auto-detect tenant ID
if [ -z "$TENANT_ID" ]; then
  TENANT_ID=$(az account show --query "tenantId" -o tsv 2>/dev/null) || true
fi

# Auto-detect Client ID: look for the app registration created by API Center portal setup
# Convention: <api-center-name>-apic-aad
if [ -z "$CLIENT_ID" ] && [ -n "$SERVICE_NAME" ]; then
  info "Entra ID アプリ登録 (${SERVICE_NAME}-apic-aad) を検索中..."
  CLIENT_ID=$(az ad app list \
    --display-name "${SERVICE_NAME}-apic-aad" \
    --query "[0].appId" -o tsv 2>/dev/null) || true
fi

if [ -z "$SERVICE_NAME" ] || [ -z "$REGION" ]; then
  error "必要な設定が見つかりません。以下を確認してください:"
  printf '  APIC_SERVICE_NAME=%s\n' "${SERVICE_NAME:-<未設定>}"
  printf '  APIC_REGION=%s\n' "${REGION:-<未設定>}"
  exit 1
fi

if [ -z "$CLIENT_ID" ]; then
  error "Entra ID アプリ登録の Client ID が見つかりません。"
  info "  API Center ポータルの Entra ID セットアップを完了してから再実行してください。"
  info "  手動指定: APIC_CLIENT_ID=<client-id> ./tests/apic_dataplane_test.sh"
  info "  参照: Azure Portal > API Center > API Center portal > Settings > Configure Entra ID"
  exit 1
fi

# API Center ポータルが作成するアプリ登録は機密クライアント（confidential client）として
# 構成されている。デバイスコードフロー（パブリッククライアントフロー）を使うには
# allowPublicClient を有効にする必要がある。
APP_OBJECT_ID=$(az ad app list --filter "appId eq '${CLIENT_ID}'" --query "[0].id" -o tsv 2>/dev/null) || true
if [ -n "$APP_OBJECT_ID" ]; then
  IS_PUBLIC=$(az ad app show --id "$CLIENT_ID" --query "isFallbackPublicClient" -o tsv 2>/dev/null) || true
  if [ "$IS_PUBLIC" != "true" ]; then
    info "アプリ登録のパブリッククライアントフローを有効化中..."
    az ad app update --id "$CLIENT_ID" --is-fallback-public-client true 2>/dev/null || \
      warn "パブリッククライアントフローの有効化に失敗しました。手動で設定してください: Azure Portal > App registrations > ${SERVICE_NAME}-apic-aad > Authentication > Allow public client flows = Yes"
  fi
fi

BASE_URL="https://${SERVICE_NAME}.data.${REGION}.azure-apicenter.ms"
WORKSPACE="default"

info "API Center: ${SERVICE_NAME} (Region: ${REGION})"
info "Data Plane URL: ${BASE_URL}"
info "Client ID: ${CLIENT_ID}"
info "Tenant ID: ${TENANT_ID}"

# ---------------------------------------------------------------------------
# Acquire data plane access token via device code flow
# ---------------------------------------------------------------------------
header "認証: データプレーン アクセストークンの取得 (デバイスコードフロー)"

SCOPE="https://azure-apicenter.net/Data.Read.All"

info "デバイスコードフローでトークンを取得します..."

# Step 1: Request device code
DEVICE_CODE_RESPONSE=$(curl -sS -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/devicecode" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=${CLIENT_ID}&scope=${SCOPE}" 2>&1)

USER_CODE=$(printf '%s' "$DEVICE_CODE_RESPONSE" | jq -r '.user_code // empty' 2>/dev/null)
DEVICE_CODE=$(printf '%s' "$DEVICE_CODE_RESPONSE" | jq -r '.device_code // empty' 2>/dev/null)
VERIFICATION_URI=$(printf '%s' "$DEVICE_CODE_RESPONSE" | jq -r '.verification_uri // empty' 2>/dev/null)
INTERVAL=$(printf '%s' "$DEVICE_CODE_RESPONSE" | jq -r '.interval // 5' 2>/dev/null)

if [ -z "$DEVICE_CODE" ] || [ -z "$USER_CODE" ]; then
  error "デバイスコードの取得に失敗しました"
  info "  アプリ登録にデバイスコードフロー用のリダイレクト URI が設定されていない可能性があります"
  info "  Response: $(printf '%s' "$DEVICE_CODE_RESPONSE" | head -c 500)"
  exit 1
fi

printf '\n  %s========================================%s\n' "$YELLOW" "$NC"
printf '  以下の URL にアクセスしてコードを入力してください:\n'
printf '    URL:  %s%s%s\n' "$GREEN" "$VERIFICATION_URI" "$NC"
printf '    Code: %s%s%s\n' "$GREEN" "$USER_CODE" "$NC"
printf '  %s========================================%s\n\n' "$YELLOW" "$NC"

# Step 2: Poll for token
ACCESS_TOKEN=""
POLL_ATTEMPTS=0
MAX_POLL_ATTEMPTS=60  # 5 min at 5sec intervals

while [ "$POLL_ATTEMPTS" -lt "$MAX_POLL_ATTEMPTS" ]; do
  POLL_ATTEMPTS=$((POLL_ATTEMPTS + 1))
  sleep "$INTERVAL"

  TOKEN_RESPONSE=$(curl -sS -X POST \
    "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=${CLIENT_ID}&device_code=${DEVICE_CODE}&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>&1)

  TOKEN_ERROR=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.error // empty' 2>/dev/null)
  if [ "$TOKEN_ERROR" = "authorization_pending" ]; then
    continue
  elif [ "$TOKEN_ERROR" = "slow_down" ]; then
    INTERVAL=$((INTERVAL + 5))
    continue
  elif [ -n "$TOKEN_ERROR" ] && [ "$TOKEN_ERROR" != "null" ]; then
    error "トークン取得に失敗: $TOKEN_ERROR"
    info "  $(printf '%s' "$TOKEN_RESPONSE" | jq -r '.error_description // empty' 2>/dev/null)"
    exit 1
  fi

  ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)
  if [ -n "$ACCESS_TOKEN" ]; then
    break
  fi
done

if [ -z "$ACCESS_TOKEN" ]; then
  error "トークン取得がタイムアウトしました"
  exit 1
fi

success "アクセストークン取得成功"

# ---------------------------------------------------------------------------
# Helper: data plane GET
# ---------------------------------------------------------------------------
apic_dp_get() {
  local path="$1"
  curl -sS -w "\n%{http_code}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    "${BASE_URL}/workspaces/${WORKSPACE}${path}?api-version=${DATA_API_VERSION}" 2>&1
}

parse_response() {
  local response="$1"
  RESP_CODE=$(printf '%s' "$response" | tail -1)
  RESP_BODY=$(printf '%s' "$response" | sed '$d')
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: API 一覧の取得
# ═══════════════════════════════════════════════════════════════════════════
header "Test 1: API 一覧の取得 (GET /workspaces/default/apis)"

RAW_RESPONSE=$(apic_dp_get "/apis")
parse_response "$RAW_RESPONSE"

APIS_RESPONSE=""
if [ "$RESP_CODE" = "200" ] && printf '%s' "$RESP_BODY" | grep -q '"value"'; then
  API_COUNT=$(printf '%s' "$RESP_BODY" | jq '.value | length')
  success "API 一覧を取得しました (${API_COUNT} 件)"
  printf '%s' "$RESP_BODY" | jq -r '.value[] | "  [\(.kind)] \(.title) (name: \(.name), stage: \(.lifecycleStage))"' 2>/dev/null || true
  APIS_RESPONSE="$RESP_BODY"
else
  error "API 一覧の取得に失敗しました (HTTP ${RESP_CODE})"
  printf '%s\n' "$RESP_BODY" | head -c 500
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: MCP API のみフィルタ
# ═══════════════════════════════════════════════════════════════════════════
header "Test 2: MCP API のフィルタリング"

MCP_APIS=""
MCP_COUNT=0
if [ -n "$APIS_RESPONSE" ]; then
  MCP_APIS=$(printf '%s' "$APIS_RESPONSE" | jq '[.value[] | select(.kind == "mcp")]')
  MCP_COUNT=$(printf '%s' "$MCP_APIS" | jq 'length')

  if [ "$MCP_COUNT" -gt 0 ] 2>/dev/null; then
    success "MCP API を ${MCP_COUNT} 件検出しました"
    printf '%s' "$MCP_APIS" | jq -r '.[] | "  ・\(.title): \(.description // "(説明なし)")"' 2>/dev/null || true
  else
    warn "MCP API が見つかりませんでした"
  fi
else
  warn "API 一覧が未取得のためスキップ"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: REST API のみフィルタ
# ═══════════════════════════════════════════════════════════════════════════
header "Test 3: REST API のフィルタリング"

REST_APIS=""
REST_COUNT=0
if [ -n "$APIS_RESPONSE" ]; then
  REST_APIS=$(printf '%s' "$APIS_RESPONSE" | jq '[.value[] | select(.kind == "rest")]')
  REST_COUNT=$(printf '%s' "$REST_APIS" | jq 'length')

  if [ "$REST_COUNT" -gt 0 ] 2>/dev/null; then
    success "REST API を ${REST_COUNT} 件検出しました"
    printf '%s' "$REST_APIS" | jq -r '.[] | "  ・\(.title): \(.description // "(説明なし)" | split("\n")[0])"' 2>/dev/null || true
  else
    warn "REST API が見つかりませんでした"
  fi
else
  warn "API 一覧が未取得のためスキップ"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: 各 MCP API のバージョン・定義・デプロイメント読み出し
# ═══════════════════════════════════════════════════════════════════════════
header "Test 4: MCP API 詳細 (バージョン / 定義 / デプロイメント)"

MCP_API_NAMES=""
if [ -n "${MCP_APIS}" ] && [ "$MCP_COUNT" -gt 0 ] 2>/dev/null; then
  MCP_API_NAMES=$(printf '%s' "$MCP_APIS" | jq -r '.[].name' 2>/dev/null)
fi

DEPLOYMENT_CACHE_DIR="${TMP_DIR}/deployments"
mkdir -p "$DEPLOYMENT_CACHE_DIR"

for API_NAME in $MCP_API_NAMES; do
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .title')
  printf '\n  %s--- %s (id: %s) ---%s\n' "$YELLOW" "$API_TITLE" "$API_NAME" "$NC"

  # 4a. バージョン一覧
  RAW_RESPONSE=$(apic_dp_get "/apis/${API_NAME}/versions")
  parse_response "$RAW_RESPONSE"

  VERSIONS_BODY=""
  if [ "$RESP_CODE" = "200" ] && printf '%s' "$RESP_BODY" | grep -q '"value"'; then
    VER_COUNT=$(printf '%s' "$RESP_BODY" | jq '.value | length')
    success "  バージョン一覧取得 (${VER_COUNT} 件)"
    printf '%s' "$RESP_BODY" | jq -r '.value[] | "    version: \(.name) / title: \(.title) / stage: \(.lifecycleStage)"' 2>/dev/null || true
    VERSIONS_BODY="$RESP_BODY"
  else
    error "  バージョン一覧の取得に失敗: $API_TITLE (HTTP ${RESP_CODE})"
  fi

  # 4b. 各バージョンの定義一覧
  if [ -n "$VERSIONS_BODY" ]; then
    VERSION_NAMES=$(printf '%s' "$VERSIONS_BODY" | jq -r '.value[].name' 2>/dev/null)
    for VER_NAME in $VERSION_NAMES; do
      RAW_RESPONSE=$(apic_dp_get "/apis/${API_NAME}/versions/${VER_NAME}/definitions")
      parse_response "$RAW_RESPONSE"

      if [ "$RESP_CODE" = "200" ] && printf '%s' "$RESP_BODY" | grep -q '"value"'; then
        DEF_COUNT=$(printf '%s' "$RESP_BODY" | jq '.value | length')
        success "  定義一覧取得 [version=${VER_NAME}] (${DEF_COUNT} 件)"
        printf '%s' "$RESP_BODY" | jq -r '.value[] | "    definition: \(.name) / title: \(.title // "N/A") / spec: \(.specification.name // "N/A") \(.specification.version // "")"' 2>/dev/null || true
      else
        error "  定義一覧の取得に失敗 [version=${VER_NAME}] (HTTP ${RESP_CODE})"
      fi
    done
  fi

  # 4c. デプロイメント一覧 — キャッシュして Test 7/8 で再利用
  RAW_RESPONSE=$(apic_dp_get "/apis/${API_NAME}/deployments")
  parse_response "$RAW_RESPONSE"

  if [ "$RESP_CODE" = "200" ] && printf '%s' "$RESP_BODY" | grep -q '"value"'; then
    DEP_COUNT=$(printf '%s' "$RESP_BODY" | jq '.value | length')
    success "  デプロイメント取得 (${DEP_COUNT} 件)"
    printf '%s' "$RESP_BODY" | jq -r '.value[] | "    deployment: \(.name)\n    server URL: \(.server.runtimeUris // ["(未設定)"] | join(", "))\n    environment: \(.environment // "(未設定)")"' 2>/dev/null || true
    printf '%s' "$RESP_BODY" > "${DEPLOYMENT_CACHE_DIR}/${API_NAME}.json"
  else
    error "  デプロイメント取得に失敗: $API_TITLE (HTTP ${RESP_CODE})"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: REST API の OpenAPI 仕様エクスポート（データプレーン非同期 API）
# ═══════════════════════════════════════════════════════════════════════════
header "Test 5: REST API の定義エクスポート (OpenAPI仕様)"

REST_API_NAMES=""
if [ -n "${REST_APIS}" ] && [ "$REST_COUNT" -gt 0 ] 2>/dev/null; then
  REST_API_NAMES=$(printf '%s' "$REST_APIS" | jq -r '.[].name' 2>/dev/null)
fi

for API_NAME in $REST_API_NAMES; do
  API_TITLE=$(printf '%s' "$REST_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .title')
  printf '\n  %s--- %s (id: %s) ---%s\n' "$YELLOW" "$API_TITLE" "$API_NAME" "$NC"

  RAW_RESPONSE=$(apic_dp_get "/apis/${API_NAME}/versions")
  parse_response "$RAW_RESPONSE"
  VERSION_NAMES=""
  if [ "$RESP_CODE" = "200" ]; then
    VERSION_NAMES=$(printf '%s' "$RESP_BODY" | jq -r '.value[].name' 2>/dev/null)
  fi

  for VER_NAME in $VERSION_NAMES; do
    RAW_RESPONSE=$(apic_dp_get "/apis/${API_NAME}/versions/${VER_NAME}/definitions")
    parse_response "$RAW_RESPONSE"
    DEF_NAMES=""
    if [ "$RESP_CODE" = "200" ]; then
      DEF_NAMES=$(printf '%s' "$RESP_BODY" | jq -r '.value[].name' 2>/dev/null)
    fi

    for DEF_NAME in $DEF_NAMES; do
      EXPORT_URL="${BASE_URL}/workspaces/${WORKSPACE}/apis/${API_NAME}/versions/${VER_NAME}/definitions/${DEF_NAME}:exportSpecification?api-version=${DATA_API_VERSION}"
      EXPORT_HDR_FILE="${TMP_DIR}/export_headers.txt"
      rm -f "$EXPORT_HDR_FILE"

      EXPORT_RESPONSE=$(curl -sS -D "$EXPORT_HDR_FILE" -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        "${EXPORT_URL}" 2>&1)
      parse_response "$EXPORT_RESPONSE"

      if [ "$RESP_CODE" = "202" ] || [ "$RESP_CODE" = "200" ]; then
        OPERATION_URL=$(grep -i "operation-location" "$EXPORT_HDR_FILE" 2>/dev/null | head -1 | sed 's/.*: *//;s/\r//' || true)

        if [ -n "$OPERATION_URL" ]; then
          info "  エクスポート開始 (非同期)。ポーリング中..."
          POLL_ATTEMPTS=0
          MAX_POLLS=10
          EXPORT_RESULT=""
          POLL_STATUS=""

          while [ "$POLL_ATTEMPTS" -lt "$MAX_POLLS" ]; do
            POLL_ATTEMPTS=$((POLL_ATTEMPTS + 1))
            sleep 2
            POLL_RAW=$(curl -sS -w "\n%{http_code}" \
              -H "Authorization: Bearer ${ACCESS_TOKEN}" \
              -H "Accept: application/json" \
              "${OPERATION_URL}" 2>&1)
            parse_response "$POLL_RAW"

            POLL_STATUS=$(printf '%s' "$RESP_BODY" | jq -r '.status // empty' 2>/dev/null)
            if [ "$POLL_STATUS" = "Succeeded" ]; then
              EXPORT_RESULT="$RESP_BODY"
              break
            elif [ "$POLL_STATUS" = "Failed" ] || [ "$POLL_STATUS" = "Canceled" ]; then
              break
            fi
          done

          if [ -n "$EXPORT_RESULT" ]; then
            SPEC_FORMAT=$(printf '%s' "$EXPORT_RESULT" | jq -r '.result.format // "unknown"' 2>/dev/null)
            success "  仕様エクスポート成功 (format: ${SPEC_FORMAT}, definition: ${DEF_NAME})"

            if [ "$SPEC_FORMAT" = "link" ]; then
              SPEC_LINK=$(printf '%s' "$EXPORT_RESULT" | jq -r '.result.value // empty' 2>/dev/null)
              if [ -n "$SPEC_LINK" ]; then
                SPEC_FILE="${TMP_DIR}/spec_${API_NAME}_${DEF_NAME}.json"
                curl -sS -o "$SPEC_FILE" "$SPEC_LINK" 2>/dev/null || true
                if [ -f "$SPEC_FILE" ] && [ -s "$SPEC_FILE" ]; then
                  SPEC_LINES=$(wc -l < "$SPEC_FILE")
                  HAS_OPENAPI=$(grep -q '"openapi"\|"swagger"' "$SPEC_FILE" 2>/dev/null && echo "OpenAPI" || echo "不明")
                  info "  仕様ダウンロード完了 ($SPEC_LINES 行, $HAS_OPENAPI)"
                  if [ "$HAS_OPENAPI" = "OpenAPI" ]; then
                    info "  エンドポイント一覧:"
                    jq -r '.paths | keys[] | "    " + .' "$SPEC_FILE" 2>/dev/null || true
                  fi
                fi
              fi
            else
              info "  仕様 (inline):"
              printf '%s' "$EXPORT_RESULT" | jq -r '.result.value' 2>/dev/null | head -20 || true
            fi
          else
            warn "  仕様エクスポートがタイムアウトまたは失敗 (status: ${POLL_STATUS:-unknown}, definition: ${DEF_NAME})"
          fi
        else
          if printf '%s' "$RESP_BODY" | jq -e '.result' >/dev/null 2>&1; then
            success "  仕様エクスポート成功 (同期応答, definition: ${DEF_NAME})"
          else
            warn "  Operation-Location ヘッダーが見つかりません (definition: ${DEF_NAME})"
          fi
        fi
      else
        warn "  仕様エクスポートをスキップ (HTTP ${RESP_CODE}, definition: ${DEF_NAME})"
      fi
    done
  done
done

# ═══════════════════════════════════════════════════════════════════════════
# Test 6: 環境 (Environment) 一覧の取得
# ═══════════════════════════════════════════════════════════════════════════
header "Test 6: 環境 (Environment) 一覧の取得"

RAW_RESPONSE=$(apic_dp_get "/environments")
parse_response "$RAW_RESPONSE"

if [ "$RESP_CODE" = "200" ] && printf '%s' "$RESP_BODY" | grep -q '"value"'; then
  ENV_COUNT=$(printf '%s' "$RESP_BODY" | jq '.value | length')
  success "環境一覧を取得しました (${ENV_COUNT} 件)"
  printf '%s' "$RESP_BODY" | jq -r '.value[] | "  [\(.kind)] \(.title) (type: \(.server.type // "N/A"))"' 2>/dev/null || true
else
  error "環境一覧の取得に失敗しました (HTTP ${RESP_CODE})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Test 7: MCP サーバー URL の抽出（エージェント接続用）
# ═══════════════════════════════════════════════════════════════════════════
header "Test 7: MCP サーバー URL の抽出（エージェント接続用）"

MCP_SERVER_FOUND=0
for API_NAME in $MCP_API_NAMES; do
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .title')

  CACHE_FILE="${DEPLOYMENT_CACHE_DIR}/${API_NAME}.json"
  if [ ! -f "$CACHE_FILE" ]; then
    continue
  fi

  RUNTIME_URIS=$(jq -r '.value[].server.runtimeUris[]?' "$CACHE_FILE" 2>/dev/null)

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
  API_TITLE=$(printf '%s' "$MCP_APIS" | jq -r --arg n "$API_NAME" '.[] | select(.name == $n) | .title')

  CACHE_FILE="${DEPLOYMENT_CACHE_DIR}/${API_NAME}.json"
  if [ ! -f "$CACHE_FILE" ]; then
    continue
  fi

  RUNTIME_URIS=$(jq -r '.value[].server.runtimeUris[]?' "$CACHE_FILE" 2>/dev/null)

  for BASE_MCP_URL in $RUNTIME_URIS; do
    MCP_SUFFIXES="/mcp /runtime/webhooks/mcp"
    MCP_ENDPOINT=""

    printf '\n  %s--- %s: %s ---%s\n' "$YELLOW" "$API_TITLE" "$BASE_MCP_URL" "$NC"
    info "  runtimeUri (API Center): ${BASE_MCP_URL}"

    for SUFFIX in $MCP_SUFFIXES; do
      CANDIDATE="${BASE_MCP_URL%/}${SUFFIX}"
      info "  試行中: ${CANDIDATE}"
      PROBE_BODY_FILE="${TMP_DIR}/mcp_probe.tmp"
      rm -f "$PROBE_BODY_FILE"
      PROBE=$(curl -s --max-time 8 -w "%{http_code}" -X POST "$CANDIDATE" \
        -o "$PROBE_BODY_FILE" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"apic-probe","version":"1.0"}}}' 2>/dev/null) || PROBE="000"
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

    INIT_HDR_FILE="${TMP_DIR}/mcp_init_hdr.txt"
    INIT_BODY_FILE="${TMP_DIR}/mcp_init_body.txt"
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

    if printf '%s' "$INIT_BODY" | grep -q "serverInfo\|protocolVersion" 2>/dev/null; then
      success "  initialize 成功 (session: ${SESSION_ID:-N/A})"
    else
      error "  initialize 失敗"
      info "  Response: $(printf '%s' "$INIT_BODY" | head -c 500)"
      continue
    fi

    curl -s --max-time 5 -X POST "$MCP_ENDPOINT" \
      -o /dev/null \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      ${SESSION_ID:+-H "mcp-session-id: $SESSION_ID"} \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true

    TOOLS_BODY_FILE="${TMP_DIR}/mcp_tools.txt"
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

    TOOLS_JSON=""
    if printf '%s' "$TOOLS_RAW" | grep -q '^data: ' 2>/dev/null; then
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
