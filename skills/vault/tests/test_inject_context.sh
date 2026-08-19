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

# Case 5: an Entry-nodes list past MAX_ARG_STRLEN (128 KiB per argv string). This is the regression
# that killed SessionStart in the field: the block went to `jq --arg`, execve returned E2BIG, and the
# hook exited non-zero having emitted NOTHING — sessions started with no vault context at all.
big_vault="$(mktemp -d)"
trap 'rm -rf "$tmp_vault" "$big_vault"' EXIT
cp "$self_dir/fixtures/sample-registry.yaml" "$big_vault/_registry.yaml"
mkdir -p "$big_vault/acme/portals"
{
  printf '# portals\n\n## Entry nodes\n'
  for i in $(seq 1 400); do
    printf -- '- [[orders/node-%s]] — %s\n' "$i" "$(printf 'ъ%.0s' $(seq 1 200))"
  done
  printf '\n## Subgraph map\n'
} > "$big_vault/acme/portals/_index.md"

run_big() {
  local input
  input=$(jq -nc '{session_id:"big-session", cwd:"/home/user/projects/portals", hook_event_name:"SessionStart", source:"startup"}')
  echo "$input" | VAULT_ROOT="$big_vault" "$@" "$script_dir/inject-context.sh" 2>/dev/null
}

raw_index_bytes=$(wc -c < "$big_vault/acme/portals/_index.md")
assert_eq "yes" "$([[ $raw_index_bytes -gt 131072 ]] && echo yes || echo no)" \
  "inject oversized: fixture actually exceeds the 128 KiB argv ceiling ($raw_index_bytes B)"

out=$(run_big env); rc=$?
assert_exit "0" "$rc" "inject oversized: exit 0"
assert_contains "Vault context" "$out" "inject oversized: still emits a block"
assert_contains "vault_search" "$out" "inject oversized: retrieval trailer survives truncation"
assert_contains "omitted" "$out" "inject oversized: says what it dropped"
valid=$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    json.load(sys.stdin); print("yes")
except Exception:
    print("no")')
assert_eq "yes" "$valid" "inject oversized: emits valid JSON"
out_bytes=$(printf '%s' "$out" | wc -c)
assert_eq "yes" "$([[ $out_bytes -lt 65536 ]] && echo yes || echo no)" \
  "inject oversized: block stays bounded ($out_bytes B)"

# Case 6: the guards are tunable, and clamping never splits a UTF-8 character.
out=$(run_big env VAULT_MAX_BULLET_CHARS=40 VAULT_MAX_CONTEXT_BYTES=2000)
valid=$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    json.load(sys.stdin); print("yes")
except Exception:
    print("no")')
assert_eq "yes" "$valid" "inject tuned guards: still valid JSON (no split multibyte char)"
tuned_bytes=$(printf '%s' "$out" | wc -c)
assert_eq "yes" "$([[ $tuned_bytes -lt $out_bytes ]] && echo yes || echo no)" \
  "inject tuned guards: tighter budget yields a smaller block ($tuned_bytes < $out_bytes)"

# Case 7: with the guards off, nothing is dropped — and the block still ships (no argv ceiling).
out=$(run_big env VAULT_MAX_BULLET_CHARS=0 VAULT_MAX_CONTEXT_BYTES=0)
assert_not_contains "omitted" "$out" "inject guards off: nothing dropped"
assert_contains "orders/node-400" "$out" "inject guards off: last bullet present"

# Case 8: no python3 on PATH — jq renders the JSON instead, still over stdin, still exit 0.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_vault" "$big_vault" "$stub_dir"' EXIT
printf '#!/bin/sh\nexit 127\n' > "$stub_dir/python3"; chmod +x "$stub_dir/python3"
input=$(jq -nc '{session_id:"nopy-session", cwd:"/home/user/projects/portals", hook_event_name:"SessionStart", source:"startup"}')
out=$(echo "$input" | PATH="$stub_dir:$PATH" VAULT_ROOT="$big_vault" "$script_dir/inject-context.sh" 2>/dev/null); rc=$?
assert_exit "0" "$rc" "inject no-python3: exit 0"
assert_contains "Vault context" "$out" "inject no-python3: block still emitted"

# Case 8b: the jq fallback's own stdin form must clear the argv ceiling too — this is the exact
# mechanism the old `jq --arg` broke on, so assert it directly rather than trusting the shape.
big_block=$(printf 'x%.0s' $(seq 1 200000))
jq_out=$(printf '%s' "$big_block" | jq -Rsc '{suppressOutput: true, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null); rc=$?
assert_exit "0" "$rc" "jq stdin form: 200 KB block renders (argv form would be E2BIG)"
assert_contains "SessionStart" "$jq_out" "jq stdin form: JSON shape intact"

# Case 9: neither python3 nor jq — plain stdout, never silence.
printf '#!/bin/sh\nexit 127\n' > "$stub_dir/jq"; chmod +x "$stub_dir/jq"
out=$(echo "$input" | PATH="$stub_dir:$PATH" VAULT_ROOT="$tmp_vault" "$script_dir/inject-context.sh" 2>/dev/null); rc=$?
assert_exit "0" "$rc" "inject no-renderer: exit 0"
assert_contains "Vault context" "$out" "inject no-renderer: falls back to plain stdout"
