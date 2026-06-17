self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$self_dir/../scripts" && pwd)"

run_prompt() {
  local input="$1"
  echo "$input" | "$script_dir/prompt-actualize.sh"
  echo "EXIT:$?"
}

# Case 1: Stop, first call (stop_hook_active=false) → exit 2 + reason
input=$(jq -nc '{session_id:"s1", cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "prompt Stop first: exit 2"
assert_contains "touch /tmp/vault-s1/last-actualize" "$out" "prompt Stop first: includes touch command"

# Case 2: Stop, second call (stop_hook_active=true) → exit 0, no output
input=$(jq -nc '{session_id:"s2", cwd:"/x", hook_event_name:"Stop", stop_hook_active:true}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt Stop second: exit 0"

# Case 3: PreCompact, no sentinel → exit 0 (never blocks; next Stop captures)
sid="s3"
rm -rf "/tmp/vault-${sid}"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"PreCompact", trigger:"auto"}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "prompt PreCompact no-sentinel: exit 0 (never blocks)"
rm -rf "/tmp/vault-${sid}"

# Case 4: Paused session → exit 0 silently for either event
sid="paused-actualize"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/paused"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt Stop paused: exit 0"
assert_eq "" "$out" "prompt Stop paused: no output"
rm -rf "/tmp/vault-${sid}"

# Case 5: Empty stdin → exit 0 (defensive)
out=$(echo "" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt empty stdin: exit 0"

# Case 6: Stop with fresh actualize sentinel → exit 0 (no nag)
sid="fresh-actualize"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt Stop fresh-sentinel: exit 0"
assert_eq "" "$out" "prompt Stop fresh-sentinel: no output"
rm -rf "/tmp/vault-${sid}"

# Case 7: Stop with stale sentinel → exit 0 (first-actualize-only: file exists = pass)
sid="stale-actualize"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch -d "10 minutes ago" "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt Stop stale-sentinel: exit 0 (first-actualize-only)"
rm -rf "/tmp/vault-${sid}"

# Case 9: PreCompact with stale sentinel → exit 0, invalidates sentinel (next Stop re-captures)
sid="stale-precompact"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch -d "10 minutes ago" "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"PreCompact", trigger:"auto"}')
out=$(echo "$input" | VAULT_ACTUALIZE_FRESHNESS_SECONDS=300 "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "prompt PreCompact stale-sentinel: exit 0 (never blocks)"
assert_eq "false" "$([[ -f "/tmp/vault-${sid}/last-actualize" ]] && echo true || echo false)" "prompt PreCompact stale-sentinel: invalidates sentinel"
rm -rf "/tmp/vault-${sid}"

# Case 8: PreCompact with fresh sentinel → exit 0
sid="fresh-precompact"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"PreCompact", trigger:"auto"}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt PreCompact fresh-sentinel: exit 0"
rm -rf "/tmp/vault-${sid}"
