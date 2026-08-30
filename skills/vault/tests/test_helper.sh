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

# Two clones over one origin, with B's pushed commit conflicting against A's local
# one — so A is genuinely diverged against a reachable remote.
_sync_fixture() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare -b main "$root/origin.git"
  git clone -q "$root/origin.git" "$root/A" 2>/dev/null
  git -C "$root/A" config user.email t@t; git -C "$root/A" config user.name t
  mkdir -p "$root/A/sg"
  printf '# index\n\n## Entry nodes\n\n- [[sg/one]] — base\n' > "$root/A/sg/_index.md"
  git -C "$root/A" add -A; git -C "$root/A" commit -qm base
  git -C "$root/A" push -q -u origin main

  git clone -q "$root/origin.git" "$root/B" 2>/dev/null
  git -C "$root/B" config user.email t@t; git -C "$root/B" config user.name t
  printf '# index\n\n## Entry nodes\n\n- [[sg/two]] — from B\n' > "$root/B/sg/_index.md"
  git -C "$root/B" add -A; git -C "$root/B" commit -qm B; git -C "$root/B" push -q

  printf '# index\n\n## Entry nodes\n\n- [[sg/three]] — from A\n' > "$root/A/sg/_index.md"
  git -C "$root/A" add -A; git -C "$root/A" commit -qm A
  # A cloned before B pushed, so its origin/main ref is stale — without this fetch
  # a `rebase origin/main` in the tests below is a silent no-op.
  git -C "$root/A" fetch -q origin
}
