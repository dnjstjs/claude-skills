#!/usr/bin/env python3
"""근거 심볼이 기준 커밋 이후 실제로 바뀌었는지 판정한다.

사용법: symbol_diff.py <repo> <path> <symbol> <base_commit>

<symbol> 은 다음 두 형태를 지원한다:
    - bare name: "process" — 이름이 같은 정의가 여러 개면 모두 비교한다
      (클래스마다 __init__ 이 있는 등 동명이인이 흔하기 때문에, 첫 매치만
      보면 실제로 바뀐 정의를 놓치고 false UNCHANGED 를 낼 수 있다).
    - dotted qualified name: "Handler.process", "Outer.Inner.run" — 중첩
      경로를 따라 내려가 정확히 하나의 정의를 가리킨다. 모호함이 없으므로
      호출자는 가능하면 이 형태를 써야 한다.

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


def _find_by_name(tree: ast.AST, name: str) -> list[ast.AST]:
    """트리 전체에서 이름이 name 인 함수/클래스 정의를 소스 순서로 모두 찾는다.

    ast.walk() 는 BFS 라 소스 순서를 보장하지 않으므로, 매치를 모은 뒤
    (lineno, col_offset) 으로 정렬해 소스 순서를 맞춘다.
    """
    matches = [n for n in ast.walk(tree) if isinstance(n, DEFS) and n.name == name]
    matches.sort(key=lambda n: (n.lineno, n.col_offset))
    return matches


def _resolve_dotted(body: list[ast.stmt], parts: list[str]) -> list[ast.AST]:
    """body(정의 목록) 안에서 parts 로 표현된 중첩 경로를 따라 내려간다.

    각 단계에서 이름이 같은 정의가 여럿이면(비정상적이지만 가능) 모두
    따라 내려가 최종 매치를 전부 모은다 — 모호함을 조용히 무시하지 않기
    위함이다.
    """
    candidates = [n for n in body if isinstance(n, DEFS) and n.name == parts[0]]
    if len(parts) == 1:
        return candidates
    results: list[ast.AST] = []
    for node in candidates:
        results.extend(_resolve_dotted(node.body, parts[1:]))
    return results


def symbol_sources(source: str | None, symbol: str) -> list[str] | None:
    """소스에서 symbol 에 해당하는 모든 정의의 소스 조각 목록(소스 순서).

    source 가 없거나 파싱 불가면 None. symbol 이 파싱은 됐지만 하나도
    없으면 빈 리스트를 반환한다(둘은 호출부에서 동일하게 MISSING 처리됨).
    """
    if source is None:
        return None
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return None

    if "." in symbol:
        nodes = _resolve_dotted(tree.body, symbol.split("."))
    else:
        nodes = _find_by_name(tree, symbol)
    nodes.sort(key=lambda n: (n.lineno, n.col_offset))
    return [ast.get_source_segment(source, n) for n in nodes]


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: symbol_diff.py <repo> <path> <symbol> <base_commit>", file=sys.stderr)
        return 2
    repo, path, symbol, base = sys.argv[1:5]

    before = symbol_sources(source_at(repo, base, path), symbol)
    after = symbol_sources(source_at(repo, "HEAD", path), symbol)

    if before is None or after is None or not before or not after:
        print("MISSING")
        return 2

    # 매치 개수가 다르면(정의가 추가/삭제됐거나 애초에 모호한 이름이면)
    # 무엇이 바뀌었는지 안전하게 판단할 수 없으므로 CHANGED 로 처리한다.
    if len(before) != len(after):
        print("CHANGED")
        return 1

    if before == after:
        print("UNCHANGED")
        return 0
    print("CHANGED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
