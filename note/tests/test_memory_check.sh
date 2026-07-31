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
cat > "$REPO/deleted.py" <<'PY'
def doomed():
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
rm "$REPO/deleted.py"
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
mk deleted-one   "deleted.py#doomed@$BASE"

cat > "$STORE/MEMORY.md" <<'EOF'
- [안 바뀜](unchanged-one.md) — 그대로
- ⚠ [바뀜](changed-one.md) — 변경됨
- [파일단위](file-level.md) — py 아님
- [커밋없음](no-commit.md) — 기준 없음
- [삭제됨](deleted-one.md) — 파일이 사라짐
EOF

echo "test_memory_check"

export CC_MEMORY_STORE="$STORE"
OUT=$(echo '{"session_id":"m1","cwd":"/tmp"}' | bash "$HERE/../scripts/memory-check.sh")

IDX=$(cat "$STORE/MEMORY.md")
assert_contains "$IDX" "- [안 바뀜](unchanged-one.md)" "변경 없음: ⚠ 안 붙음"
assert_contains "$IDX" "- ⚠ [바뀜](changed-one.md)" "변경됨: ⚠ 붙음"
assert_contains "$IDX" "- ⚠ [파일단위](file-level.md)" "py 아님: 파일 단위 폴백으로 ⚠"
assert_contains "$IDX" "- [커밋없음](no-commit.md)" "커밋 없음: 건너뜀"
assert_contains "$IDX" "- ⚠ 삭제됨 [삭제됨](deleted-one.md)" "심볼 근거 파일 삭제됨: ⚠ 삭제됨 붙음 (MISSING 판정 실사용)"

assert_contains "$OUT" "additionalContext" "SessionStart JSON 출력"
assert_contains "$OUT" "재확인 필요 3건" "요약: 3건"

# 두 번 돌려도 파일 전체가 바이트 단위로 동일하다 (⚠ 및 ⚠ 삭제됨 모두 재계산 전 벗겨져야 함)
IDX_RUN1=$(cat "$STORE/MEMORY.md")
bash "$HERE/../scripts/memory-check.sh" <<< '{"session_id":"m1","cwd":"/tmp"}' >/dev/null
IDX_RUN2=$(cat "$STORE/MEMORY.md")
assert_eq "$IDX_RUN1" "$IDX_RUN2" "재실행: MEMORY.md 전체 내용 동일 (idempotent, ⚠/⚠ 삭제됨 모두 벗겨짐)"

# 저장소가 없어도 죽지 않는다
CC_MEMORY_STORE=/no/such/store bash "$HERE/../scripts/memory-check.sh" <<< '{}' >/dev/null && rc=0 || rc=$?
assert_eq "0" "$rc" "저장소 없음: 정상 종료"

# 항목 50건 초과 -> 검사 건너뛰고 정리 경고
: > "$STORE/MEMORY.md"
for i in $(seq 1 51); do echo "- [m$i](unchanged-one.md) — x" >> "$STORE/MEMORY.md"; done
OUT=$(echo '{}' | bash "$HERE/../scripts/memory-check.sh")
assert_contains "$OUT" "정리 필요" "51건: 정리 경고"

finish
