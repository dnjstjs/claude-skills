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
