#!/usr/bin/env bash
# SessionStart 훅 — 근거가 바뀐 메모리에 ⚠ 를 붙이고 요약을 컨텍스트로 올린다.
#
# 낡은 메모리는 도움이 아니라 오염원이다. 한 번이라도 틀린 메모리를 만나면
# 도구 전체를 못 믿게 되므로, 거짓이 될 수 있는 항목을 구조적으로 표시한다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 공통 라이브러리가 없으면 조용히 끝낸다 — 훅이 nonzero 로 죽으면 안 된다.
[ -f "$HERE/lib/common.sh" ] || exit 0
. "$HERE/lib/common.sh"

STORE="${CC_MEMORY_STORE:-$HOME/claude-memory/np-enterprise}"
INDEX="$STORE/MEMORY.md"
MAX_ENTRIES="${CC_MEMORY_MAX:-50}"
DEFAULT_REPO="/ssd1/home/wonseon.song/test2/np-enterprise"

# stdin(훅 입력)은 쓰지 않는다. 읽지 않고 그대로 둔다 —
# cat 으로 비우면 터미널에서 수동 실행할 때 입력을 기다리며 멈춘다.

emit() {  # <additionalContext>
  jq -nc --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
}

[ -f "$INDEX" ] || exit 0

REPO=$(cat "$STORE/.repo" 2>/dev/null || printf '%s' "$DEFAULT_REPO")
[ -d "$REPO/.git" ] || exit 0

TOTAL=$(grep -c '^- ' "$INDEX" || true)
if [ "${TOTAL:-0}" -gt "$MAX_ENTRIES" ]; then
  emit "메모리 ${TOTAL}건 — 상한 ${MAX_ENTRIES}건 초과로 stale 검사를 건너뛰었습니다. 정리 필요."
  exit 0
fi

TMP=$(mktemp)
STALE=""
COUNT=0

while IFS= read -r line; do
  # 기존 표시를 제거해 재실행해도 결과가 같게 만든다
  clean=$(printf '%s' "$line" | sed -E 's/^- (⚠ 삭제됨 |⚠ )/- /')

  file=$(printf '%s' "$clean" | sed -nE 's/^- \[[^]]*\]\(([^)]+\.md)\).*/\1/p')
  if [ -z "$file" ] || [ ! -f "$STORE/$file" ]; then
    printf '%s\n' "$clean" >> "$TMP"
    continue
  fi

  src=$(sed -nE 's/^\*\*Source:\*\* *`(.+)`.*/\1/p' "$STORE/$file" | head -1)
  commit=$(printf '%s' "$src" | sed -nE 's/.*@([0-9a-fA-F]{7,40})$/\1/p')
  if [ -z "$commit" ]; then                     # 기준 커밋 없음 -> 검사 건너뜀
    printf '%s\n' "$clean" >> "$TMP"
    continue
  fi

  rest=${src%@*}
  path=${rest%%#*}
  symbol=""
  case "$rest" in *#*) symbol=${rest#*#} ;; esac

  mark=""
  if [ -n "$symbol" ] && [ "${path##*.}" = "py" ]; then
    python3 "$HERE/symbol_diff.py" "$REPO" "$path" "$symbol" "$commit" >/dev/null 2>&1
    case $? in
      1) mark="⚠ " ;;
      2) mark="⚠ 삭제됨 " ;;
      *) mark="" ;;
    esac
  else                                          # 파일 단위 폴백
    if ! git -C "$REPO" cat-file -e "HEAD:$path" 2>/dev/null; then
      mark="⚠ 삭제됨 "
    elif [ -n "$(git -C "$REPO" log --format=%h "$commit..HEAD" -- "$path" 2>/dev/null)" ]; then
      mark="⚠ "
    fi
  fi

  if [ -n "$mark" ]; then
    COUNT=$((COUNT + 1))
    STALE="$STALE${STALE:+, }${file%.md}"
    printf '%s\n' "$(printf '%s' "$clean" | sed -E "s/^- /- $mark/")" >> "$TMP"
  else
    printf '%s\n' "$clean" >> "$TMP"
  fi
done < "$INDEX"

mv "$TMP" "$INDEX" 2>/dev/null || rm -f "$TMP"

[ "$COUNT" -gt 0 ] && emit "⚠ 재확인 필요 ${COUNT}건: ${STALE}"
exit 0
