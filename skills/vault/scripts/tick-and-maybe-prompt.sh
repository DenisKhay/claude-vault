#!/usr/bin/env bash
# tick-and-maybe-prompt.sh — PostToolUse hook target.
# Counts mutating tool calls per session. Every Nth call (default 40) surfaces a
# NON-BLOCKING advisory nudge (via additionalContext) to optionally actualize —
# unless an actualize happened recently. Pause-aware. Never blocks or crashes the
# session; the Stop hook still guarantees one capture sweep at session end.

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

read_hook_input

if is_paused "$HOOK_SESSION_ID"; then
  exit 0
fi

threshold="${VAULT_TICK_THRESHOLD:-40}"
freshness="${VAULT_TICK_FRESHNESS_SECONDS:-300}"

dir=$(state_dir "$HOOK_SESSION_ID")
counter_file="$dir/tick"
actualize_file="$dir/last-actualize"

# Increment counter.
count=0
if [[ -f "$counter_file" ]]; then
  count=$(cat "$counter_file" 2>/dev/null || echo 0)
fi
count=$((count + 1))
echo "$count" > "$counter_file"

# If actualize timestamp is recent, do nothing.
if [[ -f "$actualize_file" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
  if (( age < freshness )); then
    exit 0
  fi
fi

# Threshold check — NON-BLOCKING advisory (M1). Mid-session capture is no longer
# forced (that was pure friction); it surfaces a gentle, optional nudge via
# additionalContext and never interrupts the flow. The Stop hook still guarantees a
# once-per-session capture sweep at session end.
if (( count >= threshold )); then
  echo "0" > "$counter_file"
  msg="Vault (optional): $count mutating tool calls since last sync. If durable, non-obvious knowledge accumulated this session, you may invoke the vault skill in actualize mode now. Not required — capture also runs at session end."
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}'
  fi
  exit 0
fi

exit 0
