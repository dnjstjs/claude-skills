#!/usr/bin/env bash
# 훅 스크립트 공통 헬퍼.
#
# 규칙 (스펙 설계 E "견고성 규칙"):
#   - jq -s(slurp) 금지. 줄 하나가 깨지면 전체가 빈 값이 된다.
#     jq -R -r 'fromjson? | ...' 로 줄 단위 스트리밍하면 깨진 줄만 건너뛴다.
#   - tail -n N 금지. 도구 호출이 많은 턴에서 필요한 레코드가 창 밖으로 밀린다.

CC_NOTIFY_STATE_DIR="${CC_NOTIFY_STATE_DIR:-/tmp/claude-notify}"
CC_SLACK_WEBHOOK_FILE="${CC_SLACK_WEBHOOK_FILE:-$HOME/.claude/.slack-webhook}"
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 트랜스크립트에서 lastPrompt 값을 순서대로 모두 출력한다.
_tx_prompts() {  # <transcript>
  [ -f "$1" ] || return 0
  jq -R -r 'fromjson? | select(.type=="last-prompt") | .lastPrompt // empty' "$1" 2>/dev/null
}

tx_last_prompt() {  # <transcript> -> 마지막 사용자 프롬프트
  _tx_prompts "$1" | tail -1
}

tx_count_prompts() {  # <transcript> -> 정수
  local n
  n=$(_tx_prompts "$1" | wc -l | tr -d ' ')
  echo "${n:-0}"
}

tx_count_notes() {  # <transcript> -> /note 로 시작하는 프롬프트 수
  local n
  n=$(_tx_prompts "$1" | grep -c '^/note' || true)
  echo "${n:-0}"
}

tx_ai_title() {  # <transcript> -> 마지막 ai-title
  [ -f "$1" ] || return 0
  jq -R -r 'fromjson? | select(.type=="ai-title") | .aiTitle // empty' "$1" 2>/dev/null | tail -1
}

clean_text() {  # stdin -> 정제된 한 줄. <maxchars>
  python3 "$_COMMON_DIR/clean_text.py" "${1:-200}"
}

slack_send() {  # <text>
  local url
  [ -f "$CC_SLACK_WEBHOOK_FILE" ] || return 0
  url=$(tr -d ' \n' < "$CC_SLACK_WEBHOOK_FILE")
  [ -n "$url" ] || return 0
  curl -s -X POST -H 'Content-type: application/json' \
    --data "$(jq -nc --arg t "$1" '{text:$t}')" \
    "$url" >/dev/null 2>&1 || true
  return 0
}

# 초를 사람이 읽는 형태로 (예: 720 -> "12분", 45 -> "45초", 4000 -> "1시간 6분")
human_duration() {  # <seconds>
  local s="${1:-0}" h m
  if [ "$s" -lt 60 ]; then echo "${s}초"; return 0; fi
  if [ "$s" -lt 3600 ]; then echo "$((s / 60))분"; return 0; fi
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  echo "${h}시간 ${m}분"
}
