#!/usr/bin/env bash
# 테스트 어서션 헬퍼. 각 test_*.sh가 source 한다.

FAILED=0

assert_eq() {  # <expected> <actual> <name>
  if [ "$1" = "$2" ]; then
    echo "  ok    $3"
  else
    echo "  FAIL  $3"
    echo "        expected: [$1]"
    echo "        actual:   [$2]"
    FAILED=1
  fi
}

assert_contains() {  # <haystack> <needle> <name>
  case "$1" in
    *"$2"*) echo "  ok    $3" ;;
    *)
      echo "  FAIL  $3"
      echo "        expected to contain: [$2]"
      echo "        actual:              [$1]"
      FAILED=1
      ;;
  esac
}

assert_rc() {  # <expected_rc> <actual_rc> <name>
  assert_eq "$1" "$2" "$3"
}

finish() {
  if [ "$FAILED" -eq 0 ]; then
    echo "PASS"
    exit 0
  fi
  echo "FAIL"
  exit 1
}
