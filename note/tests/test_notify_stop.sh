#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

. "$HERE/curl_stub.sh"

export CC_NOTIFY_STATE_DIR="$(mktemp -d)"
OUTDIR="$(mktemp -d)"
trap 'rm -rf "$CC_NOTIFY_STATE_DIR" "$OUTDIR"' EXIT
install_curl_stub "$OUTDIR"

OK="$HERE/fixtures/transcript_ok.jsonl"
NOW=$(date +%s)

run_stop() {  # <turn_start_epoch> <last_assistant_message>
  curl_stub_reset
  mkdir -p "$CC_NOTIFY_STATE_DIR"
  printf '%s\n' "$1" > "$CC_NOTIFY_STATE_DIR/s1.turn"
  jq -nc --arg t "$OK" --arg m "$2" \
    '{session_id:"s1",cwd:"/ssd1/home/wonseon.song/test2/np-enterprise/engine",transcript_path:$t,last_assistant_message:$m}' \
    | bash "$HERE/../scripts/notify-stop.sh"
}

echo "test_notify_stop"

# 1. 경과 3분 미만 -> 전송 안 함
run_stop "$((NOW - 30))" "짧은 작업 끝"
assert_eq "false" "$(curl_stub_sent)" "3분 미만: 전송 안 함"

# 2. 경과 3분 초과 -> 전송, 요청·결과 모두 채워짐
run_stop "$((NOW - 720))" "AMP 예외 3곳 추가, 테스트 통과."
BODY=$(curl_stub_body)
assert_contains "$BODY" "작업 완료 (12분)" "3분 초과: 경과 표시"
assert_contains "$BODY" "커밋 푸시 부탁" "3분 초과: 요청 채워짐"
assert_contains "$BODY" "AMP 예외 3곳 추가" "3분 초과: 결과 채워짐"
assert_contains "$BODY" "np-enterprise/engine" "3분 초과: 경로 2단계"

# 3. last_assistant_message 없음 -> last-prompt 로 폴백, "확인 불가" 안 나옴
run_stop "$((NOW - 720))" ""
BODY=$(curl_stub_body)
assert_contains "$BODY" "커밋 푸시 부탁" "결과 없음: last-prompt 폴백"
case "$BODY" in *"확인 불가"*) assert_eq "없음" "있음" "결과 없음: '확인 불가' 미출력" ;;
                *) assert_eq "없음" "없음" "결과 없음: '확인 불가' 미출력" ;; esac

# 4. 깨진 줄 포함 트랜스크립트 -> 정상 전송
curl_stub_reset
printf '%s\n' "$((NOW - 720))" > "$CC_NOTIFY_STATE_DIR/s2.turn"
jq -nc --arg t "$HERE/fixtures/transcript_broken.jsonl" \
  '{session_id:"s2",cwd:"/tmp/x/y",transcript_path:$t,last_assistant_message:"결과"}' \
  | bash "$HERE/../scripts/notify-stop.sh"
BODY=$(curl_stub_body)
assert_contains "$BODY" "마지막 프롬프트" "깨진 줄: 정상 전송"

# 5. .turn 파일 없음 -> 죽지 않고 전송도 안 함
curl_stub_reset
rm -f "$CC_NOTIFY_STATE_DIR/s3.turn"
jq -nc --arg t "$OK" '{session_id:"s3",cwd:"/tmp",transcript_path:$t,last_assistant_message:"x"}' \
  | bash "$HERE/../scripts/notify-stop.sh" && rc=0 || rc=$?
assert_eq "0" "$rc" "turn 파일 없음: 정상 종료"
assert_eq "false" "$(curl_stub_sent)" "turn 파일 없음: 전송 안 함"

finish
