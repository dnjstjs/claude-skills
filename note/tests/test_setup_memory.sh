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

# ── 실제 사고 재현: target 자리에 이미 실제 디렉터리(파일 내용 포함)가 있는 경우 ──
# 51개 메모리 파일이 조용히 displaced 됐던 바로 그 경로.
# 지금까지 한 번도 다뤄지지 않은 "engine" 서브디렉터리를 새로 만들어 사용한다 —
# sdk/qa/backend는 이미 위에서 symlink로 처리됐으므로 재사용하면 이 케이스를
# 검증하지 못한 채 통과해버린다 (target이 이미 symlink라 백업 분기를 타지 않음).
mkdir -p "$PROJ_ROOT/engine"
qenc=$(printf '%s' "$(realpath "$PROJ_ROOT/engine")" | tr -c 'A-Za-z0-9' '-')
QTARGET="$FAKE_HOME/.claude/projects/$qenc/memory"
mkdir -p "$QTARGET"
ORIGINAL_CONTENT="original memory content — must survive byte-for-byte"
printf '%s' "$ORIGINAL_CONTENT" > "$QTARGET/note1.md"

HOME="$FAKE_HOME" CC_MEMORY_STORE="$STORE" CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
  bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1

assert_eq "true" "$([ -L "$QTARGET" ] && echo true || echo false)" "engine: 기존 dir 백업 후 symlink 로 교체됨"
assert_eq "$STORE" "$(readlink "$QTARGET" 2>/dev/null)" "engine: symlink 대상 정확"

qbak=$(find "$FAKE_HOME/.claude/projects/$qenc" -maxdepth 1 -name 'memory.bak.*' -type d | head -1)
assert_eq "true" "$([ -n "$qbak" ] && [ -d "$qbak" ] && echo true || echo false)" "engine: .bak. 디렉터리가 생성됨"
assert_eq "$ORIGINAL_CONTENT" "$(cat "$qbak/note1.md" 2>/dev/null)" "engine: 백업 안의 원본 파일 내용이 byte-for-byte 보존됨"

# ── Finding 1 재현: target 자리에 디렉터리가 아니라 '평범한 파일'이 있는 경우 ──
# ln -sfn 은 이런 노드를 경고 없이 덮어쓴다 — 반드시 백업되어야 한다.
# 마찬가지로 아직 손대지 않은 "client" 서브디렉터리를 새로 사용한다.
mkdir -p "$PROJ_ROOT/client"
benc=$(printf '%s' "$(realpath "$PROJ_ROOT/client")" | tr -c 'A-Za-z0-9' '-')
BTARGET="$FAKE_HOME/.claude/projects/$benc/memory"
mkdir -p "$(dirname "$BTARGET")"
FILE_CONTENT="plain file sitting where a dir/symlink was expected"
printf '%s' "$FILE_CONTENT" > "$BTARGET"

HOME="$FAKE_HOME" CC_MEMORY_STORE="$STORE" CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
  bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1

assert_eq "true" "$([ -L "$BTARGET" ] && echo true || echo false)" "client: 평범한 파일이 destroy 되지 않고 symlink 로 교체됨"
assert_eq "$STORE" "$(readlink "$BTARGET" 2>/dev/null)" "client: symlink 대상 정확"

bbak=$(find "$FAKE_HOME/.claude/projects/$benc" -maxdepth 1 -name 'memory.bak.*' | head -1)
assert_eq "true" "$([ -n "$bbak" ] && [ -f "$bbak" ] && echo true || echo false)" "client: 평범한 파일이 .bak. 으로 백업됨 (destroy 아님)"
assert_eq "$FILE_CONTENT" "$(cat "$bbak" 2>/dev/null)" "client: 백업된 파일 내용이 byte-for-byte 보존됨"

finish
