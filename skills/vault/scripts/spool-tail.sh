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

[[ -z "$HOOK_SESSION_ID" ]] && exit 0

actualize_file="/tmp/vault-${HOOK_SESSION_ID}/last-actualize"
freshness="${VAULT_ACTUALIZE_FRESHNESS_SECONDS:-1800}"

if [[ -f "$actualize_file" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
  (( age < freshness )) && exit 0
fi

transcript=$(echo "$HOOK_INPUT_RAW" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
# A session that never produced a transcript (or a sub-second one) has no tail worth mining.
[[ -n "$transcript" && ! -f "$transcript" ]] && exit 0

spool="$HOME/.claude/vault-spool"
mkdir -p "$spool" 2>/dev/null || exit 0
jq -n --arg sid "$HOOK_SESSION_ID" --arg cwd "$HOOK_CWD" \
      --arg tp "$transcript" --arg ts "$(date -Is)" \
      '{session_id:$sid, cwd:$cwd, transcript_path:$tp, ended_at:$ts}' \
      > "$spool/${HOOK_SESSION_ID}.json" 2>/dev/null || true
exit 0
