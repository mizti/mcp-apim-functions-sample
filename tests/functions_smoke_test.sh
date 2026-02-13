#!/bin/sh

# =============================================================================
# Smoke test for Azure Functions (REST + MCP)
# =============================================================================
# - Reads endpoints from `azd env get-values`
# - Validates REST API and MCP tools per docs/SPECS.md
#
# Usage:
#   ./tests/functions_smoke_test.sh
#
# Notes:
# - This script targets the Function endpoints directly (not APIM).

set -e

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

pretty_json() {
  # Reads from stdin. If jq is available and input is valid JSON, prints formatted JSON.
  # Otherwise, prints the original input.
  input=$(cat)
  if [ -z "$input" ]; then
    return
  fi

  if has_cmd jq; then
    if printf '%s\n' "$input" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$input" | jq .
      return
    fi
  fi

  printf '%s\n' "$input"
}

dump_json_line() {
  # Usage: dump_json_line "<prefix>" "<json>"
  prefix="$1"
  json="$2"
  if [ -n "$prefix" ]; then
    printf '%s\n' "$prefix"
  fi
  printf '%s\n' "$json" | pretty_json
}

dump_body_mcp() {
  # MCP responses may be SSE framed. Print event lines as-is, and pretty-print JSON on `data:` lines.
  body="$1"
  if printf '%s' "$body" | grep -q '^data: '; then
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
    # Not SSE-framed; try to pretty-print as JSON.
    printf '%s\n' "$body" | pretty_json
  fi
}

split_curl_response() {
  HTTP_CODE=$(printf '%s\n' "$1" | tail -n 1)
  BODY=$(printf '%s\n' "$1" | sed '$d')
}

extract_mcp_json() {
  # MCP extension may return SSE-framed output (event:/data:) and/or split output
  # across multiple lines. We robustly extract the first complete JSON object by
  # taking the substring from the first '{' to the last '}'.
  printf '%s' "$1" | "$PY" - <<'PY'
import sys
s = (sys.stdin.read() or "").replace("\r", "")
i = s.find("{")
j = s.rfind("}")
if i != -1 and j != -1 and j > i:
    sys.stdout.write(s[i : j + 1])
PY
}

pick_python() {
  if command -v python3 >/dev/null 2>&1; then
    echo python3
  else
    echo python
  fi
}

PY=$(pick_python)

json_eval() {
  # Usage: json_eval '<python expr that sets __out>'
  # Reads JSON from stdin. Prints __out.
  "$PY" - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read() or "null")
# The caller expression sets __out
__out = None
PY
}

json_get() {
  # Usage: echo "$json" | json_get 'path expression'
  # Example path: obj["result"]["tools"][0]["name"]
  expr="$1"
  "$PY" - <<PY
import json, sys
obj = json.loads(sys.stdin.read() or "null")
try:
    value = (${expr})
except Exception as e:
    print("__ERROR__:" + str(e))
    raise
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

# =============================================================================
# Load env values
# =============================================================================
info "Loading azd environment values..."
# shellcheck disable=SC2046
# (azd outputs KEY="VALUE" lines; eval is intentional)
eval "$(azd env get-values)"

MENU_MCP_ENDPOINT="${menuFunctionMcpEndpoint:-}"
ORDERS_BASE_URL="${ordersFunctionBaseUrl:-}"

if [ -z "$MENU_MCP_ENDPOINT" ]; then
  error "menuFunctionMcpEndpoint is not set (run: azd env get-values)"
  exit 1
fi

if [ -z "$ORDERS_BASE_URL" ]; then
  error "ordersFunctionBaseUrl is not set (run: azd env get-values)"
  exit 1
fi

info "MCP endpoint: $MENU_MCP_ENDPOINT"
info "Orders base URL: $ORDERS_BASE_URL"

# =============================================================================
# REST tests
# =============================================================================
info "=========================================="
info "REST API smoke tests"
info "=========================================="

info "Test REST-1: POST /api/orders"
IDEMPOTENCY_KEY="smoke-$(date +%s)"
REST_ORDER_REQUEST='{
  "menuVersion": "v1",
  "items": [
    { "menuItemId": "ramen-shoyu", "quantity": 1 }
  ],
  "note": "smoke test",
  "pickupTime": "2026-02-04T13:30:00+09:00"
}'

info "REST request body:"
printf '%s\n' "$REST_ORDER_REQUEST" | pretty_json

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${ORDERS_BASE_URL%/}/api/orders" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
  -d "$REST_ORDER_REQUEST")
split_curl_response "$RESPONSE"

info "REST response body (HTTP $HTTP_CODE):"
printf '%s\n' "$BODY" | pretty_json

ORDER_ID=""
if [ "$HTTP_CODE" = "200" ]; then
  # Extract orderId
  ORDER_ID=$(printf '%s' "$BODY" | "$PY" -c 'import json,sys
try:
    obj=json.loads(sys.stdin.read() or "{}")
    print(obj.get("orderId", ""))
except Exception:
    print("")' || true)

  if [ -n "$ORDER_ID" ]; then
    success "Order created (HTTP $HTTP_CODE, orderId=$ORDER_ID)"
  else
    error "Order created but orderId missing"
    printf '%s\n' "$BODY"
  fi
else
  error "POST /api/orders failed (HTTP $HTTP_CODE)"
  printf '%s\n' "$BODY"
fi

if [ -n "$ORDER_ID" ]; then
  info "Test REST-2: GET /api/orders/{orderId}"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${ORDERS_BASE_URL%/}/api/orders/$ORDER_ID")
  split_curl_response "$RESPONSE"

  info "REST response body (HTTP $HTTP_CODE):"
  printf '%s\n' "$BODY" | pretty_json

  if [ "$HTTP_CODE" = "200" ]; then
    # Basic shape checks
    GOT_ID=$(printf '%s' "$BODY" | "$PY" -c 'import json,sys
try:
    obj=json.loads(sys.stdin.read() or "{}")
    print(obj.get("orderId", ""))
except Exception:
    print("")' || true)

    if [ "$GOT_ID" = "$ORDER_ID" ]; then
      success "Order fetched (HTTP $HTTP_CODE)"
    else
      error "Order fetched but orderId mismatch (expected $ORDER_ID, got $GOT_ID)"
      printf '%s\n' "$BODY"
    fi
  else
    error "GET /api/orders/{orderId} failed (HTTP $HTTP_CODE)"
    printf '%s\n' "$BODY"
  fi
else
  warn "Skipping REST-2 (orderId not available)"
fi

# =============================================================================
# MCP tests
# =============================================================================
info "=========================================="
info "MCP (Streamable HTTP) smoke tests"
info "=========================================="

info "Test MCP-1: tools/list"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$MENU_MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
split_curl_response "$RESPONSE"

# MCP: status-code-only validation; always dump response for troubleshooting.
if [ "$HTTP_CODE" = "200" ]; then
  success "tools/list succeeded (HTTP $HTTP_CODE)"
else
  error "tools/list failed (HTTP $HTTP_CODE)"
fi
dump_body_mcp "$BODY"

info "Test MCP-2: tools/call get_list_menus"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$MENU_MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_list_menus","arguments":{}}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "tools/call get_list_menus succeeded (HTTP $HTTP_CODE)"
else
  error "tools/call get_list_menus failed (HTTP $HTTP_CODE)"
fi
dump_body_mcp "$BODY"

info "Test MCP-3: tools/call get_menu_details (ramen-shoyu)"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$MENU_MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_menu_details","arguments":{"itemId":"ramen-shoyu"}}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "tools/call get_menu_details succeeded (HTTP $HTTP_CODE)"
else
  error "tools/call get_menu_details failed (HTTP $HTTP_CODE)"
fi
dump_body_mcp "$BODY"

info "Test MCP-4: tools/call get_constraints"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$MENU_MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_constraints","arguments":{}}}')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
  success "tools/call get_constraints succeeded (HTTP $HTTP_CODE)"
else
  error "tools/call get_constraints failed (HTTP $HTTP_CODE)"
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
