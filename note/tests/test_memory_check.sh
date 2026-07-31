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
assert_contains "$OUT" "근거 없음 1건" "요약: 근거 없음(no-commit.md) 1건 별도 명시"

# 두 번 돌려도 파일 전체가 바이트 단위로 동일하다 (⚠ 및 ⚠ 삭제됨 모두 재계산 전 벗겨져야 함)
IDX_RUN1=$(cat "$STORE/MEMORY.md")
bash "$HERE/../scripts/memory-check.sh" <<< '{"session_id":"m1","cwd":"/tmp"}' >/dev/null
IDX_RUN2=$(cat "$STORE/MEMORY.md")
assert_eq "$IDX_RUN1" "$IDX_RUN2" "재실행: MEMORY.md 전체 내용 동일 (idempotent, ⚠/⚠ 삭제됨 모두 벗겨짐)"

# 저장소가 없어도 죽지 않는다
CC_MEMORY_STORE=/no/such/store bash "$HERE/../scripts/memory-check.sh" <<< '{}' >/dev/null && rc=0 || rc=$?
assert_eq "0" "$rc" "저장소 없음: 정상 종료"

# --- 예산 초과: 부분 검사 (under cap, over CC_MEMORY_BUDGET_SEC) ---
# 예산을 0으로 강제해 실제 소요 시간에 기대지 않고 결정적으로 재현한다.
# "마크유지"는 unchanged-one.md(Source 가 실제로는 안 바뀜)를 가리키면서도
# 인덱스에는 (이전 실행에서 남았다고 가정한) ⚠ 를 손으로 붙여 둔다 — 예산 안에서
# 실제로 검사했다면 벗겨질 표시라서, 가드가 없으면 이 항목이 벗겨지고
# 아래 assert_contains 가 실패한다(= 가드가 load-bearing 하다는 증거).
cat > "$STORE/MEMORY.md" <<'EOF'
- ⚠ [마크유지](unchanged-one.md) — 예산 초과로 미검사, 기존 표시 유지되어야 함
- [정상](changed-one.md) — 예산 초과로 미검사, 표시 없는 채 그대로여야 함
EOF
BEFORE_BUDGET=$(cat "$STORE/MEMORY.md")
OUT_BUDGET=$(CC_MEMORY_BUDGET_SEC=0 bash "$HERE/../scripts/memory-check.sh" <<< '{}')
AFTER_BUDGET=$(cat "$STORE/MEMORY.md")

assert_eq "$BEFORE_BUDGET" "$AFTER_BUDGET" "예산 0: 어떤 항목도 검사되지 않아 인덱스가 그대로"
assert_contains "$AFTER_BUDGET" "⚠ [마크유지](unchanged-one.md)" "예산 초과: 닿지 않은 항목의 기존 ⚠ 표시가 유지됨"
assert_contains "$OUT_BUDGET" "부분 검사" "예산 초과: 부분 검사임을 컨텍스트에 명시"
assert_contains "$OUT_BUDGET" "2건" "예산 초과: 건너뛴 항목 수(2건)를 명시"

# --- 항목 200건 초과 -> 검사 건너뛰고 정리 경고 (상한 초과, 예산과 무관) ---
: > "$STORE/MEMORY.md"
for i in $(seq 1 201); do echo "- [m$i](unchanged-one.md) — x" >> "$STORE/MEMORY.md"; done
BEFORE_CAP=$(cat "$STORE/MEMORY.md")
OUT=$(echo '{}' | bash "$HERE/../scripts/memory-check.sh")
AFTER_CAP=$(cat "$STORE/MEMORY.md")
assert_contains "$OUT" "정리 필요" "201건(상한 200 초과): 정리 경고"
assert_eq "$BEFORE_CAP" "$AFTER_CAP" "201건: 상한 초과로 스킵 -> 표시 변경 없음"

# --- Finding 1 회귀: 인덱스 마지막 줄에 개행이 없어도 항목이 사라지지 않는다 ---
# `read -r line` 는 개행 없는 마지막 줄에서 nonzero 로 리턴하므로, 가드 없이
# `while IFS= read -r line; do ... done < "$INDEX"` 로 돌리면 그 줄은 루프 몸통을
# 아예 타지 않아 TMP 에 쓰이지 않고, mv 로 통째 사라진다.
printf -- '- [첫째](unchanged-one.md) — 그대로\n- [둘째](changed-one.md) — 마지막 줄, 개행 없음' > "$STORE/MEMORY.md"
echo '{}' | bash "$HERE/../scripts/memory-check.sh" >/dev/null
IDX_NONL=$(cat "$STORE/MEMORY.md")
assert_contains "$IDX_NONL" "[첫째](unchanged-one.md)" "trailing newline 없음: 첫 항목 보존"
assert_contains "$IDX_NONL" "[둘째](changed-one.md)" "trailing newline 없음: 마지막(개행 없는) 항목 보존"
LINES_NONL=$(printf '%s' "$IDX_NONL" | grep -cE '^- ')
assert_eq "2" "$LINES_NONL" "trailing newline 없음: 항목 2건 모두 살아남음"

# --- Finding 2 회귀: Source 줄 뒤에 백틱이 더 있어도 커밋을 정확히 추출한다 ---
# 그리디 (.+) 는 줄의 마지막 백틱까지 삼켜, `**Source:** \`a\` (참고: \`b\`)` 같은
# 줄에서 커밋 추출이 조용히 실패하고 이 항목이 검사 없이 통과해버린다.
cat > "$STORE/greedy-source.md" <<EOF
---
name: greedy-source
description: greedy-source 설명
metadata:
  type: project
---

본문 — Source 줄 뒤에 참고용 백틱이 하나 더 붙어 있다.

**Source:** \`mod.py#volatile@$BASE\` (참고: \`other.py\` 도 봄)
**Verified:** 2026-07-01
EOF
printf -- '- [그리디](greedy-source.md) — volatile 은 실제로 바뀜\n' > "$STORE/MEMORY.md"
echo '{}' | bash "$HERE/../scripts/memory-check.sh" >/dev/null
IDX_GREEDY=$(cat "$STORE/MEMORY.md")
assert_contains "$IDX_GREEDY" "- ⚠ [그리디](greedy-source.md)" "greedy Source: 뒤 백틱 있어도 커밋 정확 추출, ⚠ 붙음"

# --- Finding 3 회귀: 근거 없는 항목 수를 세어 별도 문구로 알린다 ---
# Source 가 없거나 커밋을 추출할 수 없는 항목은 stale 검사 대상이 아니다.
# 표시가 안 붙는 것과 "검사해서 이상 없음"이 구분되지 않으면, 사용자는
# 지켜보지 않는 메모리도 지켜지고 있다고 착각하게 된다.
mk no-source-a "mod.py#stable"
mk no-source-b "mod.py#stable"
cat > "$STORE/MEMORY.md" <<'EOF'
- [정상](unchanged-one.md) — 그대로
- [근거1](no-source-a.md) — Source 있지만 커밋 없음
- [근거2](no-source-b.md) — Source 있지만 커밋 없음
EOF
OUT_NS=$(echo '{}' | bash "$HERE/../scripts/memory-check.sh")
assert_contains "$OUT_NS" "근거 없음 2건" "근거 없음 카운트: 정확히 2건, stale 요약과 구분되는 문구"

finish
