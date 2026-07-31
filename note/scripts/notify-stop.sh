#!/usr/bin/env bash
# Stop 훅 — 오래 걸린 턴만 Slack으로 알린다.
#
# Stop 은 사양상 "Claude가 응답을 마칠 때"마다 발화한다.
# 알림의 실제 용도는 "자리 비운 사이 끝났나"이므로 짧은 턴은 보내지 않는다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 공통 라이브러리가 없으면 조용히 끝낸다 — 훅이 nonzero 로 죽으면 안 된다.
[ -f "$HERE/lib/common.sh" ] || exit 0
. "$HERE/lib/common.sh"

MIN_SEC="${CC_NOTIFY_MIN_SEC:-180}"

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TS=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)

[ -n "$SESSION" ] || exit 0

START_FILE="$CC_NOTIFY_STATE_DIR/$SESSION.turn"
[ -f "$START_FILE" ] || exit 0
START=$(cat "$START_FILE" 2>/dev/null)
case "$START" in ''|*[!0-9]*) exit 0 ;; esac

ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -ge "$MIN_SEC" ] || exit 0

# 요청: 트랜스크립트의 last-prompt (배열 파싱 불필요)
REQ=$(tx_last_prompt "$TS" | clean_text 120)
# 결과: 훅이 준 last_assistant_message. 없으면 요청으로 폴백.
RES=$(printf '%s' "$MSG" | clean_text 200)
[ -n "$RES" ] || RES="$REQ"
[ -n "$RES" ] || RES="(내용 없음)"
[ -n "$REQ" ] || REQ="(내용 없음)"

# 경로: 훅이 준 cwd 의 마지막 2단계 ($(pwd) 는 논리 경로라 쓰지 않는다)
SHORT_CWD=$(short_cwd "$CWD")
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
LOC="$SHORT_CWD"
[ -n "$BRANCH" ] && LOC="$SHORT_CWD · $BRANCH"

TEXT=$(printf '✅ 작업 완료 (%s)\n📁 %s\n📝 요청: %s\n💬 결과: %s' \
  "$(human_duration "$ELAPSED")" "$LOC" "$REQ" "$RES")

slack_send "$TEXT"
exit 0
