#!/usr/bin/env bash
# PreCompact must leave its own evidence.
#
# Two audits concluded "PreCompact has never fired" by grepping transcripts for
# isCompactSummary / compact_boundary / compactMetadata and finding nothing in
# 90+ files. Claude Code's docs say the transcript entry format is internal and
# changes between versions — so a guessed key returning zero proves nothing, and
# that conclusion was never supported. Auto-compaction is on by default and does
# fire this hook (trigger=auto), so it may have been firing the whole time.
#
# The fix is not a better grep, it is to stop reading someone else's unstable
# format: the hook records its own firings, and one real compaction settles it.

pc_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pc_script_dir="$(cd "$pc_self_dir/../scripts" && pwd)"

pc_state="$(mktemp -d)"
_precompact() {   # session id, trigger, sentinel age in seconds ("" = none)
  local sid="$1" trig="$2" age="${3:-}"
  rm -rf "/tmp/vault-${sid}"
  if [[ -n "$age" ]]; then
    mkdir -p "/tmp/vault-${sid}"
    touch -d "@$(( $(date +%s) - age ))" "/tmp/vault-${sid}/last-actualize"
  fi
  jq -nc --arg sid "$sid" --arg t "$trig" \
     '{session_id:$sid, cwd:"/x", hook_event_name:"PreCompact", trigger:$t}' \
     | VAULT_STATE_DIR="$pc_state" "$pc_script_dir/prompt-actualize.sh" >/dev/null 2>&1
  echo "$?"
}

# --- it never blocks, whatever the state ------------------------------------
ec=$(_precompact "pc-auto" "auto" 5000)
assert_eq "0" "$ec" "precompact: never blocks (stale sentinel)"
ec=$(_precompact "pc-fresh" "auto" 10)
assert_eq "0" "$ec" "precompact: never blocks (fresh sentinel)"
ec=$(_precompact "pc-none" "manual" "")
assert_eq "0" "$ec" "precompact: never blocks (no sentinel)"

# --- but it always leaves evidence that it fired -----------------------------
log="$pc_state/hook-events.log"
[[ -f "$log" ]] && got=recorded || got=missing
assert_eq "recorded" "$got" "precompact: firing is recorded in a durable log"
n=$(wc -l < "$log")
assert_eq "3" "$n" "precompact: every firing is recorded, not just the stale case"

# --- the row distinguishes auto from manual, and says what it did ------------
assert_contains "auto" "$(awk -F'\t' 'NR==1{print $4}' "$log")" "precompact: the trigger (auto/manual) is recorded"
assert_contains "sentinel-invalidated" "$(awk -F'\t' 'NR==1{print $5}' "$log")" "precompact: a stale sentinel is invalidated and says so"
assert_contains "fresh-sentinel-kept" "$(awk -F'\t' 'NR==2{print $5}' "$log")" "precompact: a fresh sentinel is kept and says so"
assert_contains "manual" "$(awk -F'\t' 'NR==3{print $4}' "$log")" "precompact: a manual /compact is distinguishable from an auto one"

# --- the sentinel behaviour itself still holds -------------------------------
[[ -f "/tmp/vault-pc-auto/last-actualize" ]] && got=kept || got=invalidated
assert_eq "invalidated" "$got" "precompact: a stale sentinel is actually removed"
[[ -f "/tmp/vault-pc-fresh/last-actualize" ]] && got=kept || got=invalidated
assert_eq "kept" "$got" "precompact: a fresh sentinel is left alone"

rm -rf "$pc_state" /tmp/vault-pc-auto /tmp/vault-pc-fresh /tmp/vault-pc-none
