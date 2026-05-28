#!/usr/bin/env bash
# prompt-actualize.sh — Stop + PreCompact hook target.
# Stop: blocks ONCE per session (first-actualize-only). After any actualize, all future Stops pass.
# PreCompact: freshness-based (may compact multiple times; re-actualize if stale).
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
    # Freshness-based: may compact multiple times per session.
    if [[ -f "$actualize_file" ]]; then
      freshness="${VAULT_ACTUALIZE_FRESHNESS_SECONDS:-1800}"
      age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
      if (( age < freshness )); then
        exit 0
      fi
    fi
    echo "Vault sync (pre-compact): invoke the vault skill in actualize mode. After actualize, run: touch $actualize_file" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
