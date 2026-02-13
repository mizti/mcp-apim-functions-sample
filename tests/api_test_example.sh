#!/bin/sh

# =============================================================================
# 統合テストスクリプト（APIM / FrontDoor 共通）
# =============================================================================
# 引数:
#   apim       APIM_GATEWAY_URL 経由でテスト（デフォルト）
#   frontdoor  API_FRONTDOOR_ENDPOINT_URL 経由でテスト

set -e

# 色付き出力（POSIX: printfでエスケープを生成）
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
NC=$(printf '\033[0m') # No Color

# テスト結果カウンタ
PASSED=0
FAILED=0

# ヘルパー関数
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

split_curl_response() {
    # curlの "body\nhttp_code" 形式から http_code と body を取り出す
    # POSIX互換のため head -n-1 は使わない
    # 使い方: split_curl_response "$RESPONSE"; echo "$HTTP_CODE"; echo "$BODY"
    HTTP_CODE=$(printf '%s\n' "$1" | tail -n 1)
    BODY=$(printf '%s\n' "$1" | sed '$d')
}

make_temp_file() {
    # mktemp の挙動差（GNU/BSD）を吸収
    # Linux(GNU): mktemp
    # macOS(BSD): mktemp -t prefix.XXXXXX
    tmpfile=$(mktemp 2>/dev/null) || tmpfile=$(mktemp -t integration-test.XXXXXX)
    printf '%s' "$tmpfile"
}

MODE="${1:-apim}"
info "テストモード: $MODE"

# 環境変数の取得
info "azd環境変数を読み込み中..."
eval "$(azd env get-values)"

case "$MODE" in
  apim)
    if [ -z "$APIM_GATEWAY_URL" ]; then
        error "APIM_GATEWAY_URL環境変数が設定されていません"
        exit 1
    fi
    API_BASE_URL="${APIM_GATEWAY_URL%/}/v1"
    ;;
  frontdoor)
    if [ -z "$API_FRONTDOOR_ENDPOINT_URL" ]; then
        error "API_FRONTDOOR_ENDPOINT_URL環境変数が設定されていません"
        exit 1
    fi
    API_BASE_URL="${API_FRONTDOOR_ENDPOINT_URL%/}/v1"
    ;;
  *)
    error "未知のモードです: $MODE (apim|frontdoor を指定してください)"
    exit 1
    ;;
esac

info "API Base URL: $API_BASE_URL"

# =============================================================================
# テストケース
# =============================================================================

info "=========================================="
info "統合テスト開始"
info "=========================================="

# Test 1: 申請一覧取得
info "Test 1: GET /applications - 申請一覧取得"
RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_BASE_URL/applications")
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
    success "申請一覧取得成功 (HTTP $HTTP_CODE)"
else
    error "申請一覧取得失敗 (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
fi

# Test 2: 申請作成
info "Test 2: POST /applications - 申請作成"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/applications" \
    -H "Content-Type: application/json" \
    -d '{
        "applicantName": "統合テストユーザー",
        "applicantEmail": "integration-test@example.com",
        "title": "統合テスト申請",
        "reason": "デプロイ後の自動テスト",
        "attachments": []
    }')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    success "申請作成成功 (HTTP $HTTP_CODE)"
    # IDを抽出（次のテストで使用）
    APPLICATION_ID=$(printf '%s\n' "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
    info "作成された申請ID: $APPLICATION_ID"
else
    error "申請作成失敗 (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
    APPLICATION_ID=""
fi

# Test 3: 申請詳細取得
if [ -n "$APPLICATION_ID" ]; then
    info "Test 3: GET /applications/{id} - 申請詳細取得"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_BASE_URL/applications/$APPLICATION_ID")
    split_curl_response "$RESPONSE"

    if [ "$HTTP_CODE" = "200" ]; then
        success "申請詳細取得成功 (HTTP $HTTP_CODE)"
    else
        error "申請詳細取得失敗 (HTTP $HTTP_CODE)"
        echo "Response: $BODY"
    fi
else
    warn "Test 3: スキップ（申請IDが取得できませんでした）"
fi

# Test 4: ファイルアップロード準備
info "Test 4: POST /attachments/prepare_upload - SAS URL取得"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/attachments/prepare_upload" \
    -H "Content-Type: application/json" \
    -d '{
        "fileName": "integration-test.txt"
    }')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ]; then
    success "SAS URL取得成功 (HTTP $HTTP_CODE)"
    UPLOAD_URL=$(printf '%s\n' "$BODY" | sed -n 's/.*"uploadUrl":"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -n "$UPLOAD_URL" ]; then
        info "SAS URLを取得しました"
        
        # Test 4-2: Blob Storageへの実際のアップロード
        info "Test 4-2: Blob Storageへファイルアップロード"
        TEST_FILE=$(make_temp_file)
        echo "This is a test file for integration testing" > "$TEST_FILE"
        
        UPLOAD_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "$UPLOAD_URL" \
            -H "x-ms-blob-type: BlockBlob" \
            -H "Content-Type: text/plain" \
            --data-binary "@$TEST_FILE")
        UPLOAD_HTTP_CODE=$(printf '%s\n' "$UPLOAD_RESPONSE" | tail -n 1)
        
        rm -f "$TEST_FILE"
        
        if [ "$UPLOAD_HTTP_CODE" = "201" ]; then
            success "ファイルアップロード成功 (HTTP $UPLOAD_HTTP_CODE)"
        else
            error "ファイルアップロード失敗 (HTTP $UPLOAD_HTTP_CODE)"
        fi
    fi
else
    error "SAS URL取得失敗 (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
fi

# Test 5: 申請承認（submittedステータスの申請を作成してテスト）
info "Test 5: POST /review/applications/{id}/approve - 申請承認"
# まずsubmittedステータスの申請を作成
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/applications" \
    -H "Content-Type: application/json" \
    -d '{
        "applicantName": "承認テストユーザー",
        "applicantEmail": "approve-test@example.com",
        "title": "承認テスト申請",
        "reason": "承認機能のテスト",
        "attachments": []
    }')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    APPROVE_APP_ID=$(printf '%s\n' "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
    info "承認テスト用申請作成 (ID: $APPROVE_APP_ID)"
    
    # 承認を実行
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/review/applications/$APPROVE_APP_ID/approve" \
        -H "Content-Type: application/json" \
        -d '{
            "comment": "統合テストによる自動承認"
        }')
    split_curl_response "$RESPONSE"
    
    if [ "$HTTP_CODE" = "200" ]; then
        success "申請承認成功 (HTTP $HTTP_CODE)"
        # ステータスがapprovedになっているか確認
        if echo "$BODY" | grep -q '"status":[[:space:]]*"approved"'; then
            success "ステータスがapprovedに変更されました"
        else
            error "ステータスがapprovedになっていません"
        fi
    else
        error "申請承認失敗 (HTTP $HTTP_CODE)"
        echo "Response: $BODY"
    fi
else
    warn "Test 5: スキップ（承認テスト用申請の作成に失敗しました）"
fi

# Test 6: 申請否認
info "Test 6: POST /review/applications/{id}/deny - 申請否認"
# submittedステータスの申請を作成
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/applications" \
    -H "Content-Type: application/json" \
    -d '{
        "applicantName": "否認テストユーザー",
        "applicantEmail": "deny-test@example.com",
        "title": "否認テスト申請",
        "reason": "否認機能のテスト",
        "attachments": []
    }')
split_curl_response "$RESPONSE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    DENY_APP_ID=$(printf '%s\n' "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
    info "否認テスト用申請作成 (ID: $DENY_APP_ID)"
    
    # 否認を実行
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/review/applications/$DENY_APP_ID/deny" \
        -H "Content-Type: application/json" \
        -d '{
            "reason": "統合テストによる自動否認: テスト目的のため却下"
        }')
    split_curl_response "$RESPONSE"
    
    if [ "$HTTP_CODE" = "200" ]; then
        success "申請否認成功 (HTTP $HTTP_CODE)"
        # ステータスがdeniedになっているか確認
        if echo "$BODY" | grep -q '"status":[[:space:]]*"denied"'; then
            success "ステータスがdeniedに変更されました"
        else
            error "ステータスがdeniedになっていません"
        fi
    else
        error "申請否認失敗 (HTTP $HTTP_CODE)"
        echo "Response: $BODY"
    fi
else
    warn "Test 6: スキップ（否認テスト用申請の作成に失敗しました）"
fi

# Test 7: エラーケース - 存在しないIDの取得
info "Test 7: GET /applications/999999 - 存在しないID（エラーケース）"
RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_BASE_URL/applications/999999")
HTTP_CODE=$(printf '%s\n' "$RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "404" ]; then
    success "存在しないIDで404エラーを正しく返却 (HTTP $HTTP_CODE)"
else
    error "期待するHTTP 404ではなく$HTTP_CODEが返却されました"
fi

# Test 8: エラーケース - 承認済み申請の再承認
if [ -n "$APPROVE_APP_ID" ]; then
    info "Test 8: POST /review/applications/{id}/approve - 承認済み申請の再承認（エラーケース）"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE_URL/review/applications/$APPROVE_APP_ID/approve" \
        -H "Content-Type: application/json" \
        -d '{"comment":"再承認"}')
    HTTP_CODE=$(printf '%s\n' "$RESPONSE" | tail -n 1)
    
    if [ "$HTTP_CODE" = "400" ]; then
        success "承認済み申請の再承認で400エラーを正しく返却 (HTTP $HTTP_CODE)"
    else
        error "期待するHTTP 400ではなく$HTTP_CODEが返却されました"
    fi
else
    warn "Test 8: スキップ（承認済み申請IDが取得できませんでした）"
fi

# =============================================================================
# テスト結果サマリー
# =============================================================================

echo ""
info "=========================================="
info "テスト結果サマリー"
info "=========================================="
printf '%s成功: %s%s\n' "$GREEN" "$PASSED" "$NC"
printf '%s失敗: %s%s\n' "$RED" "$FAILED" "$NC"
printf '\n'

if [ $FAILED -eq 0 ]; then
    success "すべてのテストが成功しました！"
    exit 0
else
    error "$FAILED 件のテストが失敗しました"
    exit 1
fi
