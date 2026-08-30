#!/usr/bin/env bash
# A pause must be VISIBLE. Before 1.3.2 SessionStart exited silently when paused,
# which made this the one control whose failure mode was invisible in both
# directions: you could not tell it was on, and you could not tell it had never
# engaged — and it hadn't, for months, because the flag was keyed on a variable
# that is unset in slash-command shells.
#
# It deliberately does NOT auto-expire. Lapsing a pause would resume capture
# inside the sensitive work it was switched on for, and auto-push would put that
# on a remote within seconds. So the contract is: persists until lifted, and says
# so at every session start, louder once it is more than a day old.

pause_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pause_script_dir="$(cd "$pause_self_dir/../scripts" && pwd)"

# VAULT_ROOT is redirected to an empty temp dir: without it the unpaused case
# below runs the real SessionStart path against ~/Vaults, which kicks off a
# background `git pull` holding that vault's lock — and the sync tests then fail
# on a 30s lock timeout. Tests must never touch the operator's store.
_inject() {   # cwd → SessionStart output
  jq -nc --arg cwd "$1" \
    '{session_id:"pausetest", cwd:$cwd, hook_event_name:"SessionStart"}' \
    | VAULT_ROOT="$pause_fake_vault" "$pause_script_dir/inject-context.sh" 2>/dev/null
}

pause_fake_vault="$(mktemp -d)"
tmpcwd="$(mktemp -d)"
flag="/tmp/vault-pause-$(printf '%s' "$tmpcwd" | md5sum | cut -c1-12)"
rm -f "$flag"

# --- not paused: normal behaviour, and no false alarm ------------------------
out=$(_inject "$tmpcwd")
if [[ "$out" == *"VAULT PAUSED"* ]]; then got=announced; else got=silent; fi
assert_eq "silent" "$got" "pause: an unpaused workspace does not claim to be paused"

# --- paused: the state is announced, not silent ------------------------------
touch "$flag"
out=$(_inject "$tmpcwd")
assert_contains "VAULT PAUSED" "$out" "pause: a paused workspace says so at SessionStart"
assert_contains "vault-resume" "$out" "pause: the banner names the way out"
assert_contains "spooled" "$out" "pause: the banner warns that crash recovery is off too"

# --- an aged pause escalates, because a forgotten one is the real failure -----
touch -d "@$(( $(date +%s) - 3 * 24 * 3600 ))" "$flag"
out=$(_inject "$tmpcwd")
assert_contains "3d" "$out" "pause: a 3-day-old pause reports its age"
assert_contains "over a day old" "$out" "pause: an aged pause escalates its wording"

# --- and it must still actually pause ----------------------------------------
if [[ "$out" == *"Entry nodes"* || "$out" == *"NO SUBGRAPH MATCHED"* ]]; then
  got=leaked
else
  got=suppressed
fi
assert_eq "suppressed" "$got" "pause: no vault context is injected while paused"

rm -f "$flag"; rm -rf "$tmpcwd" "$pause_fake_vault"
