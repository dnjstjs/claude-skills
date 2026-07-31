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
