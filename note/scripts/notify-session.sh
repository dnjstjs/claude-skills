#!/usr/bin/env bash
# SessionEnd 훅 — 세션 요약 + /note 누락 경고 + 상태 파일 정리.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 공통 라이브러리가 없으면 조용히 끝낸다 — 훅이 nonzero 로 죽으면 안 된다.
[ -f "$HERE/lib/common.sh" ] || exit 0
. "$HERE/lib/common.sh"

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
TS=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

[ -n "$SESSION" ] || exit 0

TURNS=$(tx_count_prompts "$TS")
NOTES=$(tx_count_notes "$TS")
TITLE=$(tx_ai_title "$TS" | clean_text 80)

DUR=""
START_FILE="$CC_NOTIFY_STATE_DIR/$SESSION.session"
if [ -f "$START_FILE" ]; then
  START=$(cat "$START_FILE" 2>/dev/null)
  case "$START" in
    ''|*[!0-9]*) : ;;
    *) DUR=" · $(human_duration $(( $(date +%s) - START )))" ;;
  esac
fi

SHORT_CWD=$(short_cwd "$CWD")

TEXT="🏁 세션 종료 · ${SHORT_CWD}${DUR} · ${TURNS}턴"
[ -n "$TITLE" ] && TEXT="$TEXT"$'\n'"📌 $TITLE"

# 확정한 사실을 남길 만한 세션이었는데 /note 가 0건이면 알린다.
# 짧은 확인용 세션(프롬프트 5건 미만)은 조용히 넘어간다.
if [ "$NOTES" -eq 0 ] && [ "$TURNS" -ge 5 ]; then
  TEXT="$TEXT"$'\n'"🧠 note 0건 — 확정한 사실이 있었다면 /note 로 남기세요"
fi

slack_send "$TEXT"

rm -f "$CC_NOTIFY_STATE_DIR/$SESSION.turn" "$CC_NOTIFY_STATE_DIR/$SESSION.session" 2>/dev/null || true
exit 0
