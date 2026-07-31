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

# Claude Code의 실제 프로젝트 디렉토리 인코딩과 일치시킨다: '/' 뿐 아니라
# 영숫자가 아닌 모든 문자를 '-'로 치환 (mktemp가 만드는 /tmp/tmp.XXXX 처럼
# 경로에 '.'이 섞여 있어도 실제 규칙과 어긋나지 않는지 검증하기 위함).
# realpath 출력의 개행을 먼저 $()로 제거한 뒤 tr -c에 넘긴다 (setup.sh와 동일 순서).
enc=$(printf '%s' "$(realpath "$PROJ_ROOT/sdk")" | tr -c 'A-Za-z0-9' '-')
LINK="$FAKE_HOME/.claude/projects/$enc/memory"
assert_eq "true" "$([ -L "$LINK" ] && echo true || echo false)" "sdk memory symlink 생성됨"
assert_eq "$STORE" "$(readlink "$LINK")" "sdk symlink 대상 정확"

# 존재하지 않는 하위 디렉터리는 건너뛴다
enc2=$(printf '%s' "$(realpath "$PROJ_ROOT")" | tr -c 'A-Za-z0-9' '-')-engine
assert_eq "false" "$([ -e "$FAKE_HOME/.claude/projects/$enc2/memory" ] && echo true || echo false)" "없는 디렉터리는 건너뜀"

# 재실행해도 깨지지 않는다
HOME="$FAKE_HOME" CC_MEMORY_STORE="$STORE" CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
  bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1
assert_eq "$STORE" "$(readlink "$LINK")" "재실행: symlink 유지"

finish
