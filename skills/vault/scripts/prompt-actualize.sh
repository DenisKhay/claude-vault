#!/usr/bin/env bash
# prompt-actualize.sh — Stop + PreCompact hook target.
# Stop: blocks ONCE per session (first-actualize-only). After any actualize, all future Stops pass.
# PreCompact: NEVER blocks. If the vault is stale, it invalidates the actualize
#   sentinel so the next Stop re-captures. Blocking compaction wedges sessions
#   (a manual /compact dead-ends; auto-compact can't be user-retried), and the
#   Stop path self-resolves cleanly while staying wedge-safe via stop_hook_active.
# Pause: silent allow.
# Error: silent allow (never break the user).

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

read_hook_input

if is_paused "$HOOK_SESSION_ID"; then
  exit 0
fi

actualize_file="/tmp/vault-${HOOK_SESSION_ID}/last-actualize"

case "$HOOK_EVENT" in
  Stop)
    if [[ "$HOOK_STOP_HOOK_ACTIVE" == "true" ]]; then
      exit 0
    fi
    # First-actualize-only: if sentinel EXISTS (any age), allow exit.
    if [[ -f "$actualize_file" ]]; then
      exit 0
    fi
    echo "Vault sync: invoke the vault skill in actualize mode. After actualize, run: touch $actualize_file" >&2
    exit 2
    ;;
  PreCompact)
    # Never block — let compaction always proceed. If the vault is stale,
    # invalidate the sentinel so the next Stop forces a fresh capture
    # (post-compaction). The Stop path feeds back to the model and self-resolves.
    if [[ -f "$actualize_file" ]]; then
      freshness="${VAULT_ACTUALIZE_FRESHNESS_SECONDS:-1800}"
      age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
      if (( age < freshness )); then
        exit 0
      fi
      rm -f "$actualize_file" 2>/dev/null
      echo "Vault sync (pre-compact): vault stale — invalidated so the next stop re-captures. Compacting." >&2
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
