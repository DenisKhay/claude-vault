#!/usr/bin/env bash
# prompt-actualize.sh — Stop + PreCompact hook target.
# Stop: blocks when the actualize sentinel is MISSING or STALE (older than
#   VAULT_ACTUALIZE_FRESHNESS_SECONDS, default 1800). A fresh sentinel passes.
#   The 2026-08-30 audit proved the old first-actualize-only gate swept once at
#   the knowledge-poorest moment (end of turn 1) and then never again — session
#   tails were the vault's dominant confirmed loss window (a real incident is
#   permanently lost that way). Age-based re-arm bounds the un-swept window to
#   the freshness interval.
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
    freshness="${VAULT_ACTUALIZE_FRESHNESS_SECONDS:-1800}"
    if [[ -f "$actualize_file" ]]; then
      age=$(( $(date +%s) - $(stat -c %Y "$actualize_file" 2>/dev/null || echo 0) ))
      if (( age < freshness )); then
        exit 0
      fi
      echo "Vault sync: last actualize was ${age}s ago — sweep the DELTA since then (new findings only; if nothing new, touch the sentinel and say so). After actualize, run: touch $actualize_file" >&2
      exit 2
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
