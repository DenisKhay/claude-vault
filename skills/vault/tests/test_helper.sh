#!/usr/bin/env bash
# Tiny test framework for vault scripts.
# Usage: source this from each test_*.sh file. Call report() at end (run.sh does this).

test_count=${test_count:-0}
fail_count=${fail_count:-0}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-assert_eq}"
  test_count=$((test_count + 1))
  if [[ "$expected" != "$actual" ]]; then
    fail_count=$((fail_count + 1))
    echo "FAIL: $msg"
    echo "  expected: <$expected>"
    echo "  actual:   <$actual>"
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" msg="${3:-assert_contains}"
  test_count=$((test_count + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    fail_count=$((fail_count + 1))
    echo "FAIL: $msg"
    echo "  needle:   <$needle>"
    echo "  haystack: <$haystack>"
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2" msg="${3:-assert_not_contains}"
  test_count=$((test_count + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    fail_count=$((fail_count + 1))
    echo "FAIL: $msg"
    echo "  forbidden needle: <$needle>"
    echo "  haystack:         <$haystack>"
  fi
}

assert_exit() {
  local expected="$1" actual="$2" msg="${3:-assert_exit}"
  test_count=$((test_count + 1))
  if [[ "$expected" != "$actual" ]]; then
    fail_count=$((fail_count + 1))
    echo "FAIL: $msg"
    echo "  expected exit: $expected"
    echo "  actual exit:   $actual"
  fi
}

report() {
  local passed=$((test_count - fail_count))
  echo ""
  echo "Tests: $test_count  Passed: $passed  Failed: $fail_count"
  if [[ $fail_count -gt 0 ]]; then
    exit 1
  fi
}
