# /note 메모리 + 알림 훅 개선 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 세션 간 도메인 판정을 `/note`로 보존하고, git 심볼 단위로 낡은 메모리를 표시하며, Slack 알림을 "매 응답"에서 "오래 걸린 턴 + 세션 종료 요약"으로 바꾼다.

**Architecture:** 순수 bash 훅 스크립트 4개 + Python 헬퍼 2개 + `/note` 스킬 문서. 모든 훅은 `note/scripts/lib/common.sh`를 source해 트랜스크립트 파싱과 Slack 전송을 공유한다. 메모리 실체는 `~/claude-memory/np-enterprise/` 한 곳이고, 프로젝트별 `memory/` 디렉터리를 symlink로 연결한다.

**Tech Stack:** bash, jq, python3(표준 라이브러리 `ast`, `json`, `re`만), git, curl

## Global Constraints

이 값들은 스펙에서 그대로 옮긴 것이다. 모든 태스크에 암묵적으로 적용된다.

- **`jq -s`(slurp) 금지.** 트랜스크립트는 `jq -R -r 'fromjson? | ...'` 로 줄 단위 스트리밍한다. `fromjson?`가 깨진 줄을 조용히 건너뛴다.
- **`tail -n N` 금지.** 필요한 타입만 파일 전체에서 스캔한다.
- **모든 필드에 폴백.** `last_assistant_message` → `last-prompt` → `(내용 없음)`. `(확인 불가)` 문자열은 어디에도 쓰지 않는다.
- **훅 실패가 세션을 막지 않는다.** 스크립트는 항상 `exit 0`. 내부 실패는 `|| true`로 흡수한다.
- **Slack 웹훅 URL 하드코딩 금지.** `~/.claude/.slack-webhook`에서 읽고, 파일이 없으면 조용히 건너뛴다.
- **경로는 훅 stdin의 `cwd`를 쓴다.** `$(pwd)` 금지 (논리 경로가 `/home/...`로 나옴).
- **알림 임계값:** `CC_NOTIFY_MIN_SEC` 기본 `180`.
- **메모리 항목 상한:** 50건. 초과 시 stale 검사를 건너뛰고 정리 경고만 낸다.
- **메모리 저장소:** `~/claude-memory/np-enterprise/`. 기준 repo는 `<저장소>/.repo` 파일, 기본값 `/ssd1/home/wonseon.song/test2/np-enterprise`.
- **작업 브랜치:** `feat/note-memory-notify` (이미 생성됨, 스펙 커밋 `fbdb715` 위).
- **작업 repo:** `/ssd1/home/wonseon.song/claude-skills`. 모든 상대 경로는 이 디렉터리 기준.

---

## File Structure

| 파일 | 책임 |
|---|---|
| `note/SKILL.md` | `/note` 스킬 정의. 기록 기준·사용법·`--verify` 규칙 |
| `note/scripts/lib/common.sh` | 트랜스크립트 파싱 + 텍스트 정제 + Slack 전송. 모든 훅이 source |
| `note/scripts/lib/clean_text.py` | 마크다운 제거 + 개행 접기 + 글자수 절단 (UTF-8 안전) |
| `note/scripts/symbol_diff.py` | AST 기반 심볼 변경 판정. 단독 실행 가능, 종료코드로 결과 전달 |
| `note/scripts/stamp-start.sh` | `UserPromptSubmit` 훅. 턴/세션 시작 시각 기록 |
| `note/scripts/notify-stop.sh` | `Stop` 훅. 경과 ≥ 임계값인 턴만 Slack |
| `note/scripts/notify-session.sh` | `SessionEnd` 훅. 세션 요약 + note 누락 경고 + 상태파일 정리 |
| `note/scripts/memory-check.sh` | `SessionStart` 훅. stale 판정 후 `MEMORY.md` 갱신 + 요약 주입 |
| `note/tests/assert.sh` | 테스트 어서션 헬퍼 |
| `note/tests/fixtures/*.jsonl` | 트랜스크립트 픽스처 (정상/깨진 줄) |
| `note/tests/test_*.sh` | 스크립트별 테스트 |
| `note/tests/run.sh` | 전체 테스트 실행 |
| `setup.sh` | (수정) 메모리 symlink 루프 추가 |
| `README.md` | (수정) 스킬 목록에 `note` 추가 |

---

## Task 1: 테스트 하네스 + 공통 라이브러리

**Files:**
- Create: `note/tests/assert.sh`
- Create: `note/tests/curl_stub.sh`
- Create: `note/tests/run.sh`
- Create: `note/tests/fixtures/transcript_ok.jsonl`
- Create: `note/tests/fixtures/transcript_broken.jsonl`
- Create: `note/scripts/lib/clean_text.py`
- Create: `note/scripts/lib/common.sh`
- Test: `note/tests/test_common.sh`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces: 다른 모든 태스크가 `source note/scripts/lib/common.sh` 후 아래를 쓴다.
  - `tx_last_prompt <transcript>` → 마지막 사용자 프롬프트 문자열 (없으면 빈 문자열)
  - `tx_count_prompts <transcript>` → 정수
  - `tx_count_notes <transcript>` → `/note`로 시작하는 프롬프트 수, 정수
  - `tx_ai_title <transcript>` → 마지막 `ai-title` 값 (없으면 빈 문자열)
  - `clean_text <maxchars>` → stdin을 정제해 stdout으로 (한 줄)
  - `slack_send <text>` → 전송. 웹훅 파일 없으면 조용히 성공
  - 변수 `CC_NOTIFY_STATE_DIR` (기본 `/tmp/claude-notify`), `CC_SLACK_WEBHOOK_FILE` (기본 `~/.claude/.slack-webhook`)
  - 테스트는 `note/tests/assert.sh`의 `assert_eq`, `assert_contains`, `finish`를 쓴다.
  - Slack 전송을 검사하는 테스트는 `note/tests/curl_stub.sh`를 source 한 뒤
    `install_curl_stub <dir>` 를 호출하고 `curl_stub_body` 로 마지막 전송 내용을 읽는다.

- [ ] **Step 1: 어서션 헬퍼 작성**

`note/tests/assert.sh`:

```bash
#!/usr/bin/env bash
# 테스트 어서션 헬퍼. 각 test_*.sh가 source 한다.

FAILED=0

assert_eq() {  # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    echo "  ok    $3"
  else
    echo "  FAIL  $3"
    echo "        expected: [$1]"
    echo "        actual:   [$2]"
    FAILED=1
  fi
}

assert_contains() {  # <haystack> <needle> <name>
  case "$1" in
    *"$2"*) echo "  ok    $3" ;;
    *)
      echo "  FAIL  $3"
      echo "        expected to contain: [$2]"
      echo "        actual:              [$1]"
      FAILED=1
      ;;
  esac
}

assert_rc() {  # <expected_rc> <actual_rc> <name>
  assert_eq "$1" "$2" "$3"
}

finish() {
  if [ "$FAILED" -eq 0 ]; then
    echo "PASS"
    exit 0
  fi
  echo "FAIL"
  exit 1
}
```

- [ ] **Step 2: curl 스텁 헬퍼 작성**

Slack 전송을 검사하는 테스트가 공유한다. 실제 알림이 나가지 않게 `curl` 을 PATH 앞단에서 가로챈다.

`note/tests/curl_stub.sh`:

```bash
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
```

- [ ] **Step 3: 픽스처 작성**

`note/tests/fixtures/transcript_ok.jsonl`:

```
{"type":"last-prompt","lastPrompt":"레거시 검증기에 AMP 예외 추가 진행해줘","sessionId":"s1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"확인했습니다"}]},"timestamp":"2026-07-31T02:00:00.000Z"}
{"type":"last-prompt","lastPrompt":"/note \"presigned URL은 백엔드가 발급\"","sessionId":"s1"}
{"type":"ai-title","aiTitle":"AMP 예외 처리","sessionId":"s1"}
{"type":"last-prompt","lastPrompt":"커밋 푸시 부탁","sessionId":"s1"}
```

`note/tests/fixtures/transcript_broken.jsonl` — 2번째 줄이 잘린 JSON이다:

```
{"type":"last-prompt","lastPrompt":"첫 프롬프트","sessionId":"s2"}
{"type":"assistant","message":{"content":[{"type":"tex
{"type":"ai-title","aiTitle":"깨진 줄 테스트","sessionId":"s2"}
{"type":"last-prompt","lastPrompt":"마지막 프롬프트","sessionId":"s2"}
```

- [ ] **Step 4: 실패하는 테스트 작성**

`note/tests/test_common.sh`:

```bash
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/../scripts/lib/common.sh"

OK="$HERE/fixtures/transcript_ok.jsonl"
BROKEN="$HERE/fixtures/transcript_broken.jsonl"

echo "test_common"

assert_eq "커밋 푸시 부탁" "$(tx_last_prompt "$OK")" "tx_last_prompt: 마지막 프롬프트"
assert_eq "3" "$(tx_count_prompts "$OK")" "tx_count_prompts: 3건"
assert_eq "1" "$(tx_count_notes "$OK")" "tx_count_notes: /note 1건"
assert_eq "AMP 예외 처리" "$(tx_ai_title "$OK")" "tx_ai_title"

# 깨진 줄이 있어도 나머지는 정상 파싱된다
assert_eq "마지막 프롬프트" "$(tx_last_prompt "$BROKEN")" "깨진 줄: 마지막 프롬프트"
assert_eq "2" "$(tx_count_prompts "$BROKEN")" "깨진 줄: 프롬프트 2건"
assert_eq "깨진 줄 테스트" "$(tx_ai_title "$BROKEN")" "깨진 줄: ai-title"

# 파일이 없어도 죽지 않는다
assert_eq "" "$(tx_last_prompt /no/such/file.jsonl)" "없는 파일: 빈 문자열"
assert_eq "0" "$(tx_count_prompts /no/such/file.jsonl)" "없는 파일: 0건"

# clean_text: 마크다운 제거, 개행 접기, 글자수 절단 (한글 안전)
assert_eq "굵게 강조 코드" "$(printf '**굵게** _강조_\n`코드`' | clean_text 100)" "clean_text: 마크다운 제거"
assert_eq "앞부분" "$(printf '앞부분뒷부분' | clean_text 3)" "clean_text: 한글 3글자 절단"
assert_eq "앞 뒤" "$(printf '앞 ```\ncode block\n``` 뒤' | clean_text 100)" "clean_text: 코드블록 제거"

# slack_send: 웹훅 파일이 없으면 조용히 성공
CC_SLACK_WEBHOOK_FILE=/no/such/webhook
slack_send "테스트" && rc=0 || rc=$?
assert_eq "0" "$rc" "slack_send: 웹훅 없으면 성공 종료"

finish
```

- [ ] **Step 5: 테스트를 돌려 실패를 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/test_common.sh
```

기대: `note/scripts/lib/common.sh: No such file or directory` 로 실패.

- [ ] **Step 6: clean_text.py 작성**

`note/scripts/lib/clean_text.py`:

```python
#!/usr/bin/env python3
"""stdin의 마크다운 텍스트를 한 줄로 정제해 stdout으로 낸다.

사용법: clean_text.py <최대_글자수>
- 코드블록(``` ... ```)을 공백으로 치환
- 마크다운 기호(* _ ` # >) 제거
- 모든 공백/개행을 단일 공백으로 접음
- 앞에서 <최대_글자수> 글자만 남김 (바이트가 아닌 글자 기준이라 한글이 깨지지 않음)
"""
import re
import sys

def main() -> int:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    text = sys.stdin.read()
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"[*_`#>]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    sys.stdout.write(text[:limit])
    return 0

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 7: common.sh 작성**

`note/scripts/lib/common.sh`:

```bash
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
```

- [ ] **Step 8: 테스트를 돌려 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/test_common.sh
```

기대: 모든 줄이 `ok`, 마지막 줄 `PASS`.

- [ ] **Step 9: 전체 실행기 작성**

`note/tests/run.sh`:

```bash
#!/usr/bin/env bash
# 모든 테스트를 실행한다. 하나라도 실패하면 1로 종료.
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "── $(basename "$t") ──"
  bash "$t" || rc=1
  echo
done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$rc"
```

- [ ] **Step 10: 전체 테스트 실행**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/run.sh
```

기대: 마지막 줄 `ALL PASS`.

- [ ] **Step 11: 커밋**

```bash
cd /ssd1/home/wonseon.song/claude-skills
git add note/tests note/scripts/lib
git commit -m "feat(note): 테스트 하네스 + 트랜스크립트 파싱 공통 라이브러리

- jq -R 'fromjson?' 스트리밍으로 깨진 줄만 건너뛴다 (jq -s slurp 대체)
- clean_text는 python3로 글자 단위 절단 (한글 깨짐 방지)"
```

---

## Task 2: 턴 시작 시각 기록 (`UserPromptSubmit`)

**Files:**
- Create: `note/scripts/stamp-start.sh`
- Test: `note/tests/test_stamp_start.sh`

**Interfaces:**
- Consumes: `common.sh`의 `CC_NOTIFY_STATE_DIR`
- Produces:
  - `$CC_NOTIFY_STATE_DIR/<session_id>.turn` — 이번 턴 시작 epoch (매 프롬프트마다 덮어씀)
  - `$CC_NOTIFY_STATE_DIR/<session_id>.session` — 세션 첫 프롬프트 epoch (이미 있으면 유지)
  - Task 3(`notify-stop.sh`)과 Task 4(`notify-session.sh`)가 이 두 파일을 읽는다.

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_stamp_start.sh`:

```bash
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

export CC_NOTIFY_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$CC_NOTIFY_STATE_DIR"' EXIT

echo "test_stamp_start"

# 첫 프롬프트: .turn 과 .session 이 모두 생긴다
echo '{"session_id":"abc","cwd":"/tmp"}' | bash "$HERE/../scripts/stamp-start.sh"
assert_eq "true" "$([ -f "$CC_NOTIFY_STATE_DIR/abc.turn" ] && echo true)" "첫 프롬프트: .turn 생성"
assert_eq "true" "$([ -f "$CC_NOTIFY_STATE_DIR/abc.session" ] && echo true)" "첫 프롬프트: .session 생성"

FIRST_SESSION=$(cat "$CC_NOTIFY_STATE_DIR/abc.session")

# .turn 을 과거 값으로 바꾼 뒤 두 번째 프롬프트를 넣으면
# .turn 은 갱신되고 .session 은 유지된다
echo "1" > "$CC_NOTIFY_STATE_DIR/abc.turn"
echo '{"session_id":"abc","cwd":"/tmp"}' | bash "$HERE/../scripts/stamp-start.sh"
assert_eq "false" "$([ "$(cat "$CC_NOTIFY_STATE_DIR/abc.turn")" = "1" ] && echo true || echo false)" "두번째: .turn 갱신됨"
assert_eq "$FIRST_SESSION" "$(cat "$CC_NOTIFY_STATE_DIR/abc.session")" "두번째: .session 유지됨"

# session_id 가 없어도 죽지 않는다
echo '{"cwd":"/tmp"}' | bash "$HERE/../scripts/stamp-start.sh" && rc=0 || rc=$?
assert_eq "0" "$rc" "session_id 없음: 정상 종료"

# 입력이 JSON이 아니어도 죽지 않는다
echo 'not json' | bash "$HERE/../scripts/stamp-start.sh" && rc=0 || rc=$?
assert_eq "0" "$rc" "잘못된 입력: 정상 종료"

finish
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_stamp_start.sh
```

기대: `scripts/stamp-start.sh: No such file or directory` 로 실패.

- [ ] **Step 3: 구현**

`note/scripts/stamp-start.sh`:

```bash
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
```

- [ ] **Step 4: 실행 권한 부여 후 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
chmod +x note/scripts/stamp-start.sh
bash note/tests/test_stamp_start.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 5: 커밋**

```bash
git add note/scripts/stamp-start.sh note/tests/test_stamp_start.sh
git commit -m "feat(note): UserPromptSubmit 훅으로 턴/세션 시작 시각 기록

트랜스크립트 구조에 의존하지 않도록 상태 파일로 경과를 잰다."
```

---

## Task 3: 긴 작업 알림 (`Stop`)

**Files:**
- Create: `note/scripts/notify-stop.sh`
- Test: `note/tests/test_notify_stop.sh`

**Interfaces:**
- Consumes: `common.sh` 전체, Task 2가 만든 `<session>.turn`
- Produces: 없음 (말단 훅). `CC_SLACK_WEBHOOK_FILE`을 테스트에서 가짜 경로로 덮어써 전송 여부를 검사한다.

**동작:** stdin JSON에서 `session_id`, `cwd`, `transcript_path`, `last_assistant_message`를 읽는다. `.turn` 과의 경과가 `CC_NOTIFY_MIN_SEC`(기본 180) 미만이면 아무것도 하지 않는다.

메시지 형식:

```
✅ 작업 완료 (12분)
📁 np-enterprise/engine · feat/NPP02-6405
📝 요청: 레거시 검증기에 AMP 예외 추가 진행해줘
💬 결과: AMP 예외 3곳 추가, 테스트 통과. PR #2412 생성함.
```

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_notify_stop.sh`:

```bash
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
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_notify_stop.sh
```

기대: `scripts/notify-stop.sh: No such file or directory` 로 실패.

- [ ] **Step 3: 구현**

`note/scripts/notify-stop.sh`:

```bash
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
SHORT_CWD=$(printf '%s' "$CWD" | awk -F/ '{ if (NF>=2) printf "%s/%s", $(NF-1), $NF; else printf "%s", $NF }')
BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
LOC="$SHORT_CWD"
[ -n "$BRANCH" ] && LOC="$SHORT_CWD · $BRANCH"

TEXT=$(printf '✅ 작업 완료 (%s)\n📁 %s\n📝 요청: %s\n💬 결과: %s' \
  "$(human_duration "$ELAPSED")" "$LOC" "$REQ" "$RES")

slack_send "$TEXT"
exit 0
```

- [ ] **Step 4: 실행 권한 부여 후 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
chmod +x note/scripts/notify-stop.sh
bash note/tests/test_notify_stop.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 5: 커밋**

```bash
git add note/scripts/notify-stop.sh note/tests/test_notify_stop.sh
git commit -m "feat(note): Stop 훅을 '오래 걸린 턴만' 알림으로 교체

- 요청은 last-prompt 레코드, 결과는 훅 stdin의 last_assistant_message
- 경로는 훅의 cwd 사용 (pwd 는 논리 경로라 /home/... 로 나옴)
- 임계값 CC_NOTIFY_MIN_SEC 기본 180초"
```

---

## Task 4: 세션 종료 요약 (`SessionEnd`)

**Files:**
- Create: `note/scripts/notify-session.sh`
- Modify: `note/scripts/lib/common.sh` (`short_cwd` 추가)
- Modify: `note/scripts/notify-stop.sh` (인라인 awk → `short_cwd` 호출)
- Test: `note/tests/test_notify_session.sh`, `note/tests/test_common.sh` (`short_cwd` 케이스 추가)

**Interfaces:**
- Consumes: `common.sh` 전체, Task 2가 만든 `<session>.session`
- Produces: `common.sh` 에 `short_cwd <path>` → 경로의 마지막 2단계 문자열. `notify-stop.sh` 와 공유한다.
- 종료 시 `$CC_NOTIFY_STATE_DIR/<session>.*` 를 삭제한다.

**선행 정리:** Task 3 리뷰에서 경로 축약 `awk -F/` 가 후행 슬래시를 잘못 처리하는 것이 확인됐다
(`/foo/bar/` → `bar/`). 같은 줄을 이 태스크에서 복제하지 말고, `common.sh` 로 뽑아 양쪽이 쓴다.

`note/scripts/lib/common.sh` 끝에 추가한다.

```bash
# 경로의 마지막 2단계만 남긴다 (예: /a/b/c/d -> c/d).
# 후행 슬래시를 먼저 떼지 않으면 마지막 필드가 비어 'c/' 처럼 잘못 나온다.
short_cwd() {  # <path>
  local p="${1:-}"
  while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
  [ -n "$p" ] || return 0
  printf '%s' "$p" | awk -F/ '{ if (NF>=2 && $(NF-1) != "") printf "%s/%s", $(NF-1), $NF; else printf "%s", $NF }'
}
```

`note/tests/test_common.sh` 에 케이스를 추가한다.

```bash
assert_eq "c/d" "$(short_cwd /a/b/c/d)" "short_cwd: 마지막 2단계"
assert_eq "c/d" "$(short_cwd /a/b/c/d/)" "short_cwd: 후행 슬래시 제거"
assert_eq "engine" "$(short_cwd /engine)" "short_cwd: 1단계 경로"
assert_eq "" "$(short_cwd '')" "short_cwd: 빈 경로"
```

`note/scripts/notify-stop.sh` 의 아래 줄을 `SHORT_CWD=$(short_cwd "$CWD")` 로 교체한다.

```bash
SHORT_CWD=$(printf '%s' "$CWD" | awk -F/ '{ if (NF>=2) printf "%s/%s", $(NF-1), $NF; else printf "%s", $NF }')
```

메시지 형식:

```
🏁 세션 종료 · np-enterprise/engine · 47분 · 18턴
📌 AMP 예외 처리
🧠 note 0건 — 확정한 사실이 있었다면 /note 로 남기세요
```

`🧠` 줄은 **`/note` 호출 0건 AND 사용자 프롬프트 5건 이상**일 때만 붙인다.

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_notify_session.sh`:

```bash
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

# 4. 상태 파일 정리
assert_eq "false" "$([ -f "$CC_NOTIFY_STATE_DIR/e3.session" ] && echo true || echo false)" "상태파일 .session 삭제됨"
assert_eq "false" "$([ -f "$CC_NOTIFY_STATE_DIR/e3.turn" ] && echo true || echo false)" "상태파일 .turn 삭제됨"

# 5. session_id 없음 -> 죽지 않음
echo '{"cwd":"/tmp"}' | bash "$HERE/../scripts/notify-session.sh" && rc=0 || rc=$?
assert_eq "0" "$rc" "session_id 없음: 정상 종료"

finish
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_notify_session.sh
```

기대: `scripts/notify-session.sh: No such file or directory` 로 실패.

- [ ] **Step 3: 구현**

`note/scripts/notify-session.sh`:

```bash
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
```

- [ ] **Step 4: 실행 권한 부여 후 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
chmod +x note/scripts/notify-session.sh
bash note/tests/test_notify_session.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 5: 커밋**

```bash
git add note/scripts/notify-session.sh note/tests/test_notify_session.sh
git commit -m "feat(note): SessionEnd 세션 요약 + note 누락 경고

프롬프트 5건 이상인 세션에서 /note 가 0건일 때만 경고한다."
```

---

## Task 5: AST 기반 심볼 변경 판정

**Files:**
- Create: `note/scripts/symbol_diff.py`
- Test: `note/tests/test_symbol_diff.sh`

**Interfaces:**
- Consumes: 없음 (독립 실행)
- Produces: Task 6(`memory-check.sh`)이 아래 계약으로 호출한다.
  - 호출: `python3 symbol_diff.py <repo> <path> <symbol> <base_commit>`
  - stdout: `UNCHANGED` | `CHANGED` | `MISSING`
  - 종료코드: `0` = UNCHANGED, `1` = CHANGED, `2` = MISSING(심볼·파일 없음 또는 파싱 불가)

**왜 `git log -L`이 아닌가:** 실측에서 `git log -L :__init__:<file> <base>..HEAD` 가 `fatal: -L parameter '__init__' starting at line 1: no match` (rc=128)로 종료했다. `-L`은 funcname 패턴에 의존해 Python 메서드에서 신뢰할 수 없다.

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_symbol_diff.sh`:

```bash
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t

cat > "$REPO/mod.py" <<'PY'
class Builder:
    def __init__(self):
        self.x = 1

    def build(self):
        return self.x
PY
cat > "$REPO/gone.py" <<'PY'
def doomed():
    return 1
PY
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)

# build() 만 바꾸고 __init__ 은 그대로 둔다. gone.py 는 삭제한다.
cat > "$REPO/mod.py" <<'PY'
class Builder:
    def __init__(self):
        self.x = 1

    def build(self):
        return self.x * 2
PY
rm "$REPO/gone.py"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm change

SD="$HERE/../scripts/symbol_diff.py"

echo "test_symbol_diff"

out=$(python3 "$SD" "$REPO" mod.py __init__ "$BASE"); rc=$?
assert_eq "UNCHANGED" "$out" "변경 없는 심볼: UNCHANGED"
assert_eq "0" "$rc" "변경 없는 심볼: rc=0"

out=$(python3 "$SD" "$REPO" mod.py build "$BASE"); rc=$?
assert_eq "CHANGED" "$out" "변경된 심볼: CHANGED"
assert_eq "1" "$rc" "변경된 심볼: rc=1"

out=$(python3 "$SD" "$REPO" mod.py Builder "$BASE"); rc=$?
assert_eq "CHANGED" "$out" "변경된 클래스: CHANGED"

out=$(python3 "$SD" "$REPO" gone.py doomed "$BASE"); rc=$?
assert_eq "MISSING" "$out" "삭제된 파일: MISSING"
assert_eq "2" "$rc" "삭제된 파일: rc=2"

out=$(python3 "$SD" "$REPO" mod.py no_such_symbol "$BASE"); rc=$?
assert_eq "MISSING" "$out" "없는 심볼: MISSING"
assert_eq "2" "$rc" "없는 심볼: rc=2"

out=$(python3 "$SD" "$REPO" mod.py build deadbeef); rc=$?
assert_eq "MISSING" "$out" "무효 커밋: MISSING"
assert_eq "2" "$rc" "무효 커밋: rc=2"

finish
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_symbol_diff.sh
```

기대: `can't open file .../symbol_diff.py` 로 실패.

- [ ] **Step 3: 구현**

`note/scripts/symbol_diff.py`:

```python
#!/usr/bin/env python3
"""근거 심볼이 기준 커밋 이후 실제로 바뀌었는지 판정한다.

사용법: symbol_diff.py <repo> <path> <symbol> <base_commit>

stdout: UNCHANGED | CHANGED | MISSING
종료코드: 0=UNCHANGED, 1=CHANGED, 2=MISSING

git log -L 을 쓰지 않는 이유:
    -L 은 심볼을 funcname 패턴으로 찾기 때문에 Python 메서드에서
    'fatal: -L parameter ... no match' 로 종료한다(실측 rc=128).
    대신 두 시점의 소스를 ast 로 파싱해 해당 심볼의 소스 조각을 직접 비교한다.
"""
import ast
import subprocess
import sys

DEFS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def source_at(repo: str, rev: str, path: str) -> str | None:
    """<rev>:<path> 의 파일 내용. 없으면 None."""
    proc = subprocess.run(
        ["git", "-C", repo, "show", f"{rev}:{path}"],
        capture_output=True,
        text=True,
    )
    return proc.stdout if proc.returncode == 0 else None


def symbol_source(source: str | None, symbol: str) -> str | None:
    """소스에서 이름이 symbol 인 함수/클래스의 소스 조각. 없으면 None."""
    if source is None:
        return None
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None
    for node in ast.walk(tree):
        if isinstance(node, DEFS) and node.name == symbol:
            return ast.get_source_segment(source, node)
    return None


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: symbol_diff.py <repo> <path> <symbol> <base_commit>", file=sys.stderr)
        return 2
    repo, path, symbol, base = sys.argv[1:5]

    before = symbol_source(source_at(repo, base, path), symbol)
    after = symbol_source(source_at(repo, "HEAD", path), symbol)

    if after is None or before is None:
        print("MISSING")
        return 2
    if before == after:
        print("UNCHANGED")
        return 0
    print("CHANGED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/test_symbol_diff.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 5: 실제 repo에서 확인**

```bash
python3 note/scripts/symbol_diff.py \
  /ssd1/home/wonseon.song/test2/np-enterprise \
  sdk/src/domain/composition/service/step_params_builder.py \
  StepParamsBuilder \
  abbc677a1aeeb72020021c33f8efc1dc87b4cc9a
```

기대: `CHANGED` 출력, 종료코드 1.

- [ ] **Step 6: 커밋**

```bash
git add note/scripts/symbol_diff.py note/tests/test_symbol_diff.sh
git commit -m "feat(note): AST 기반 심볼 변경 판정

git log -L 은 Python 메서드에서 'no match' 로 죽어(rc=128) 쓸 수 없다.
git show 로 두 시점 소스를 받아 ast 로 심볼 조각을 비교한다."
```

---

## Task 6: stale 감지 훅 (`SessionStart`)

**Files:**
- Create: `note/scripts/memory-check.sh`
- Test: `note/tests/test_memory_check.sh`

**Interfaces:**
- Consumes: Task 5의 `symbol_diff.py` (계약: stdout `UNCHANGED|CHANGED|MISSING`, rc `0|1|2`)
- Produces: `MEMORY.md` 를 제자리 갱신하고, stdout으로 SessionStart 훅 JSON을 낸다.

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⚠ 재확인 필요 2건: presigned-url-issuer, tar-snapshot-flat-error"}}
```

**`MEMORY.md` 인덱스 줄 형식:**

```
- [presigned URL 발급 주체](presigned-url-issuer.md) — 백엔드가 발급, np-client는 조립 안 함
- ⚠ [tar 스냅샷 구조](tar-snapshot-flat-error.md) — snapshot 폴더 없으면 flat 으로 풀림
```

`⚠` / `⚠ 삭제됨` 은 `- ` 바로 뒤에 붙는다. 훅은 **매번 기존 표시를 지우고 다시 계산**하므로 몇 번 실행해도 결과가 같다.

**메모리 파일의 `Source` 줄 형식:** `**Source:** \`<path>#<symbol>@<commit>\`` — `#<symbol>` 은 생략 가능.

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_memory_check.sh`:

```bash
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

REPO="$(mktemp -d)"
STORE="$(mktemp -d)"
trap 'rm -rf "$REPO" "$STORE"' EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
cat > "$REPO/mod.py" <<'PY'
def stable():
    return 1

def volatile():
    return 1
PY
echo "text" > "$REPO/doc.txt"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)

cat > "$REPO/mod.py" <<'PY'
def stable():
    return 1

def volatile():
    return 999
PY
echo "text changed" > "$REPO/doc.txt"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm change

printf '%s\n' "$REPO" > "$STORE/.repo"

mk() {  # <name> <source_line>
  cat > "$STORE/$1.md" <<EOF
---
name: $1
description: $1 설명
metadata:
  type: project
---

본문.

**Source:** \`$2\`
**Verified:** 2026-07-01
EOF
}

mk unchanged-one "mod.py#stable@$BASE"
mk changed-one   "mod.py#volatile@$BASE"
mk file-level    "doc.txt@$BASE"
mk no-commit     "mod.py#stable"

cat > "$STORE/MEMORY.md" <<'EOF'
- [안 바뀜](unchanged-one.md) — 그대로
- ⚠ [바뀜](changed-one.md) — 변경됨
- [파일단위](file-level.md) — py 아님
- [커밋없음](no-commit.md) — 기준 없음
EOF

echo "test_memory_check"

export CC_MEMORY_STORE="$STORE"
OUT=$(echo '{"session_id":"m1","cwd":"/tmp"}' | bash "$HERE/../scripts/memory-check.sh")

IDX=$(cat "$STORE/MEMORY.md")
assert_contains "$IDX" "- [안 바뀜](unchanged-one.md)" "변경 없음: ⚠ 안 붙음"
assert_contains "$IDX" "- ⚠ [바뀜](changed-one.md)" "변경됨: ⚠ 붙음"
assert_contains "$IDX" "- ⚠ [파일단위](file-level.md)" "py 아님: 파일 단위 폴백으로 ⚠"
assert_contains "$IDX" "- [커밋없음](no-commit.md)" "커밋 없음: 건너뜀"

assert_contains "$OUT" "additionalContext" "SessionStart JSON 출력"
assert_contains "$OUT" "재확인 필요 2건" "요약: 2건"

# 두 번 돌려도 ⚠ 가 중복되지 않는다
bash "$HERE/../scripts/memory-check.sh" <<< '{"session_id":"m1","cwd":"/tmp"}' >/dev/null
CNT=$(grep -c '⚠ ⚠' "$STORE/MEMORY.md" || true)
assert_eq "0" "$CNT" "재실행: ⚠ 중복 없음"

# 저장소가 없어도 죽지 않는다
CC_MEMORY_STORE=/no/such/store bash "$HERE/../scripts/memory-check.sh" <<< '{}' >/dev/null && rc=0 || rc=$?
assert_eq "0" "$rc" "저장소 없음: 정상 종료"

# 항목 50건 초과 -> 검사 건너뛰고 정리 경고
: > "$STORE/MEMORY.md"
for i in $(seq 1 51); do echo "- [m$i](unchanged-one.md) — x" >> "$STORE/MEMORY.md"; done
OUT=$(echo '{}' | bash "$HERE/../scripts/memory-check.sh")
assert_contains "$OUT" "정리 필요" "51건: 정리 경고"

finish
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_memory_check.sh
```

기대: `scripts/memory-check.sh: No such file or directory` 로 실패.

- [ ] **Step 3: 구현**

`note/scripts/memory-check.sh`:

```bash
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
```

- [ ] **Step 4: 실행 권한 부여 후 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
chmod +x note/scripts/memory-check.sh
bash note/tests/test_memory_check.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 5: 전체 테스트 실행**

```bash
bash note/tests/run.sh
```

기대: 마지막 줄 `ALL PASS`.

- [ ] **Step 6: 커밋**

```bash
git add note/scripts/memory-check.sh note/tests/test_memory_check.sh
git commit -m "feat(note): SessionStart stale 감지

- py + 심볼이면 AST 비교, 그 외는 파일 단위 폴백
- 매 실행마다 기존 표시를 지우고 재계산해 멱등
- 50건 초과 시 검사 건너뛰고 정리 경고"
```

---

## Task 7: `/note` 스킬 문서

**Files:**
- Create: `note/SKILL.md`
- Test: 수동 (스킬은 문서라 자동 테스트 대상이 아니다)

**Interfaces:**
- Consumes: Task 6이 정한 `MEMORY.md` 인덱스 형식과 `**Source:**` / `**Verified:**` 형식
- Produces: 사용자에게 노출되는 `/note`, `/note --check`, `/note --verify <name>` 인터페이스

- [ ] **Step 1: SKILL.md 작성**

`note/SKILL.md`:

````markdown
---
name: note
description: "세션 간 사라지는 도메인 판정을 메모리로 남긴다. 소유권·경계 판정, 재현된 함정, 검증된 환경값을 근거(파일#심볼@커밋)와 함께 기록하고, 근거가 바뀌면 SessionStart에서 ⚠ 로 표시한다. --check 재검사, --verify 재확인 완료."
argument-hint: "<확정한 사실> | --check | --verify <name>"
marketplace: false
---

# Note — 도메인 판정 메모리

## 목적

코드를 읽어도 안 나오는 사실 — 누가 무엇을 소유하는가, 어떤 함정이 있는가 — 은
세션이 끝나면 사라진다. 그걸 근거와 함께 파일로 남겨 다음 세션이 0에서 시작하지 않게 한다.

## 저장 위치

실체는 `~/claude-memory/np-enterprise/` 한 곳이다.
`sdk`/`qa`/`backend`/`engine`/`client`/`common`/루트의 프로젝트 memory 디렉터리가
전부 이곳으로 symlink 되어 있어, **어느 디렉터리에서 시작하든 같은 메모리가 로드된다.**

기준 repo는 `~/claude-memory/np-enterprise/.repo` 에 적는다.
없으면 `/ssd1/home/wonseon.song/test2/np-enterprise` 를 쓴다.

## 사용법

```
/note "presigned URL은 백엔드가 발급, np-client는 조립 안 함"
/note --check              # stale 재검사 수동 실행
/note --verify <name>      # ⚠ 해제
```

## 기록 기준

**남긴다:**

| 유형 | 예 |
|---|---|
| 소유권·경계 판정 | presigned URL은 백엔드가 발급, np-client는 조립 안 함 |
| 재현된 함정 | tar 에 snapshot 폴더가 없으면 flat 구조로 풀려 에러 |
| 검증된 환경값 | `SDK_DEPLOYMENT=internal` 이면 profiler 와 실제 송수신됨 |
| 의도적 예외·금지 영역 | GQ mpq 구현은 명시 요청 없으면 수정 금지 |

**남기지 않는다:** 코드를 읽으면 나오는 사실 / 일회성 디버깅 로그 /
티켓·PR 에 이미 적힌 것 / 검증 전 추측.

추측을 사실로 적지 않는다. 확인하지 못했으면 기록하지 말고 확인부터 한다.

## 기록 절차 (`/note "<사실>"`)

1. **근거 추출** — 직전 대화에서 참조한 파일 경로와 심볼, 그리고 기준 repo 의 현재 HEAD 커밋을 찾는다.
   찾지 못하면 그때만 사용자에게 한 번 되묻는다. 되묻고도 없으면 `Source` 없이 저장하되,
   stale 검사 대상에서 빠진다는 점을 알린다.
2. **중복 검사** — 저장소의 기존 `description` 과 대조한다. 같은 사실이면 새 파일을 만들지 말고 갱신한다.
3. **쓰기** — 메모리 파일 생성/갱신 + `MEMORY.md` 에 한 줄 추가.

### 파일 형식

프론트매터는 하네스 규격만 쓴다. 비표준 키를 넣지 않는다 — 처리 방식이 보장되지 않는다.

```markdown
---
name: presigned-url-issuer
description: presigned URL은 백엔드가 발급하고 np-client는 조립하지 않는다
metadata:
  type: project
---

presigned URL은 백엔드가 발급한다. np-client는 URL을 조립하지 않고 응답을 그대로 사용한다.

**Source:** `backend/src/pynp/api/v1/models.py#create_presigned_url@a1b2c3d`
**Verified:** 2026-07-31 (NPP02-6405)
```

- `Source`: `<repo 상대경로>#<심볼>@<커밋 해시>`. 심볼을 특정할 수 없으면 `#<심볼>` 을 생략한다.
- `Verified`: `YYYY-MM-DD` + 선택적 `(티켓키)`.
- 관련 메모리는 본문에서 `[[다른-메모리-name]]` 으로 잇는다.

### 인덱스 형식

`MEMORY.md` 는 메모리당 정확히 한 줄이다.

```
- [presigned URL 발급 주체](presigned-url-issuer.md) — 백엔드가 발급, np-client는 조립 안 함
```

## `--check`

`scripts/memory-check.sh` 를 수동 실행한다. SessionStart 훅과 같은 판정을 즉시 돌린다.

```bash
bash ~/claude-skills/note/scripts/memory-check.sh <<< '{}'
```

## `--verify <name>`

`⚠` 가 붙은 항목을 재확인한 뒤 해제한다. **세 가지를 함께 갱신한다.**
하나라도 빠지면 다음 세션에 `⚠` 가 그대로 다시 붙는다.

1. `Source` 의 커밋 해시를 현재 HEAD 로 갱신 (비교 기준선 이동)
2. `Verified` 날짜를 오늘로 갱신
3. `MEMORY.md` 해당 줄의 `⚠` 제거

**내용이 실제로 바뀌었으면 `--verify` 가 아니라 `/note` 로 갱신한다.**
`--verify` 는 "확인해보니 여전히 사실이더라" 일 때만 쓴다.

## 관련 훅

| 훅 | 스크립트 | 역할 |
|---|---|---|
| `SessionStart` | `scripts/memory-check.sh` | 근거가 바뀐 메모리에 `⚠` |
| `UserPromptSubmit` | `scripts/stamp-start.sh` | 턴/세션 시작 시각 기록 |
| `Stop` | `scripts/notify-stop.sh` | 3분 이상 걸린 턴만 Slack |
| `SessionEnd` | `scripts/notify-session.sh` | 세션 요약 + note 누락 경고 |

설치는 `~/claude-skills/setup.sh` 가 한다.
````

- [ ] **Step 2: 스킬이 인식되는지 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash setup.sh 2>&1 | grep note
ls -la ~/.claude/skills/note
```

기대: `✅ note (linked)` 출력, symlink이 `~/claude-skills/note` 를 가리킴.

- [ ] **Step 3: 커밋**

```bash
git add note/SKILL.md
git commit -m "feat(note): /note 스킬 문서

기록 기준(남긴다/안 남긴다)과 --verify 3종 갱신 규칙을 명시."
```

---

## Task 8: 설치 자동화 + 마이그레이션

**Files:**
- Modify: `setup.sh` (Step 3 뒤에 메모리 symlink 단계 추가, 헤더 주석의 "수행 내용" 갱신)
- Modify: `README.md` (스킬 목록 표에 `note` 행 추가)
- Create: `note/tests/test_setup_memory.sh`

**Interfaces:**
- Consumes: Task 7의 `note/SKILL.md` (setup.sh 의 기존 스킬 symlink 루프가 자동으로 잡는다)
- Produces: `~/claude-memory/np-enterprise/` 저장소와 프로젝트별 `memory/` symlink

- [ ] **Step 1: 실패하는 테스트 작성**

`note/tests/test_setup_memory.sh`:

```bash
#!/usr/bin/env bash
# link_memory_dirs() 함수만 떼어내 검증한다 (setup.sh 전체를 돌리지 않는다).
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"

FAKE_HOME="$(mktemp -d)"
PROJ_ROOT="$FAKE_HOME/np-enterprise"
trap 'rm -rf "$FAKE_HOME"' EXIT

mkdir -p "$PROJ_ROOT"/{sdk,qa,backend}
mkdir -p "$FAKE_HOME/.claude/projects"

echo "test_setup_memory"

HOME="$FAKE_HOME" \
CC_MEMORY_STORE="$FAKE_HOME/claude-memory/np-enterprise" \
CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
  bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1

STORE="$FAKE_HOME/claude-memory/np-enterprise"
assert_eq "true" "$([ -d "$STORE" ] && echo true || echo false)" "저장소 생성됨"

enc=$(realpath "$PROJ_ROOT/sdk" | tr '/' '-')
LINK="$FAKE_HOME/.claude/projects/$enc/memory"
assert_eq "true" "$([ -L "$LINK" ] && echo true || echo false)" "sdk memory symlink 생성됨"
assert_eq "$STORE" "$(readlink "$LINK")" "sdk symlink 대상 정확"

# 존재하지 않는 하위 디렉터리는 건너뛴다
enc2=$(realpath "$PROJ_ROOT" | tr '/' '-')-engine
assert_eq "false" "$([ -e "$FAKE_HOME/.claude/projects/$enc2/memory" ] && echo true || echo false)" "없는 디렉터리는 건너뜀"

# 재실행해도 깨지지 않는다
HOME="$FAKE_HOME" CC_MEMORY_STORE="$STORE" CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
  bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1
assert_eq "$STORE" "$(readlink "$LINK")" "재실행: symlink 유지"

finish
```

- [ ] **Step 2: 테스트를 돌려 실패 확인**

```bash
bash note/tests/test_setup_memory.sh
```

기대: `--memory-only` 를 모르는 setup.sh 라 symlink이 안 생겨 `FAIL`.

- [ ] **Step 3: setup.sh 수정 — 헤더 주석**

`setup.sh` 상단 주석의 "수행 내용" 목록을 아래로 교체한다.

```bash
# 수행 내용:
#   1. ~/.claude/skills/ 디렉토리 생성
#   2. 각 스킬 디렉토리를 symlink 연결
#   3. 필수 환경 (gh CLI, 환경변수) 검증
#   4. 메모리 저장소 생성 + 프로젝트별 memory symlink 연결
#
# 옵션:
#   --memory-only   4단계만 수행 (테스트용)
```

- [ ] **Step 4: setup.sh 수정 — 메모리 단계 추가**

`setup.sh` 의 `SKILLS_DIR=...` 줄 바로 아래에 아래를 넣는다.

```bash
MEMORY_STORE="${CC_MEMORY_STORE:-$HOME/claude-memory/np-enterprise}"
MEMORY_PROJECT_ROOT="${CC_MEMORY_PROJECT_ROOT:-/ssd1/home/wonseon.song/test2/np-enterprise}"
MEMORY_SUBDIRS=("" "/sdk" "/qa" "/backend" "/engine" "/client" "/common")

# 메모리 실체는 한 곳에 두고, 프로젝트별 memory 디렉터리를 전부 그곳으로 잇는다.
# 작업 경로가 sdk/qa/backend 로 갈려도 같은 사실이 로드되게 하기 위해서다.
link_memory_dirs() {
  mkdir -p "$MEMORY_STORE"
  echo "[4/4] 메모리 저장소: $MEMORY_STORE"
  local linked=0 sub p enc target
  for sub in "${MEMORY_SUBDIRS[@]}"; do
    p="$MEMORY_PROJECT_ROOT$sub"
    [ -d "$p" ] || continue
    enc=$(realpath "$p" | tr '/' '-')
    target="$HOME/.claude/projects/$enc/memory"
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ]; then
      ln -sfn "$MEMORY_STORE" "$target"
    elif [ -d "$target" ]; then
      mv "$target" "$target.bak.$(date +%s)"
      ln -sfn "$MEMORY_STORE" "$target"
      echo "  🔄 $(basename "$p") (dir → symlink, old backed up)"
      linked=$((linked + 1))
      continue
    else
      ln -sfn "$MEMORY_STORE" "$target"
    fi
    echo "  ✅ $(basename "$p")"
    linked=$((linked + 1))
  done
  echo "  $linked memory dirs linked"
}

if [ "${1:-}" = "--memory-only" ]; then
  link_memory_dirs
  return 0 2>/dev/null || exit 0
fi
```

그리고 파일 맨 끝(마지막 `echo "═══..."` 뒤)에 아래를 추가한다.

```bash
echo ""
link_memory_dirs
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/test_setup_memory.sh
```

기대: 모든 줄 `ok`, 마지막 `PASS`.

- [ ] **Step 6: README.md 갱신**

스킬 목록 표에 아래 행을 추가한다.

```markdown
| `note` | 세션 간 사라지는 도메인 판정을 근거와 함께 기록. 근거가 바뀌면 ⚠ 표시 | `/note "presigned URL은 백엔드가 발급"` |
```

- [ ] **Step 7: 실제 설치 실행**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash setup.sh
ls -la ~/.claude/projects/-ssd1-home-wonseon-song-test2-np-enterprise-sdk/memory
```

기대: `note` 스킬 linked, memory symlink이 `~/claude-memory/np-enterprise` 를 가리킴.

- [ ] **Step 8: 기준 repo 파일 생성**

```bash
echo "/ssd1/home/wonseon.song/test2/np-enterprise" > ~/claude-memory/np-enterprise/.repo
printf '' > ~/claude-memory/np-enterprise/MEMORY.md
```

- [ ] **Step 9: Slack 웹훅을 파일로 분리**

현재 `~/.claude/settings.json` 에 평문으로 박혀 있는 URL을 옮긴다.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$(date +%s)
jq -r '.hooks.Stop[0].hooks[0].command' ~/.claude/settings.json \
  | grep -oE 'https://hooks\.slack\.com/services/[A-Za-z0-9/]+' > ~/.claude/.slack-webhook
chmod 600 ~/.claude/.slack-webhook
cat ~/.claude/.slack-webhook
```

기대: `https://hooks.slack.com/services/...` 한 줄 출력.

- [ ] **Step 10: settings.json 훅 교체**

`~/.claude/settings.json` 의 `hooks` 블록 전체를 아래로 바꾼다.
기존 인라인 셸(`Stop`)은 제거한다 — `notify-stop.sh` 가 대체한다.

```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command", "command": "$HOME/claude-skills/note/scripts/stamp-start.sh", "timeout": 5, "async": true } ] }
  ],
  "SessionStart": [
    { "hooks": [ { "type": "command", "command": "$HOME/claude-skills/note/scripts/memory-check.sh", "timeout": 15 } ] }
  ],
  "Stop": [
    { "hooks": [ { "type": "command", "command": "$HOME/claude-skills/note/scripts/notify-stop.sh", "timeout": 15, "async": true } ] }
  ],
  "SessionEnd": [
    { "hooks": [ { "type": "command", "command": "$HOME/claude-skills/note/scripts/notify-session.sh", "timeout": 15, "async": true } ] }
  ]
}
```

`SessionStart` 만 `async` 를 켜지 않는다. `additionalContext` 를 세션 시작 컨텍스트에 넣어야 하므로 동기 실행이 필요하다.

- [ ] **Step 11: 훅 수동 검증**

```bash
# SessionStart: JSON 이 나오는지 (메모리 0건이면 출력 없음이 정상)
echo '{}' | $HOME/claude-skills/note/scripts/memory-check.sh; echo "rc=$?"

# Stop: 30초 전 턴 -> 전송 안 함
mkdir -p /tmp/claude-notify && echo $(( $(date +%s) - 30 )) > /tmp/claude-notify/manual.turn
echo '{"session_id":"manual","cwd":"'"$PWD"'","transcript_path":"","last_assistant_message":"테스트"}' \
  | $HOME/claude-skills/note/scripts/notify-stop.sh; echo "rc=$?"

# Stop: 10분 전 턴 -> Slack 으로 실제 전송됨
echo $(( $(date +%s) - 600 )) > /tmp/claude-notify/manual.turn
echo '{"session_id":"manual","cwd":"'"$PWD"'","transcript_path":"","last_assistant_message":"수동 검증 메시지"}' \
  | $HOME/claude-skills/note/scripts/notify-stop.sh; echo "rc=$?"
rm -f /tmp/claude-notify/manual.*
```

기대: 전부 `rc=0`. 세 번째만 Slack 채널에 `✅ 작업 완료 (10분)` 메시지 도착.

- [ ] **Step 12: 전체 테스트 실행**

```bash
cd /ssd1/home/wonseon.song/claude-skills
bash note/tests/run.sh
```

기대: 마지막 줄 `ALL PASS`.

- [ ] **Step 13: 커밋 및 푸시**

```bash
git add setup.sh README.md note/tests/test_setup_memory.sh
git commit -m "feat(note): setup.sh 메모리 symlink + README 갱신

프로젝트별 memory 디렉터리를 단일 저장소로 잇는다.
--memory-only 옵션으로 해당 단계만 테스트 가능."
git push -u origin feat/note-memory-notify
```

---

## Task 9: 실사용 확인

**Files:**
- Create: `~/claude-memory/np-enterprise/*.md` (실제 메모리 3건, repo 밖이라 커밋되지 않음)

**Interfaces:**
- Consumes: Task 1~8 전부
- Produces: 없음 (검증 태스크)

- [ ] **Step 1: 확정된 사실 3건을 손으로 기록**

스펙에서 예로 든, 이미 검증된 사실들이다. 각 `Source` 의 경로·심볼·커밋은 실제 repo에서 확인한 값으로 채운다.

```bash
cd /ssd1/home/wonseon.song/test2/np-enterprise
HEAD_SHA=$(git rev-parse --short HEAD)
echo "$HEAD_SHA"
```

각 사실의 근거 경로·심볼을 먼저 repo 에서 확인한다. 아래 명령의 출력이 파일 내용의 `Source` 가 된다.

```bash
cd /ssd1/home/wonseon.song/test2/np-enterprise
grep -rn "SDK_DEPLOYMENT" --include=*.py -l | head -3
grep -rn "presigned" --include=*.py -l | head -3
grep -rn "snapshot" --include=*.py -l | head -3
```

찾은 파일에서 해당 로직을 감싸는 함수/클래스 이름을 확인해 `#<심볼>` 에 넣는다.
아래는 `presigned-url-issuer.md` 의 완성 형태다. 나머지 둘도 같은 구조로 쓴다.

```markdown
---
name: presigned-url-issuer
description: presigned URL은 백엔드가 발급하고 np-client는 조립하지 않는다
metadata:
  type: project
---

presigned URL은 백엔드가 발급한다. np-client는 URL을 조립하지 않고 응답을 그대로 사용한다.

**Source:** `backend/src/pynp/api/v1/models.py#create_presigned_url@<HEAD_SHA>`
**Verified:** 2026-07-31
```

```markdown
---
name: tar-snapshot-flat-error
description: tar.gz에 snapshot 폴더가 없으면 flat 구조로 풀려 에러가 난다
metadata:
  type: project
---

export 산출물 tar.gz 안에 snapshot 폴더가 없으면 내용이 flat 구조로 풀리고,
그 상태로 로드하면 에러가 난다. 구조를 먼저 확인한 뒤 푼다.

**Source:** `<위 grep 으로 찾은 경로>#<심볼>@<HEAD_SHA>`
**Verified:** 2026-07-31
```

```markdown
---
name: sdk-deployment-internal
description: SDK_DEPLOYMENT=internal이면 profiler와 실제로 송수신된다
metadata:
  type: reference
---

`SDK_DEPLOYMENT=internal` 로 설정하면 profiler 와 실제 송수신이 이루어져
`executorch_profile.etdump` 가 돌아온다. 디버깅 컨테이너 검증에 쓴다.

**Source:** `<위 grep 으로 찾은 경로>#<심볼>@<HEAD_SHA>`
**Verified:** 2026-07-31
```

`<HEAD_SHA>` 는 위에서 출력한 값으로, `<위 grep 으로 찾은 경로>#<심볼>` 은 실제 확인한 값으로 채운다.
심볼을 특정할 수 없으면 `#<심볼>` 을 통째로 생략한다 — 파일 단위 폴백으로 검사된다.

- [ ] **Step 2: 인덱스 작성**

```bash
cat > ~/claude-memory/np-enterprise/MEMORY.md <<'EOF'
- [tar 스냅샷 구조](tar-snapshot-flat-error.md) — snapshot 폴더 없으면 flat 으로 풀려 에러
- [SDK_DEPLOYMENT=internal](sdk-deployment-internal.md) — profiler 와 실제 송수신됨
- [presigned URL 발급 주체](presigned-url-issuer.md) — 백엔드가 발급, np-client 는 조립 안 함
EOF
```

- [ ] **Step 3: stale 검사 실행**

```bash
echo '{}' | ~/claude-skills/note/scripts/memory-check.sh
cat ~/claude-memory/np-enterprise/MEMORY.md
```

기대: 방금 HEAD 로 기록했으므로 `⚠` 가 하나도 없고, 출력도 없다.

- [ ] **Step 4: ⚠ 가 붙는지 역검증**

한 메모리의 `Source` 커밋을 과거 값으로 바꾸고 다시 돌린다.

```bash
OLD=$(git -C /ssd1/home/wonseon.song/test2/np-enterprise log --format=%h -50 | tail -1)
sed -i "s/@[0-9a-f]\{7,40\}\`/@$OLD\`/" ~/claude-memory/np-enterprise/presigned-url-issuer.md
echo '{}' | ~/claude-skills/note/scripts/memory-check.sh
grep presigned ~/claude-memory/np-enterprise/MEMORY.md
```

기대: `⚠ 재확인 필요 1건` 출력, 인덱스 줄이 `- ⚠ [presigned URL 발급 주체](...)` 로 바뀜.

- [ ] **Step 5: 새 세션에서 메모리가 로드되는지 확인**

`sdk` 디렉터리에서 새 Claude Code 세션을 열고, 기록한 사실 중 하나를 묻는다.
메모리 인덱스가 컨텍스트에 들어와 있으면 파일을 뒤지지 않고 답한다.

```bash
ls -la ~/.claude/projects/-ssd1-home-wonseon-song-test2-np-enterprise-sdk/memory/
```

기대: symlink을 통해 3개 메모리와 `MEMORY.md` 가 보인다.

- [ ] **Step 6: 원상 복구**

Step 4에서 바꾼 커밋 해시를 현재 HEAD 로 되돌리고 `⚠` 를 해제한다.

```bash
NEW=$(git -C /ssd1/home/wonseon.song/test2/np-enterprise rev-parse --short HEAD)
sed -i "s/@[0-9a-f]\{7,40\}\`/@$NEW\`/" ~/claude-memory/np-enterprise/presigned-url-issuer.md
echo '{}' | ~/claude-skills/note/scripts/memory-check.sh
grep presigned ~/claude-memory/np-enterprise/MEMORY.md
```

기대: `⚠` 없음.

---

## 완료 조건

- [ ] `bash note/tests/run.sh` → `ALL PASS`
- [ ] `~/.claude/settings.json` 의 훅 4종이 스크립트를 가리키고, 인라인 Slack 셸이 제거됨
- [ ] Slack 웹훅 URL이 `settings.json` 이 아니라 `~/.claude/.slack-webhook` 에만 있음
- [ ] 짧은 턴에 Slack 알림이 오지 않고, 3분 이상 걸린 턴에만 옴
- [ ] 알림 본문에 `(확인 불가)` 가 나오지 않음
- [ ] `sdk`/`backend` 어느 쪽에서 세션을 열어도 같은 메모리가 로드됨
- [ ] 근거 심볼을 바꾸면 다음 세션 시작 시 `⚠` 가 붙음
