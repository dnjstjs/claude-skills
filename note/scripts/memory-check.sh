#!/usr/bin/env bash
# SessionStart 훅 — 근거가 바뀐 메모리에 ⚠ 를 붙이고 요약을 컨텍스트로 올린다.
#
# 낡은 메모리는 도움이 아니라 오염원이다. 한 번이라도 틀린 메모리를 만나면
# 도구 전체를 못 믿게 되므로, 거짓이 될 수 있는 항목을 구조적으로 표시한다.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

STORE="${CC_MEMORY_STORE:-$HOME/claude-memory/np-enterprise}"
INDEX="$STORE/MEMORY.md"
MAX_ENTRIES="${CC_MEMORY_MAX:-200}"
# 항목당 Source 가 있으면 symbol_diff.py 가 git show 를 두 번 포크한다 —
# 항목 수가 늘어날수록 SessionStart 를 막는 시간도 늘어난다. 벽시계 예산으로
# 상한을 건다: 예산을 넘기면 그 시점부터는 검사를 멈추고 기존 표시를 그대로 둔다.
BUDGET_SEC="${CC_MEMORY_BUDGET_SEC:-2}"
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

# 실제 항목 인식 패턴과 동일한 것을 세야 한다 — 느슨한 '^- ' 는 항목이 아닌
# 불릿 텍스트까지 세어 상한을 잘못 건드릴 수 있다. 이전 실행이 남긴 ⚠ 표시도
# 허용해 재실행 시 상한 판정이 흔들리지 않게 한다.
ENTRY_RE='^- (⚠ 삭제됨 |⚠ )?\[[^]]*\]\([^)]+\.md\)'
TOTAL=$(grep -cE "$ENTRY_RE" "$INDEX" || true)
if [ "${TOTAL:-0}" -gt "$MAX_ENTRIES" ]; then
  emit "메모리 ${TOTAL}건 — 상한 ${MAX_ENTRIES}건 초과로 stale 검사를 건너뛰었습니다. 정리 필요."
  exit 0
fi

# symbol_diff.py 가 없으면 심볼 단위 검사를 아예 시도하지 않는다 — 실패한
# 호출의 nonzero 종료를 MISSING 으로 오독해 전체 항목을 거짓으로 삭제됨
# 처리하는 것을, 진짜 삭제와 구분되지 않는 상태로 방치하지 않기 위해서다.
SYMBOL_DIFF="$HERE/symbol_diff.py"
SYMBOL_DIFF_AVAILABLE=1
[ -f "$SYMBOL_DIFF" ] || SYMBOL_DIFF_AVAILABLE=0

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
STALE=""
COUNT=0

# 예산 초과 판정용 시각(마이크로초, 정수). date 를 매 항목마다 포크하지 않도록
# bash 내장 EPOCHREALTIME 을 쓴다.
LOOP_START_US=${EPOCHREALTIME/./}
BUDGET_US=$(( BUDGET_SEC * 1000000 ))
BUDGET_EXCEEDED=0
SKIPPED=0

while IFS= read -r line; do
  if [ "$BUDGET_EXCEEDED" -eq 0 ]; then
    NOW_US=${EPOCHREALTIME/./}
    if [ $(( NOW_US - LOOP_START_US )) -ge "$BUDGET_US" ]; then
      BUDGET_EXCEEDED=1
    fi
  fi

  if [ "$BUDGET_EXCEEDED" -eq 1 ]; then
    # 예산 초과 후: 아직 보지 않은 항목은 손대지 않는다 — 기존 표시를 벗기지도,
    # 새로 계산하지도 않는다. 이전에 계산된 ⚠ 를 예산 부족 때문에 잃는 것은
    # 검사 지연보다 더 나쁘다.
    printf '%s\n' "$line" >> "$TMP"
    if printf '%s' "$line" | grep -qE "$ENTRY_RE"; then
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi

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
  if [ "$SYMBOL_DIFF_AVAILABLE" -eq 1 ] && [ -n "$symbol" ] && [ "${path##*.}" = "py" ]; then
    python3 "$SYMBOL_DIFF" "$REPO" "$path" "$symbol" "$commit" >/dev/null 2>&1
    case $? in
      1) mark="⚠ " ;;
      2) mark="⚠ 삭제됨 " ;;
      *) mark="" ;;
    esac
  else                                          # 파일 단위 폴백 (symbol_diff 부재 포함)
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

MSG=""
[ "$COUNT" -gt 0 ] && MSG="⚠ 재확인 필요 ${COUNT}건: ${STALE}"
if [ "$SYMBOL_DIFF_AVAILABLE" -eq 0 ]; then
  MSG="${MSG}${MSG:+ / }symbol_diff.py 없음 — 심볼 단위 검사를 건너뛰고 파일 단위로만 확인했습니다"
fi
if [ "$SKIPPED" -gt 0 ]; then
  MSG="${MSG}${MSG:+ / }시간 예산(${BUDGET_SEC}초) 초과로 부분 검사 — ${SKIPPED}건 확인 건너뜀(기존 표시 유지)"
fi
[ -n "$MSG" ] && emit "$MSG"
exit 0
