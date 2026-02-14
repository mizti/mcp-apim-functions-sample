#!/bin/sh

# =============================================================================
# Smoke test for APIM (REST + MCP servers)
# =============================================================================
# - Mirrors tests/functions_smoke_test.sh, but targets APIM as the gateway.
# - Validates:
#   - REST API through APIM: POST/GET /api/orders
#   - MCP server (Existing MCP server): tools/list + menu tools/call
#   - MCP server (REST API as MCP server): tools/list + orders tools/call (create)
#
# Usage:
#   ./tests/apim_smoke_test.sh
#
# Required env vars (recommended to set via `azd env set ...`):
#   - apimGatewayUrl (or APIM_BASE_URL)
#
# Optional (only if APIM requires subscription key):
#   - APIM_SUBSCRIPTION_KEY (or apimSubscriptionKey)
#
# For MCP server URLs (pick ONE option per server):
#   Option A (explicit URLs):
#     - APIM_MENU_MCP_SERVER_URL
#     - APIM_ORDERS_MCP_SERVER_URL
#
#   Option B (deterministic from base URL):
#     - APIM_MENU_MCP_BASE_PATH
#     - APIM_ORDERS_MCP_BASE_PATH
#
# URL composition for Option B follows the APIM MCP endpoint convention:
#   ${APIM_BASE_URL}/${BASE_PATH}/mcp
#
# Notes:
# - APIM MCP server URLs depend on how you configured MCP servers in APIM.
# - MCP responses may be SSE-framed; this script prints them for troubleshooting.

set -e

# Curl timeouts (override via env if needed)
# - MCP endpoints may stream or keep connections open depending on configuration.
#   Use a max-time to avoid the script freezing.
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME_REST="${CURL_MAX_TIME_REST:-30}"
CURL_MAX_TIME_MCP="${CURL_MAX_TIME_MCP:-20}"

# Color output (POSIX)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m')

PASSED=0
FAILED=0

info() {
  printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"
}

success() {
  printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1"
  PASSED=$((PASSED + 1))
}

error() {
  printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1"
  FAILED=$((FAILED + 1))
}

warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

curl_rest() {
  # Wrap curl so transient failures/timeouts don't abort the script (set -e).
  # If APIM subscription key is configured, add it automatically.
  if [ -n "$APIM_SUBSCRIPTION_KEY" ]; then
    set -- -H "Ocp-Apim-Subscription-Key: $APIM_SUBSCRIPTION_KEY" "$@"
  fi

  set +e
  out=$(curl -sS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME_REST" \
    -w "\n%{http_code}" \
    "$@")
  rc=$?
  set -e

  if [ $rc -ne 0 ] && [ -z "$out" ]; then
    # Ensure split_curl_response sees an HTTP code line.
    out="\n000"
  fi
  CURL_EXIT_CODE=$rc
  printf '%s' "$out"
}

curl_mcp() {
  # Same as curl_rest, but with MCP-tuned timeout.
  # If APIM subscription key is configured, add it automatically.
  if [ -n "$APIM_SUBSCRIPTION_KEY" ]; then
    set -- -H "Ocp-Apim-Subscription-Key: $APIM_SUBSCRIPTION_KEY" "$@"
  fi

  set +e
  out=$(curl -sS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME_MCP" \
    -w "\n%{http_code}" \
    "$@")
  rc=$?
  set -e

  if [ $rc -ne 0 ] && [ -z "$out" ]; then
    out="\n000"
  fi
  CURL_EXIT_CODE=$rc
  printf '%s' "$out"
}

pretty_json() {
  input=$(cat)
  if [ -z "$input" ]; then
    return
  fi

  if has_cmd jq; then
    if printf '%s\n' "$input" | jq . >/dev/null 2>&1; then
      printf '%s\n' "$input" | jq .
      return
    fi
  fi

  printf '%s\n' "$input"
}

dump_body_mcp() {
  body="$1"
  if printf '%s' "$body" | grep -q '^data:'; then
    printf '%s\n' "$body" | while IFS= read -r line; do
      case "$line" in
        data:*)
          payload=${line#data: }
          printf '%s\n' "data:"
          printf '%s\n' "$payload" | pretty_json
          ;;
        *)
          printf '%s\n' "$line"
          ;;
      esac
    done
  else
    printf '%s\n' "$body" | pretty_json
  fi
}

split_curl_response() {
  HTTP_CODE=$(printf '%s\n' "$1" | tail -n 1)
  BODY=$(printf '%s\n' "$1" | sed '$d')
}

extract_mcp_json() {
  # Extract the first JSON object from an MCP response that may be SSE-framed.
  # Supported route (the only one we care about here):
  #   event: message
  #   data:
  #   { ...multi-line JSON... }
  #   event: close
  #
  # Strategy:
  # - Drop SSE `event:` lines
  # - Drop empty `data:` lines
  # - Strip `data:` prefix if payload is on the same line
  # - Print from the first line that starts with '{' to the first line that is exactly '}'
  printf '%s\n' "$1" \
    | tr -d '\r' \
    | sed -e '/^event:/d' -e '/^data:[[:space:]]*$/d' -e 's/^data:[[:space:]]*//' \
    | awk '
      BEGIN { in_json = 0 }
      {
        if (in_json == 0) {
          if ($0 ~ /^[[:space:]]*\{/) { in_json = 1; print }
          next
        }
        print
        if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit
      }
    '
}

mcp_has_error() {
  body="$1"
  json=$(extract_mcp_json "$body")
  if [ -z "$json" ]; then
    echo no
    return
  fi

  if printf '%s' "$json" | grep -Eq '"error"[[:space:]]*:'; then
    echo yes
  else
    echo no
  fi
}

extract_json_string_field() {
  # Extract a top-level JSON string field value without jq.
  # Usage: extract_json_string_field "<json>" "orderId"
  json="$1"
  key="$2"
  printf '%s' "$json" \
    | tr -d '\n\r' \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -n 1
}

# =============================================================================
# Load env values (optional)
# =============================================================================
if has_cmd azd; then
  info "Loading azd environment values..."
  # shellcheck disable=SC2046
  eval "$(azd env get-values)"
else
  warn "azd not found; relying on existing environment variables"
fi

APIM_BASE_URL="${apimGatewayUrl:-${APIM_BASE_URL:-}}"
APIM_SUBSCRIPTION_KEY="${apimSubscriptionKey:-${APIM_SUBSCRIPTION_KEY:-}}"

export APIM_MENU_MCP_BASE_PATH="/menu-mcp/runtime/webhooks"
export APIM_ORDERS_MCP_BASE_PATH="/restaurant-order-mcp"

# These are not produced by Bicep outputs in this repo; set them explicitly.
#
# You can either pass full URLs (APIM_*_MCP_SERVER_URL) or pass base paths and
# let the script compose URLs as ${APIM_BASE_URL}/${BASE_PATH}/mcp.
MENU_MCP_URL="${apimMenuMcpServerUrl:-${APIM_MENU_MCP_SERVER_URL:-}}"
ORDERS_MCP_URL="${apimOrdersMcpServerUrl:-${APIM_ORDERS_MCP_SERVER_URL:-}}"
MENU_MCP_BASE_PATH="${apimMenuMcpBasePath:-${APIM_MENU_MCP_BASE_PATH:-}}"
ORDERS_MCP_BASE_PATH="${apimOrdersMcpBasePath:-${APIM_ORDERS_MCP_BASE_PATH:-}}"

if [ -z "$MENU_MCP_URL" ] && [ -n "$MENU_MCP_BASE_PATH" ]; then
  MENU_MCP_URL="${APIM_BASE_URL%/}/${MENU_MCP_BASE_PATH#/}/mcp"
fi

if [ -z "$ORDERS_MCP_URL" ] && [ -n "$ORDERS_MCP_BASE_PATH" ]; then
  ORDERS_MCP_URL="${APIM_BASE_URL%/}/${ORDERS_MCP_BASE_PATH#/}/mcp"
fi

if [ -z "$APIM_BASE_URL" ]; then
  error "APIM base URL is not set (expected apimGatewayUrl or APIM_BASE_URL)"
  exit 1
fi

if [ -z "$APIM_SUBSCRIPTION_KEY" ]; then
  warn "APIM subscription key is not set; assuming APIM doesn't require it"
fi

if [ -z "$MENU_MCP_URL" ]; then
  error "Menu MCP server URL is not set (expected APIM_MENU_MCP_SERVER_URL or APIM_MENU_MCP_BASE_PATH)"
  exit 1
fi

if [ -z "$ORDERS_MCP_URL" ]; then
  error "Orders MCP server URL is not set (expected APIM_ORDERS_MCP_SERVER_URL or APIM_ORDERS_MCP_BASE_PATH)"
  exit 1
fi

info "APIM base URL: $APIM_BASE_URL"
info "Menu MCP server URL: $MENU_MCP_URL"
info "Orders MCP server URL: $ORDERS_MCP_URL"

# =============================================================================
# REST tests (via APIM)
# =============================================================================
info "=========================================="
info "REST API smoke tests (via APIM)"
info "=========================================="

info "Test REST-1: POST /api/orders"
IDEMPOTENCY_KEY="apim-smoke-$(date +%s)"
REST_ORDER_REQUEST='{
  "menuVersion": "v1",
  "items": [
    { "menuItemId": "ramen-shoyu", "quantity": 1 }
  ],
  "note": "apim smoke test",
  "pickupTime": "2026-02-04T13:30:00+09:00"
}'

info "REST request body:"
printf '%s\n' "$REST_ORDER_REQUEST" | pretty_json

RESPONSE=$(curl_rest -X POST "${APIM_BASE_URL%/}/api/orders" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
  -d "$REST_ORDER_REQUEST")
split_curl_response "$RESPONSE"

info "REST response body (HTTP $HTTP_CODE):"
printf '%s\n' "$BODY" | pretty_json

ORDER_ID=""
if [ "$HTTP_CODE" = "200" ]; then
  if has_cmd jq; then
    ORDER_ID=$(printf '%s\n' "$BODY" | jq -r '.orderId // empty' 2>/dev/null || true)
  else
    ORDER_ID=$(extract_json_string_field "$BODY" "orderId" || true)
  fi

  if [ -n "$ORDER_ID" ]; then
    success "Order created via APIM (HTTP $HTTP_CODE, orderId=$ORDER_ID)"
  else
    error "Order created via APIM but orderId missing"
  fi
else
  error "POST /api/orders via APIM failed (HTTP $HTTP_CODE)"
fi

if [ -n "$ORDER_ID" ]; then
  info "Test REST-2: GET /api/orders/{orderId}"
  RESPONSE=$(curl_rest -X GET "${APIM_BASE_URL%/}/api/orders/$ORDER_ID" \
    )
  split_curl_response "$RESPONSE"

  info "REST response body (HTTP $HTTP_CODE):"
  printf '%s\n' "$BODY" | pretty_json

  if [ "$HTTP_CODE" = "200" ]; then
    success "Order fetched via APIM (HTTP $HTTP_CODE)"
  else
    error "GET /api/orders/{orderId} via APIM failed (HTTP $HTTP_CODE)"
  fi
else
  warn "Skipping REST-2 (orderId not available)"
fi

# =============================================================================
# MCP tests (via APIM) - Menu MCP server (Existing MCP server)
# =============================================================================
info "=========================================="
info "MCP (menu) smoke tests (via APIM)"
info "=========================================="

info "Test MCP-MENU-1: tools/list"
RESPONSE=$(curl_mcp -X POST "$MENU_MCP_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "menu tools/list succeeded (HTTP $HTTP_CODE)"
else
  error "menu tools/list failed (HTTP $HTTP_CODE, curlExit=$CURL_EXIT_CODE)"
fi
dump_body_mcp "$BODY"

info "Test MCP-MENU-2: tools/call get_list_menus"
RESPONSE=$(curl_mcp -X POST "$MENU_MCP_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_list_menus","arguments":{}}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "menu tools/call get_list_menus succeeded (HTTP $HTTP_CODE)"
else
  error "menu tools/call get_list_menus failed (HTTP $HTTP_CODE, curlExit=$CURL_EXIT_CODE)"
fi
dump_body_mcp "$BODY"

# =============================================================================
# MCP tests (via APIM) - Orders MCP server (REST API as MCP server)
# =============================================================================
info "=========================================="
info "MCP (orders) smoke tests (via APIM)"
info "=========================================="

info "Test MCP-ORDERS-1: tools/list"
info "Calling: $ORDERS_MCP_URL (maxTime=${CURL_MAX_TIME_MCP}s)"
RESPONSE=$(curl_mcp -X POST "$ORDERS_MCP_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "orders tools/list succeeded (HTTP $HTTP_CODE)"
else
  error "orders tools/list failed (HTTP $HTTP_CODE, curlExit=$CURL_EXIT_CODE)"
fi
dump_body_mcp "$BODY"

# Tool names are generated by APIM from OpenAPI and are stable in this sample.
# Parsing `tools/list` is brittle due to SSE framing differences, so we keep the
# `tools/list` call above as a health check, but hardcode tool names for calls.
CREATE_TOOL="createAnOrder"

info "Test MCP-ORDERS-2: tools/call $CREATE_TOOL"
ORDERS_CREATE_ARGS_DIRECT='{
  "menuVersion": "v1",
  "items": [
    { "menuItemId": "ramen-shoyu", "quantity": 1 }
  ],
  "note": "apim mcp smoke test",
  "pickupTime": "2026-02-04T13:30:00+09:00"
}'

MCP_IDEMPOTENCY_KEY="apim-mcp-smoke-$(date +%s)"
ORDERS_CREATE_ARGS_WRAPPED="{\"Idempotency-Key\":\"$MCP_IDEMPOTENCY_KEY\",\"CreateOrderRequest\":$ORDERS_CREATE_ARGS_DIRECT}"

# Attempt A: arguments = { Idempotency-Key, CreateOrderRequest }
RESPONSE=$(curl_mcp -X POST "$ORDERS_MCP_URL" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"$CREATE_TOOL\",\"arguments\":$ORDERS_CREATE_ARGS_WRAPPED}}")
split_curl_response "$RESPONSE"

HAS_ERROR=$(mcp_has_error "$BODY" || true)
if [ "$HTTP_CODE" = "200" ] && [ "$HAS_ERROR" = "no" ]; then
  success "orders tools/call $CREATE_TOOL succeeded (wrapped CreateOrderRequest)"
else
  warn "orders tools/call (wrapped CreateOrderRequest) may have failed (HTTP $HTTP_CODE, error=$HAS_ERROR); trying direct args"

  # Attempt B: arguments = request body fields (some gateways flatten)
  RESPONSE=$(curl_mcp -X POST "$ORDERS_MCP_URL" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"$CREATE_TOOL\",\"arguments\":$ORDERS_CREATE_ARGS_DIRECT}}")
  split_curl_response "$RESPONSE"

  HAS_ERROR=$(mcp_has_error "$BODY" || true)
  if [ "$HTTP_CODE" = "200" ] && [ "$HAS_ERROR" = "no" ]; then
    success "orders tools/call $CREATE_TOOL succeeded (direct args)"
  else
    warn "orders tools/call (direct args) may have failed (HTTP $HTTP_CODE, error=$HAS_ERROR); trying wrapped body"

    # Attempt C: arguments = { body: <request> }
    RESPONSE=$(curl_mcp -X POST "$ORDERS_MCP_URL" \
      -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"$CREATE_TOOL\",\"arguments\":{\"body\":$ORDERS_CREATE_ARGS_DIRECT}}}")
    split_curl_response "$RESPONSE"

    HAS_ERROR=$(mcp_has_error "$BODY" || true)
    if [ "$HTTP_CODE" = "200" ] && [ "$HAS_ERROR" = "no" ]; then
      success "orders tools/call $CREATE_TOOL succeeded (wrapped body)"
    else
      error "orders tools/call $CREATE_TOOL failed (HTTP $HTTP_CODE, error=$HAS_ERROR)"
    fi
  fi
fi

dump_body_mcp "$BODY"

# =============================================================================
# Summary
# =============================================================================
info "=========================================="
info "Summary"
info "=========================================="
info "Passed: $PASSED"
info "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
