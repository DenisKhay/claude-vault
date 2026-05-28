# Run via: tests/run.sh — do not execute directly
# Sanity check: the test framework itself works.
assert_eq "a" "a" "smoke: equal strings"
assert_contains "foo" "foobar" "smoke: substring"
assert_not_contains "zzz" "foobar" "smoke: not substring"
assert_exit "0" "0" "smoke: exit code"
