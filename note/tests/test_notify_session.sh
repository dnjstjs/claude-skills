#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

. "$HERE/curl_stub.sh"

export CC_NOTIFY_STATE_DIR="$(mktemp -d)"
OUTDIR="$(mktemp -d)"
trap 'rm -rf "$CC_NOTIFY_STATE_DIR" "$OUTDIR"' EXIT
install_curl_stub "$OUTDIR"

NOW=$(date +%s)

# note 0건 + 프롬프트 6건짜리 트랜스크립트를 만든다
NONOTE="$OUTDIR/nonote.jsonl"
: > "$NONOTE"
for i in 1 2 3 4 5 6; do
  jq -nc --arg p "프롬프트$i" '{type:"last-prompt",lastPrompt:$p}' >> "$NONOTE"
done
jq -nc '{type:"ai-title",aiTitle:"긴 세션"}' >> "$NONOTE"

run_end() {  # <transcript> <session_id>
  curl_stub_reset
  mkdir -p "$CC_NOTIFY_STATE_DIR"
  printf '%s\n' "$((NOW - 2820))" > "$CC_NOTIFY_STATE_DIR/$2.session"
  printf '%s\n' "$NOW" > "$CC_NOTIFY_STATE_DIR/$2.turn"
  jq -nc --arg t "$1" --arg s "$2" \
    '{session_id:$s,cwd:"/ssd1/home/wonseon.song/test2/np-enterprise/engine",transcript_path:$t}' \
    | bash "$HERE/../scripts/notify-session.sh"
}

echo "test_notify_session"

# 1. note 0건 + 프롬프트 6건 -> 🧠 경고 붙음
run_end "$NONOTE" "e1"
BODY=$(curl_stub_body)
assert_contains "$BODY" "세션 종료" "요약 전송됨"
assert_contains "$BODY" "47분" "세션 길이"
assert_contains "$BODY" "6턴" "턴 수"
assert_contains "$BODY" "긴 세션" "ai-title"
assert_contains "$BODY" "note 0건" "note 누락 경고 있음"

# 2. note 1건 있는 트랜스크립트 -> 🧠 경고 없음
run_end "$HERE/fixtures/transcript_ok.jsonl" "e2"
BODY=$(curl_stub_body)
case "$BODY" in *"note 0건"*) assert_eq "없음" "있음" "note 있으면 경고 없음" ;;
                *) assert_eq "없음" "없음" "note 있으면 경고 없음" ;; esac

# 3. 짧은 세션(프롬프트 3건, note 0건) -> 🧠 경고 없음
SHORT="$OUTDIR/short.jsonl"
: > "$SHORT"
for i in 1 2 3; do jq -nc --arg p "p$i" '{type:"last-prompt",lastPrompt:$p}' >> "$SHORT"; done
run_end "$SHORT" "e3"
BODY=$(curl_stub_body)
case "$BODY" in *"note 0건"*) assert_eq "없음" "있음" "짧은 세션: 경고 없음" ;;
                *) assert_eq "없음" "없음" "짧은 세션: 경고 없음" ;; esac

# 3b. note 있음 + 프롬프트 6건(>=5) -> 그래도 🧠 경고 없음
# (notes 조건을 무시하고 turns>=5 일 때 무조건 경고하는 버그를 잡기 위한 케이스)
HASNOTE="$OUTDIR/hasnote.jsonl"
: > "$HASNOTE"
for i in 1 2 3 4 5; do jq -nc --arg p "질문$i" '{type:"last-prompt",lastPrompt:$p}' >> "$HASNOTE"; done
jq -nc '{type:"last-prompt",lastPrompt:"/note 확정된 사실"}' >> "$HASNOTE"
run_end "$HASNOTE" "e4"
BODY=$(curl_stub_body)
case "$BODY" in *"note 0건"*) assert_eq "없음" "있음" "note 있고 턴 많아도 경고 없음" ;;
                *) assert_eq "없음" "없음" "note 있고 턴 많아도 경고 없음" ;; esac

# 4. 상태 파일 정리
assert_eq "false" "$([ -f "$CC_NOTIFY_STATE_DIR/e3.session" ] && echo true || echo false)" "상태파일 .session 삭제됨"
assert_eq "false" "$([ -f "$CC_NOTIFY_STATE_DIR/e3.turn" ] && echo true || echo false)" "상태파일 .turn 삭제됨"

# 5. session_id 없음 -> 죽지 않음
echo '{"cwd":"/tmp"}' | bash "$HERE/../scripts/notify-session.sh" && rc=0 || rc=$?
assert_eq "0" "$rc" "session_id 없음: 정상 종료"

finish
