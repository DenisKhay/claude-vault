self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$self_dir/../scripts" && pwd)"

run_prompt() {
  local input="$1"
  echo "$input" | "$script_dir/prompt-actualize.sh"
  echo "EXIT:$?"
}

# Case 1 (legacy nag, opt-in): Stop, first call (stop_hook_active=false) → exit 2 + reason
input=$(jq -nc '{session_id:"s1", cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | VAULT_STOP_CAPTURE=1 "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "prompt Stop first (VAULT_STOP_CAPTURE=1): exit 2"
assert_contains "touch /tmp/vault-s1/last-actualize" "$out" "prompt Stop first (VAULT_STOP_CAPTURE=1): includes touch command"

# Case 1b (NEW DEFAULT, 1.7.0): Stop is SILENT — no nag, exit 0 — and writes crash insurance instead:
# a spool record marked live with the owning claude pid, so the SessionEnd worker (or a relaunch after
# a crash) owns the capture off the human's critical path.
sroot=$(mktemp -d /tmp/vault-stop-test.XXXXXX)
input=$(jq -nc '{session_id:"s1b", cwd:"/x", hook_event_name:"Stop", stop_hook_active:false, transcript_path:"/x/t.jsonl"}')
out=$(echo "$input" | VAULT_STATE_DIR="$sroot/state" VAULT_SPOOL_DIR="$sroot/spool" "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "prompt Stop default: exit 0 (silent — capture is the worker's job)"
assert_not_contains "Vault sync" "$out" "prompt Stop default: no nag text"
[[ -f "$sroot/spool/s1b.json" ]] && got=present || got=missing
assert_eq "present" "$got" "prompt Stop default: writes the spool record (crash insurance)"
assert_eq "true" "$(jq -r .live "$sroot/spool/s1b.json" 2>/dev/null)" "prompt Stop default: the record is marked live"
rm -rf "$sroot"

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

# Case 7a: Stop with sentinel older than freshness → exit 2, delta re-sweep prompt
# (age-based re-arm, 2026-08-30: the old first-actualize-only gate lost every session tail)
sid="stale-actualize"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch -d "10 minutes ago" "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | VAULT_STOP_CAPTURE=1 VAULT_ACTUALIZE_FRESHNESS_SECONDS=300 "$script_dir/prompt-actualize.sh" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "prompt Stop stale-sentinel: exit 2 (age-based re-arm)"
assert_contains "sweep the DELTA" "$out" "prompt Stop stale-sentinel: asks for a delta sweep"
assert_contains "touch /tmp/vault-${sid}/last-actualize" "$out" "prompt Stop stale-sentinel: includes touch command"
rm -rf "/tmp/vault-${sid}"

# Case 7b: Stop with sentinel within the default freshness window (30 min) → exit 0
sid="fresh-enough-actualize"
rm -rf "/tmp/vault-${sid}"
mkdir -p "/tmp/vault-${sid}"
touch -d "10 minutes ago" "/tmp/vault-${sid}/last-actualize"
input=$(jq -nc --arg sid "$sid" '{session_id:$sid, cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}')
out=$(echo "$input" | "$script_dir/prompt-actualize.sh" 2>&1)
ec=$?
assert_exit "0" "$ec" "prompt Stop within-freshness: exit 0"
assert_eq "" "$out" "prompt Stop within-freshness: no output"
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
