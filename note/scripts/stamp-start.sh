#!/usr/bin/env bash
# UserPromptSubmit 훅 — 턴/세션 시작 시각을 기록한다.
#
# 경과 시간을 트랜스크립트가 아니라 이 상태 파일로 재는 이유:
# 트랜스크립트 내부 레코드 구조가 바뀌어도 타이밍이 깨지지 않게 하기 위해서다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 공통 라이브러리가 없으면 조용히 끝낸다 — 훅이 nonzero 로 죽으면 안 된다.
[ -f "$HERE/lib/common.sh" ] || exit 0
. "$HERE/lib/common.sh"

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION" ] || exit 0

mkdir -p "$CC_NOTIFY_STATE_DIR" 2>/dev/null || exit 0
NOW=$(date +%s)

printf '%s\n' "$NOW" > "$CC_NOTIFY_STATE_DIR/$SESSION.turn" 2>/dev/null || true
[ -f "$CC_NOTIFY_STATE_DIR/$SESSION.session" ] || \
  printf '%s\n' "$NOW" > "$CC_NOTIFY_STATE_DIR/$SESSION.session" 2>/dev/null || true

exit 0
