# Test match.sh against the sample registry fixture.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_dir="$(cd "$self_dir/../scripts" && pwd)"
fixture="$self_dir/fixtures/sample-registry.yaml"

# Build a temp vault root containing only the sample registry.
tmp_vault="$(mktemp -d)"
trap 'rm -rf "$tmp_vault"' EXIT
cp "$fixture" "$tmp_vault/_registry.yaml"

run_match() {
  VAULT_ROOT="$tmp_vault" "$script_dir/match.sh" "$1" 2>/dev/null
}

# Case 1: path_prefix match — cwd inside ~/Projects/portals
out=$(run_match "/home/user/projects/portals")
assert_eq "portals" "$out" "match: path_prefix exact root"

# Case 2: path_prefix match — cwd inside subdirectory
out=$(run_match "/home/user/projects/portals/src/components")
assert_eq "portals" "$out" "match: path_prefix subdirectory"

# Case 3: path_prefix match — different project
out=$(run_match "/home/user/projects/patient-mobile-application")
assert_eq "patient-mobile" "$out" "match: path_prefix patient-mobile"

# Case 4: No match — unknown cwd
out=$(run_match "/tmp/some-random-dir")
assert_eq "MISS" "$out" "match: unknown cwd is MISS"

# Case 5: Empty registry — MISS
empty_vault="$(mktemp -d)"
echo "subgraphs: []" > "$empty_vault/_registry.yaml"
out=$(VAULT_ROOT="$empty_vault" "$script_dir/match.sh" "/home/user/projects/portals" 2>/dev/null)
assert_eq "MISS" "$out" "match: empty registry is MISS"
rm -rf "$empty_vault"

# Case 6: Missing registry file — MISS, no crash
missing_vault="$(mktemp -d)"
out=$(VAULT_ROOT="$missing_vault" "$script_dir/match.sh" "/home/user/projects/portals" 2>/dev/null)
assert_eq "MISS" "$out" "match: missing registry is MISS"
rm -rf "$missing_vault"
