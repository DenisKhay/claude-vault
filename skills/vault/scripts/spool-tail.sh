#!/usr/bin/env bash
# spool-tail.sh — SessionEnd hook target. NON-LLM crash/abandon insurance.
#
# SessionEnd cannot prompt a model, and Stop never fires on interrupt/kill/close —
# so everything since the last fresh sweep used to die with the process (the
# audit's loss surface #2). This spools a pointer record instead: if the session
# ends with a MISSING or STALE actualize sentinel, write one small JSON file to
# ~/.claude/vault-spool/. The next SessionStart injection lists pending spool
# records so a live session can mine the dead session's transcript while it
# still exists (transcripts rot on the host's cleanupPeriodDays timer).
#
# Never blocks, never errors out, budget well under the host's hook timeout.

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

read_hook_input

if is_paused "$HOOK_SESSION_ID"; then
  exit 0
fi

# A spool worker mines a dead session; its own tail is that work, never a record.
is_spool_worker && exit 0

[[ -z "$HOOK_SESSION_ID" ]] && exit 0

actualize_file="/tmp/vault-${HOOK_SESSION_ID}/last-actualize"
# Deliberately NOT the Stop re-arm's VAULT_ACTUALIZE_FRESHNESS_SECONDS. Sharing
# that constant made the spool decline to insure exactly the window the re-arm
# leaves open: a session killed 29 minutes after its last sweep got no re-arm (it
# never reached a Stop) AND no spool record, which is the ordinary crash case
# this insurance exists for. A pointer file is ~200 bytes; the only tail not
# worth one is a sweep that just finished.
min_age="${VAULT_SPOOL_MIN_AGE_SECONDS:-120}"

# A sweep that JUST finished (fresh sentinel — a /vault-update, or the legacy in-session nag) leaves
# nothing to insure: skip, and drop any live record the Stop hook wrote, so no worker is spawned for
# an already-captured tail.
if [[ -f "$actualize_file" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
  if (( age < min_age )); then
    rm -f "$(spool_dir)/${HOOK_SESSION_ID}.json" 2>/dev/null
    exit 0
  fi
fi

transcript=$(echo "$HOOK_INPUT_RAW" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
# A session that never produced a transcript (or a sub-second one) has no tail worth mining.
[[ -n "$transcript" && ! -f "$transcript" ]] && exit 0

spool="$(spool_dir)"
# Shared writer: a Stop hook may already have written this record as live crash insurance; SessionEnd
# marks it ended and keeps whatever drain_attempts it carries.
spool_write_record "$HOOK_SESSION_ID" "$HOOK_CWD" "$transcript" false ""

# The record is insurance; the drain is the actual capture. Detached, returns at once.
# With the miner running, launching here too would mean two schedulers racing for the same record — it
# picks this up within one poll instead. Without a miner this is still the only thing that mines.
if [[ -f "$spool/${HOOK_SESSION_ID}.json" ]] && ! miner_alive; then
  bash "$self_dir/spool-drain.sh" --launch "$spool/${HOOK_SESSION_ID}.json"
fi
exit 0
