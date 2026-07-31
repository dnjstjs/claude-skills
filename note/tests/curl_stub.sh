#!/usr/bin/env bash
# curl 을 가짜로 바꿔 Slack 전송 내용을 파일로 캡처한다.
# 테스트가 실제 Slack 알림을 쏘지 않게 하려는 것이다.
#
# 사용법:
#   . curl_stub.sh
#   install_curl_stub "$WORKDIR"
#   ... 스크립트 실행 ...
#   BODY=$(curl_stub_body)     # 마지막 전송 인자 전체 (없으면 빈 문자열)
#   curl_stub_reset            # 다음 케이스 전에 호출

install_curl_stub() {  # <workdir>
  CURL_STUB_DIR="$1"
  mkdir -p "$CURL_STUB_DIR/bin"
  cat > "$CURL_STUB_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$CURL_STUB_CAPTURE/curl.args"
exit 0
STUB
  chmod +x "$CURL_STUB_DIR/bin/curl"
  export CURL_STUB_CAPTURE="$CURL_STUB_DIR"
  export PATH="$CURL_STUB_DIR/bin:$PATH"
  printf 'fake-webhook-url\n' > "$CURL_STUB_DIR/webhook"
  export CC_SLACK_WEBHOOK_FILE="$CURL_STUB_DIR/webhook"
}

curl_stub_reset() {
  rm -f "$CURL_STUB_CAPTURE/curl.args"
}

curl_stub_body() {
  cat "$CURL_STUB_CAPTURE/curl.args" 2>/dev/null
}

curl_stub_sent() {  # 전송되었으면 true, 아니면 false 를 출력
  [ -f "$CURL_STUB_CAPTURE/curl.args" ] && echo true || echo false
}
