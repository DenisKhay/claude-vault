self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$self_dir/../scripts" && pwd)"

# Use a low threshold so tests are fast.
THRESHOLD=3
FRESHNESS=300

tick() {
  local sid="$1"
  local input
  input=$(jq -nc --arg sid "$sid" \
    '{session_id:$sid, cwd:"/x", hook_event_name:"PostToolUse", tool_name:"Edit"}')
  echo "$input" | VAULT_TICK_THRESHOLD="$THRESHOLD" VAULT_TICK_FRESHNESS_SECONDS="$FRESHNESS" \
    "$script_dir/tick-and-maybe-prompt.sh"
}

# Case 1: First N-1 ticks → exit 0
sid="tick-test-1"
rm -rf "/tmp/vault-${sid}"
out=$(tick "$sid"); assert_exit "0" "$?" "tick 1: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick 2: exit 0"

# Case 2: Nth tick → exit 0 (M1: non-blocking advisory) + emits optional nudge
out=$(tick "$sid" 2>&1) && ec=$? || ec=$?; assert_exit "0" "$ec" "tick threshold: exit 0 (non-blocking)"
assert_contains "actualize" "$out" "tick threshold: advisory mentions actualize"
assert_contains "optional" "$out" "tick threshold: advisory is optional, not forced"

# Case 3: Counter resets after threshold → next tick is exit 0 again
out=$(tick "$sid"); assert_exit "0" "$?" "tick post-threshold reset: exit 0"
rm -rf "/tmp/vault-${sid}"

# Case 4: Recent actualize timestamp → counter doesn't fire
sid="tick-test-2"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/last-actualize"
out=$(tick "$sid"); assert_exit "0" "$?" "tick recent-actualize 1: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick recent-actualize 2: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick recent-actualize 3: exit 0 (would normally fire)"
rm -rf "/tmp/vault-${sid}"

# Case 5: Stale actualize timestamp (older than freshness) → counter does fire
sid="tick-test-3"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch -d "10 minutes ago" "/tmp/vault-${sid}/last-actualize"
out=$(tick "$sid"); assert_exit "0" "$?" "tick stale-actualize 1: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick stale-actualize 2: exit 0"
out=$(tick "$sid" 2>&1) && ec=$? || ec=$?; assert_exit "0" "$ec" "tick stale-actualize 3: exit 0 (non-blocking)"
assert_contains "actualize" "$out" "tick stale-actualize 3: advisory fired"
rm -rf "/tmp/vault-${sid}"

# Case 6: Paused session → exit 0, no counter increment
sid="tick-paused"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/paused"
out=$(tick "$sid"); assert_exit "0" "$?" "tick paused 1: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick paused 2: exit 0"
out=$(tick "$sid"); assert_exit "0" "$?" "tick paused 3: exit 0 (would normally fire)"
[[ ! -f "/tmp/vault-${sid}/tick" ]]; assert_exit "0" "$?" "tick paused: counter file not written"
rm -rf "/tmp/vault-${sid}"
