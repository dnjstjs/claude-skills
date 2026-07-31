#!/usr/bin/env bash
# 모든 테스트를 실행한다. 하나라도 실패하면 1로 종료.
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "── $(basename "$t") ──"
  bash "$t" || rc=1
  echo
done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$rc"
