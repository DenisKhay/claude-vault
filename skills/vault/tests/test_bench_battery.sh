#!/usr/bin/env bash
# Structural checks on the bench batteries. Fixture-free on purpose — the scoring
# run needs the live vault and index, but a malformed or drifted battery should
# fail here, in the normal suite, rather than silently degrading the one number
# that is supposed to tell the truth about retrieval.

bench_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$bench_self_dir/bench"
VALIDATE="$BENCH_DIR/validate_battery.py"

for b in battery.json battery_heldout.json; do
  f="$BENCH_DIR/$b"
  if [[ ! -f "$f" ]]; then
    test_count=$((test_count + 1)); fail_count=$((fail_count + 1))
    echo "FAIL: bench: missing $b"
    continue
  fi
  out=$(python3 "$VALIDATE" "$f" 2>&1) && ec=$? || ec=$?
  assert_exit "0" "$ec" "bench: $b is structurally valid ($out)"
done

# The held-out battery only means something if it stays held out: its whole point
# is queries phrased in someone else's words. If it shrinks or drifts back toward
# node vocabulary, the overfit the re-audit found quietly returns.
n=$(python3 "$VALIDATE" "$BENCH_DIR/battery_heldout.json" 2>/dev/null || echo 0)
[[ "$n" =~ ^[0-9]+$ ]] && (( n >= 25 )) && got=enough || got="too few ($n)"
assert_eq "enough" "$got" "bench: the held-out battery carries at least 25 queries"
