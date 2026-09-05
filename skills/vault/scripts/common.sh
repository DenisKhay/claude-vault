#!/usr/bin/env bash
# common.sh — sourced by vault hook scripts. Provides shared helpers.
# Do not execute directly.

# read_hook_input
# Reads stdin (Claude Code hook JSON), populates these variables:
#   HOOK_SESSION_ID, HOOK_CWD, HOOK_EVENT, HOOK_STOP_HOOK_ACTIVE,
#   HOOK_TRIGGER, HOOK_TOOL_NAME, HOOK_INPUT_RAW
# Missing fields become empty strings. Never errors out — empty input → empty fields.
read_hook_input() {
  HOOK_INPUT_RAW=$(cat || true)
  if [[ -z "$HOOK_INPUT_RAW" ]]; then
    HOOK_SESSION_ID=""
    HOOK_CWD="$PWD"
    HOOK_EVENT=""
    HOOK_STOP_HOOK_ACTIVE="false"
    HOOK_TRIGGER=""
    HOOK_TOOL_NAME=""
    return 0
  fi
  HOOK_SESSION_ID=$(echo "$HOOK_INPUT_RAW" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  HOOK_CWD=$(echo "$HOOK_INPUT_RAW" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  HOOK_EVENT=$(echo "$HOOK_INPUT_RAW" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
  HOOK_STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT_RAW" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  HOOK_TRIGGER=$(echo "$HOOK_INPUT_RAW" | jq -r '.trigger // ""' 2>/dev/null || echo "")
  HOOK_TOOL_NAME=$(echo "$HOOK_INPUT_RAW" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
  [[ -z "$HOOK_CWD" ]] && HOOK_CWD="$PWD"
  # Record cwd marker so the skill can find this session dir via cwd match.
  if [[ -n "$HOOK_SESSION_ID" ]]; then
    local d="/tmp/vault-${HOOK_SESSION_ID}"
    mkdir -p "$d" 2>/dev/null || true
    echo "$HOOK_CWD" > "$d/cwd" 2>/dev/null || true
  fi
}

# state_dir <session_id>
# Echoes the per-session state directory and creates it if needed.
state_dir() {
  local sid="${1:-default}"
  local d="/tmp/vault-${sid}"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

# cwd_pause_flag <cwd>
# Echoes the cwd-keyed pause flag path. Pause is keyed by CWD, not session id:
# the /vault-pause slash command runs in a Bash env where CLAUDE_SESSION_ID is
# UNSET (audit 2026-08-30: the old session-keyed flag landed in vault-default/
# while hooks checked the real uuid — pause had never actually engaged, ever).
# Hooks DO know their cwd (stdin JSON), and the command knows $PWD — same key.
cwd_pause_flag() {
  local cwd="${1:-$PWD}"
  local h
  h=$(printf '%s' "$cwd" | md5sum 2>/dev/null | cut -c1-12)
  echo "/tmp/vault-pause-${h:-nohash}"
}

# is_paused <session_id> [cwd]
# Exits 0 if a pause flag exists for this session OR its cwd, 1 otherwise.
is_paused() {
  local sid="${1:-default}"
  local cwd="${2:-${HOOK_CWD:-$PWD}}"
  [[ -f "/tmp/vault-${sid}/paused" ]] && return 0
  [[ -f "$(cwd_pause_flag "$cwd")" ]]
}

# vault_git_lock [vault_root]
# Echoes the git lock path for a vault root. Keyed by ROOT, not global: a single
# /tmp/vault-git.lock made every vault serialize against every other one, so a
# fixture vault in /tmp could block a real sweep on ~/Vaults for the full 30s
# timeout (observed in the test suite 2026-08-30 — sync tests failed with "could
# not take the vault git lock" because an unrelated fixture held it).
vault_git_lock() {
  local root="${1:-$(vault_root)}"
  local h
  h=$(printf '%s' "$root" | md5sum 2>/dev/null | cut -c1-12)
  echo "/tmp/vault-git-${h:-default}.lock"
}

# Vault root, defaulting to ~/Vaults
vault_root() {
  echo "${VAULT_ROOT:-$HOME/Vaults}"
}

# Durable (non-tmpfs) state: rejected.log, hook-events.log, spool-drain/. Overridable so
# the test suite never writes into the real audit trail.
vault_state_dir() {
  echo "${VAULT_STATE_DIR:-$HOME/.claude/vault-state}"
}

# Spool of dead-session pointer records (spool-tail.sh writes, spool-drain.sh consumes).
spool_dir() {
  echo "${VAULT_SPOOL_DIR:-$HOME/.claude/vault-spool}"
}

# is_spool_worker
# Exits 0 inside a headless spool worker (spool-drain.sh sets VAULT_SPOOL_WORKER=1). A
# worker mines a DEAD session's transcript; its own hooks must never spool it, re-prompt it
# to sweep itself, or hand it the other pending records — that is the recursion this guard
# exists to cut.
is_spool_worker() {
  [[ "${VAULT_SPOOL_WORKER:-}" == "1" ]]
}
