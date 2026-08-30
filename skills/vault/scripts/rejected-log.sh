#!/usr/bin/env bash
# rejected-log.sh — append one salience-gate rejection to a DURABLE log.
#
# SKILL.md calls the rejected-candidate log "the only way the gate's false-negative
# rate is ever measurable". It was being written to /tmp/vault-<sid>/rejected.log,
# and /tmp is tmpfs here — so the instrument was wiped at every reboot and the
# measurement could never span more than one uptime. The 2026-08-30 re-audit tried
# to compute a false-negative rate from it and found 4 surviving files across 38
# session dirs, with no way to know what the denominator should have been.
#
# One append-only file under ~/.claude survives reboots and pools every session's
# decisions, which is what makes a rate computable at all.
#
# Usage: rejected-log.sh "<candidate, one line>" "<why it was rejected>" [session_id]

set -uo pipefail

LOG_DIR="${VAULT_STATE_DIR:-$HOME/.claude/vault-state}"
LOG="$LOG_DIR/rejected.log"

candidate="${1:-}"
reason="${2:-}"
sid="${3:-${CLAUDE_SESSION_ID:-unknown}}"

if [[ -z "$candidate" || -z "$reason" ]]; then
  echo "rejected-log.sh: need a candidate and a reason" >&2
  exit 2
fi

# Tabs are the field separator, so strip them (and newlines) from the payload —
# a single mangled row would break every later parse of the whole file.
sanitize() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/  */ /g'; }

mkdir -p "$LOG_DIR" 2>/dev/null || { echo "rejected-log.sh: cannot create $LOG_DIR" >&2; exit 1; }
printf '%s\t%s\t%s\t%s\n' \
  "$(date -Is)" "$sid" "$(sanitize "$candidate")" "$(sanitize "$reason")" >> "$LOG" \
  || { echo "rejected-log.sh: cannot write $LOG" >&2; exit 1; }

echo "logged (total $(wc -l < "$LOG" 2>/dev/null || echo '?') rejections in $LOG)"
