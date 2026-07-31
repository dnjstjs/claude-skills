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

run_setup() {
  HOME="$FAKE_HOME" CC_MEMORY_STORE="$STORE" CC_MEMORY_PROJECT_ROOT="$PROJ_ROOT" \
    bash -c '. "'"$HERE"'/../../setup.sh" --memory-only' >/dev/null 2>&1
}

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
run_setup
assert_eq "$STORE" "$(readlink "$LINK")" "재실행: symlink 유지"

# ── Finding 5 재현 + 수정 검증: target 자리에 이미 실제 디렉터리(파일 내용 포함)가
# 있는 경우 — 51개 메모리 파일이 조용히 displaced 됐던 바로 그 경로.
# 예전 동작(displace): 디렉터리 전체를 .bak 로 치우고 빈 저장소를 symlink.
# 새 동작(adopt): 저장소에 없는 파일은 저장소로 흡수하고, symlink 로 교체한다.
# 지금까지 한 번도 다뤄지지 않은 "engine" 서브디렉터리를 새로 만들어 사용한다 —
# sdk/qa/backend는 이미 위에서 symlink로 처리됐으므로 재사용하면 이 케이스를
# 검증하지 못한 채 통과해버린다 (target이 이미 symlink라 백업 분기를 타지 않음).
mkdir -p "$PROJ_ROOT/engine"
qenc=$(printf '%s' "$(realpath "$PROJ_ROOT/engine")" | tr -c 'A-Za-z0-9' '-')
QTARGET="$FAKE_HOME/.claude/projects/$qenc/memory"
mkdir -p "$QTARGET"
ADOPT_CONTENT="adopted memory content — must end up copied into the shared store"
printf '%s' "$ADOPT_CONTENT" > "$QTARGET/adopt-me.md"

run_setup

assert_eq "true" "$([ -L "$QTARGET" ] && echo true || echo false)" "engine: dir → symlink 로 교체됨 (adopt 후)"
assert_eq "$STORE" "$(readlink "$QTARGET" 2>/dev/null)" "engine: symlink 대상 정확"
assert_eq "true" "$([ -f "$STORE/adopt-me.md" ] && echo true || echo false)" "engine: 비충돌 파일이 저장소로 흡수됨 (displace 아님)"
assert_eq "$ADOPT_CONTENT" "$(cat "$STORE/adopt-me.md" 2>/dev/null)" "engine: 흡수된 파일 내용이 byte-for-byte 보존됨"

# 충돌이 없으므로 이 프로젝트 아래에 .bak 디렉터리가 생기면 안 된다 — 예전
# displace 동작이었다면 여기서 memory.bak.* 가 생겼을 것이다.
qbak=$(find "$FAKE_HOME/.claude/projects/$qenc" -maxdepth 1 -name 'memory.bak.*' 2>/dev/null | head -1)
assert_eq "false" "$([ -n "$qbak" ] && echo true || echo false)" "engine: 충돌 없음 → .bak 생성 안 됨 (메모리가 사라지지 않음)"

# ── Finding 1(이전 finding) 재현: target 자리에 디렉터리가 아니라 '평범한 파일'이
# 있는 경우. ln -sfn 은 이런 노드를 경고 없이 덮어쓴다 — 반드시 백업되어야 한다.
# (이 분기는 Finding 5 수정 대상이 아니다 — 그대로 유지되는지만 재확인한다.)
mkdir -p "$PROJ_ROOT/client"
benc=$(printf '%s' "$(realpath "$PROJ_ROOT/client")" | tr -c 'A-Za-z0-9' '-')
BTARGET="$FAKE_HOME/.claude/projects/$benc/memory"
mkdir -p "$(dirname "$BTARGET")"
FILE_CONTENT="plain file sitting where a dir/symlink was expected"
printf '%s' "$FILE_CONTENT" > "$BTARGET"

run_setup

assert_eq "true" "$([ -L "$BTARGET" ] && echo true || echo false)" "client: 평범한 파일이 destroy 되지 않고 symlink 로 교체됨"
assert_eq "$STORE" "$(readlink "$BTARGET" 2>/dev/null)" "client: symlink 대상 정확"

bbak=$(find "$FAKE_HOME/.claude/projects/$benc" -maxdepth 1 -name 'memory.bak.*' | head -1)
assert_eq "true" "$([ -n "$bbak" ] && [ -f "$bbak" ] && echo true || echo false)" "client: 평범한 파일이 .bak 으로 백업됨 (destroy 아님)"
assert_eq "$FILE_CONTENT" "$(cat "$bbak" 2>/dev/null)" "client: 백업된 파일 내용이 byte-for-byte 보존됨"

# ── Finding 5 핵심 시나리오: 충돌 파일은 덮어쓰지 않고 .bak 에 남기며 보고한다,
# MEMORY.md 는 클로버가 아니라 병합된다 (중복 없이) ──
mkdir -p "$PROJ_ROOT/common"
cenc=$(printf '%s' "$(realpath "$PROJ_ROOT/common")" | tr -c 'A-Za-z0-9' '-')
CTARGET="$FAKE_HOME/.claude/projects/$cenc/memory"
mkdir -p "$CTARGET"

# 저장소에는 이미 이 이름의 파일이 있고, 들어오는 쪽은 내용이 다르다 -> 충돌
STORE_VERSION="store version — already there, must not be overwritten"
INCOMING_VERSION="incoming version — DIFFERENT content, must be preserved in .bak"
printf '%s' "$STORE_VERSION" > "$STORE/conflict-note.md"
printf '%s' "$INCOMING_VERSION" > "$CTARGET/conflict-note.md"

# 저장소에 없는 새 파일 -> 비충돌 흡수
FRESH_CONTENT="brand new content contributed by common"
printf '%s' "$FRESH_CONTENT" > "$CTARGET/fresh-note.md"

# MEMORY.md 병합: 저장소 인덱스에 이미 있는 줄은 중복되면 안 되고, 새 줄은 이어붙는다
printf '%s\n' "- [기존줄](adopt-me.md) — 이미 저장소 인덱스에도 있음" > "$STORE/MEMORY.md"
cat > "$CTARGET/MEMORY.md" <<'EOF'
- [기존줄](adopt-me.md) — 이미 저장소 인덱스에도 있음
- [새줄](fresh-note.md) — common 에서 새로 들어옴
EOF

run_setup

assert_eq "true" "$([ -L "$CTARGET" ] && echo true || echo false)" "common: dir → symlink 로 교체됨"
assert_eq "$FRESH_CONTENT" "$(cat "$STORE/fresh-note.md" 2>/dev/null)" "common: 비충돌 새 파일이 저장소로 흡수됨"
assert_eq "$STORE_VERSION" "$(cat "$STORE/conflict-note.md" 2>/dev/null)" "common: 충돌 파일 — 저장소 쪽 내용이 덮어써지지 않음"

cbak=$(find "$FAKE_HOME/.claude/projects/$cenc" -maxdepth 1 -name 'memory.bak.*' -type d | head -1)
assert_eq "true" "$([ -n "$cbak" ] && [ -d "$cbak" ] && echo true || echo false)" "common: 충돌 파일용 .bak 디렉터리 생성됨"
assert_eq "$INCOMING_VERSION" "$(cat "$cbak/conflict-note.md" 2>/dev/null)" "common: 들어오는 쪽 충돌 내용이 .bak 에 byte-for-byte 보존됨"

DUPCOUNT=$(grep -cxF -- "- [기존줄](adopt-me.md) — 이미 저장소 인덱스에도 있음" "$STORE/MEMORY.md")
assert_eq "1" "$DUPCOUNT" "common: MEMORY.md 병합 — 이미 있던 줄이 중복되지 않음"
assert_contains "$(cat "$STORE/MEMORY.md")" "- [새줄](fresh-note.md)" "common: MEMORY.md 병합 — 새 줄이 이어붙여짐"

# ── 멱등성: 같은 대상(common)에 대해 한 번 더 돌려도 결과가 흔들리지 않는다 ──
# 이번엔 target이 이미 symlink이므로 adopt 분기를 다시 타지 않는다: 새 .bak 이
# 추가로 생기지 않고, MEMORY.md 줄 수도 늘어나지 않아야 한다.
BEFORE_IDEMP_LINES=$(wc -l < "$STORE/MEMORY.md")
BEFORE_IDEMP_BAKS=$(find "$FAKE_HOME/.claude/projects/$cenc" -maxdepth 1 -name 'memory.bak.*' -type d | wc -l)

run_setup

AFTER_IDEMP_LINES=$(wc -l < "$STORE/MEMORY.md")
AFTER_IDEMP_BAKS=$(find "$FAKE_HOME/.claude/projects/$cenc" -maxdepth 1 -name 'memory.bak.*' -type d | wc -l)
assert_eq "true" "$([ -L "$CTARGET" ] && echo true || echo false)" "멱등성: common 재실행 후에도 symlink 유지"
assert_eq "$STORE" "$(readlink "$CTARGET" 2>/dev/null)" "멱등성: common symlink 대상 정확"
assert_eq "$BEFORE_IDEMP_LINES" "$AFTER_IDEMP_LINES" "멱등성: 재실행으로 MEMORY.md 줄 수가 늘지 않음"
assert_eq "$BEFORE_IDEMP_BAKS" "$AFTER_IDEMP_BAKS" "멱등성: 재실행으로 .bak 디렉터리가 추가되지 않음"

finish
