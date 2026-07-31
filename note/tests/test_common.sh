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
