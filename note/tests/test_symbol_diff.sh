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
# mod2.py: 동명이인(top-level process / Handler.process) — 메서드만 바꿀 예정.
cat > "$REPO/mod2.py" <<'PY'
def process():
    return "top"


class Handler:
    def process(self):
        return "method-base"
PY
# mod3.py: 동명이인 — 이번엔 top-level 쪽만 바꿀 예정 (메서드는 그대로).
cat > "$REPO/mod3.py" <<'PY'
def process():
    return "top-base"


class Handler:
    def process(self):
        return "method"
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
# mod2.py: Handler.process 만 바꾼다. top-level process 는 그대로.
cat > "$REPO/mod2.py" <<'PY'
def process():
    return "top"


class Handler:
    def process(self):
        return "method-CHANGED"
PY
# mod3.py: top-level process 만 바꾼다. Handler.process 는 그대로.
cat > "$REPO/mod3.py" <<'PY'
def process():
    return "top-CHANGED"


class Handler:
    def process(self):
        return "method"
PY
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
assert_eq "1" "$rc" "변경된 클래스: rc=1"

# 동명이인(top-level process / Handler.process) — bare name 은 매치 전부를 비교해야
# 메서드만 바뀐 걸 놓치지 않는다. 첫 매치(top-level)만 보던 예전 구현은 여기서
# UNCHANGED 를 내며 false negative 가 난다.
out=$(python3 "$SD" "$REPO" mod2.py process "$BASE"); rc=$?
assert_eq "CHANGED" "$out" "동명이인 bare name, 메서드만 변경: CHANGED"
assert_eq "1" "$rc" "동명이인 bare name, 메서드만 변경: rc=1"

# dotted qualified name 은 Handler.process 를 정확히 가리켜야 한다.
out=$(python3 "$SD" "$REPO" mod2.py Handler.process "$BASE"); rc=$?
assert_eq "CHANGED" "$out" "dotted Handler.process, 메서드 변경: CHANGED"
assert_eq "1" "$rc" "dotted Handler.process, 메서드 변경: rc=1"

# top-level process 만 바뀌고 Handler.process 는 그대로인 경우, dotted 이름은
# 메서드 쪽만 봐야 하므로 UNCHANGED 여야 한다.
out=$(python3 "$SD" "$REPO" mod3.py Handler.process "$BASE"); rc=$?
assert_eq "UNCHANGED" "$out" "dotted Handler.process, top-level 만 변경: UNCHANGED"
assert_eq "0" "$rc" "dotted Handler.process, top-level 만 변경: rc=0"

# 존재하지 않는 경로의 dotted name 은 MISSING 이어야 한다.
out=$(python3 "$SD" "$REPO" mod2.py NoSuchClass.process "$BASE"); rc=$?
assert_eq "MISSING" "$out" "존재하지 않는 dotted 경로: MISSING"
assert_eq "2" "$rc" "존재하지 않는 dotted 경로: rc=2"

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
