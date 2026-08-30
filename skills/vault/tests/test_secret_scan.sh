#!/usr/bin/env bash
# secret-scan.sh — the D6 guard. Locked decision 6 of the multi-machine design:
# auto-push makes "no secrets in nodes" a hard invariant, so a credential must be
# caught BEFORE it leaves the machine. Since 1.1.0 every sweep commits and pushes
# unattended, which collapsed the window between "an agent writes a token into an
# incident node" and "it is in permanent git history" to a few seconds.

sec_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sec_script_dir="$(cd "$sec_self_dir/../scripts" && pwd)"
SCAN="$sec_script_dir/secret-scan.sh"

# Assembled at runtime so this test file is not itself a bag of scannable tokens.
_fake() { printf '%s%s' "$1" "$(head -c 32 /dev/zero | tr '\0' 'A')"; }

_scan_one() {   # file body → "clean" | "caught"
  local d; d="$(mktemp -d)"
  printf '%b' "$1" > "$d/node.md"
  if bash "$SCAN" "$d/node.md" >/dev/null 2>&1; then echo clean; else echo caught; fi
  rm -rf "$d"
}

# --- catches the credential classes that actually exist in this environment ----
got=$(_scan_one "The token was $(_fake figd_) and it 401'd.\n")
assert_eq "caught" "$got" "D6: a Figma PAT in a node is caught"

got=$(_scan_one "glab was using $(_fake glpat-) when it broke.\n")
assert_eq "caught" "$got" "D6: a GitLab PAT is caught"

got=$(_scan_one "auth header: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk\n")
assert_eq "caught" "$got" "D6: a JWT is caught"

got=$(_scan_one "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n")
assert_eq "caught" "$got" "D6: a private key block is caught"

got=$(_scan_one "connect via postgres://svc_user:hunter2hunter2@db.internal:5432/app\n")
assert_eq "caught" "$got" "D6: a DSN with an inline password is caught"

got=$(_scan_one "AWS key AKIAIOSFODNN7EXAMPLE in the trace\n")
assert_eq "caught" "$got" "D6: an AWS access key id is caught"

# --- does NOT fire on the prose a knowledge vault is actually full of ----------
got=$(_scan_one "# Figma PAT\n\nStored in ~/.config/figma. Renew by 2026-11-28; 90-day expiry.\n")
assert_eq "clean" "$got" "D6: a node ABOUT a credential, with no credential in it, passes"

got=$(_scan_one "Set it as password: \"<your-token-here>\" in the config.\n")
assert_eq "clean" "$got" "D6: an obvious placeholder is not a finding"

got=$(_scan_one "The fix was token = REDACTED per the runbook.\n")
assert_eq "clean" "$got" "D6: a redaction marker is not a finding"

# --- the escape hatch, so a legitimate mention never becomes a permanent wall --
got=$(_scan_one "example format: $(_fake figd_)  <!-- vault-allow-secret: documented format -->\n")
assert_eq "clean" "$got" "D6: an inline vault-allow-secret marker on the same line allows it"

got=$(_scan_one "<!-- vault-allow-secret: the sample below is fabricated -->\nsample: $(_fake glpat-)\n")
assert_eq "clean" "$got" "D6: the marker on the preceding line allows it"

d="$(mktemp -d)"; printf 'tok %s\n' "$(_fake figd_)" > "$d/n.md"
VAULT_SKIP_SECRET_SCAN=1 bash "$SCAN" "$d/n.md" >/dev/null 2>&1 && got=clean || got=caught
assert_eq "clean" "$got" "D6: VAULT_SKIP_SECRET_SCAN=1 is an explicit override"
rm -rf "$d"

# --- the finding must be readable AND must not reprint the secret -------------
d="$(mktemp -d)"; tok="$(_fake figd_)"; printf 'the token was %s\n' "$tok" > "$d/n.md"
out=$(bash "$SCAN" "$d/n.md" 2>&1) || true
assert_contains "n.md:1" "$out" "D6: the finding names file and line"
assert_contains "figma-pat" "$out" "D6: the finding names the rule"
if [[ "$out" == *"$tok"* ]]; then got=leaked; else got=redacted; fi
assert_eq "redacted" "$got" "D6: the finding does NOT reprint the full secret"
rm -rf "$d"

# --- sync.sh integration: a sweep carrying a credential must not commit --------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'incident: the token was %s\n' "$(_fake figd_)" > "$tmp/A/sg/leaky.md"
before=$(git -C "$tmp/A" rev-parse HEAD)
out=$(VAULT_ROOT="$tmp/A" bash "$sec_script_dir/sync.sh" "leaky sweep" "sg/leaky.md" 2>&1) && ec=$? || ec=$?
after=$(git -C "$tmp/A" rev-parse HEAD)
assert_exit "2" "$ec" "D6: sync refuses (exit 2) when the sweep carries a credential"
assert_eq "$before" "$after" "D6: nothing is committed when a credential is found"
assert_contains "figma-pat" "$out" "D6: sync names the rule that fired"
[[ -f "$tmp/A/sg/leaky.md" ]] && got=present || got=GONE
assert_eq "present" "$got" "D6: the sweep's file is left intact on disk"
rm -rf "$tmp"

# --- ...and a clean sweep still goes through ----------------------------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'an ordinary, credential-free scar\n' > "$tmp/A/sg/clean.md"
out=$(VAULT_ROOT="$tmp/A" bash "$sec_script_dir/sync.sh" "clean sweep" "sg/clean.md" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "D6: a clean sweep is unaffected by the guard"
assert_contains "committed=1" "$out" "D6: a clean sweep still commits"
rm -rf "$tmp"
