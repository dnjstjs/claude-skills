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
