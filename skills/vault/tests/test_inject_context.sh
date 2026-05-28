self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$self_dir/../scripts" && pwd)"

# Build a temp vault with sample registry + sample subgraph index at the right path.
tmp_vault="$(mktemp -d)"
trap 'rm -rf "$tmp_vault"' EXIT
cp "$self_dir/fixtures/sample-registry.yaml" "$tmp_vault/_registry.yaml"
mkdir -p "$tmp_vault/acme/portals"
cp "$self_dir/fixtures/sample-subgraph-index.md" "$tmp_vault/acme/portals/_index.md"

run_inject() {
  local cwd="$1"
  local session_id="${2:-test-session-1}"
  local input
  input=$(jq -nc --arg sid "$session_id" --arg cwd "$cwd" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}')
  echo "$input" | VAULT_ROOT="$tmp_vault" "$script_dir/inject-context.sh" 2>/dev/null
}

# Case 1: HIT — cwd inside ~/Projects/portals
out=$(run_inject "/home/user/projects/portals")
assert_contains "Vault context" "$out" "inject HIT: header present"
assert_contains "Matched subgraph: portals" "$out" "inject HIT: subgraph name"
assert_contains "acme/portals/_index.md" "$out" "inject HIT: entry path"
assert_contains "orders/orders" "$out" "inject HIT: entry node listed"
assert_contains "patients/patient-search" "$out" "inject HIT: entry node listed"
assert_not_contains "NO SUBGRAPH MATCHED" "$out" "inject HIT: no MISS marker"

# Case 2: MISS — unknown cwd
out=$(run_inject "/tmp/random-unenrolled-repo")
assert_contains "Vault context" "$out" "inject MISS: header present"
assert_contains "NO SUBGRAPH MATCHED" "$out" "inject MISS: noisy marker"
assert_contains "vault skill in 'enroll'" "$out" "inject MISS: enroll instruction"
assert_contains "/tmp/random-unenrolled-repo" "$out" "inject MISS: cwd echoed"

# Case 3: Paused session — silent (no output)
sid="paused-session-1"
mkdir -p "/tmp/vault-${sid}"
touch "/tmp/vault-${sid}/paused"
out=$(run_inject "/home/user/projects/portals" "$sid")
assert_eq "" "$out" "inject paused: no output"
rm -rf "/tmp/vault-${sid}"

# Case 4: Empty stdin (defensive)
out=$(echo "" | VAULT_ROOT="$tmp_vault" "$script_dir/inject-context.sh" 2>/dev/null)
# With empty stdin, HOOK_CWD falls back to PWD which may or may not match.
# Just verify the script doesn't crash and exits 0.
assert_exit "0" "$?" "inject empty stdin: exit 0"
