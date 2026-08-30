#!/usr/bin/env bash
# inject-context.sh — SessionStart hook target.
# Reads hook JSON on stdin, matches the cwd against the registry, and prints
# either a HIT context block (one or more matched subgraphs) or a MISS
# enrollment-needed block to stdout. Silent on paused sessions. Always exits 0.

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

read_hook_input

paused_flag=""
if is_paused "$HOOK_SESSION_ID"; then
  paused_flag="$(cwd_pause_flag "${HOOK_CWD:-$PWD}")"
  [[ -f "$paused_flag" ]] || paused_flag="/tmp/vault-${HOOK_SESSION_ID}/paused"
fi

# Emit the context block INVISIBLY: JSON additionalContext + suppressOutput — the model gets the
# block, the UI renders nothing (the old plain-stdout form printed a wall at every session start).
#
# The block goes to every renderer over STDIN, never argv: a single argv string is capped at
# MAX_ARG_STRLEN (128 KiB), and the old `jq --arg c "$block"` form hit that ceiling for real —
# one subgraph's Entry-nodes list had grown to 110 KiB, execve returned E2BIG, and the hook died
# emitting NOTHING, so sessions silently started with no vault at all. `printf` is a bash builtin,
# so the pipe below never execve's the block.
#
# Three renderers, tried in order, each falling through only on failure or empty output — the one
# thing this function may never do is print nothing: python3 (size-guarded JSON, the normal path),
# jq (JSON), plain stdout (visible, but never silently dropped). The jq and stdout fallbacks get a
# crude byte guard of their own: unguarded, a big block sails past the host's 10,000-char ceiling
# and is spilled to a file with only a ~2KB preview injected — the silent-delivery-loss era the
# audit counted 45 historical spill files from.
emit_context() {
  local block="$1" out=""
  if command -v python3 >/dev/null 2>&1; then
    out=$(printf '%s' "$block" | python3 "$self_dir/emit-context.py" 2>/dev/null) || out=""
  fi
  if [[ -z "$out" ]]; then
    if (( ${#block} > 9000 )); then
      block="${block:0:8800}
(…block truncated: emit-context.py unavailable — open the Entry file(s) above or use vault_search.)"
    fi
    if command -v jq >/dev/null 2>&1; then
      out=$(printf '%s' "$block" | jq -Rsc '{suppressOutput: true, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}' 2>/dev/null) || out=""
    fi
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$block"
  fi
}

vroot=$(vault_root)

# Kick a background fast-forward pull so a multi-machine vault converges without
# ever taxing SessionStart latency (fail-open: network down → next session catches
# up). Divergence is NEVER auto-merged — a marker is written and surfaced loudly
# below; sync.sh owns the write-side flow.
if [[ -d "$vroot/.git" ]] && command -v git >/dev/null 2>&1 && command -v flock >/dev/null 2>&1; then
  (
    flock -n 9 || exit 0
    # BatchMode/no-prompt + a hard timeout: this runs behind the same lock every
    # sync.sh takes, so one pull hanging on a credential prompt would wedge every
    # sweep on the machine for as long as it hangs.
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes -oConnectTimeout=10}"
    _git() { if command -v timeout >/dev/null 2>&1; then timeout 60 git "$@"; else git "$@"; fi; }
    if ! _git -C "$vroot" pull --ff-only --quiet 2>/dev/null; then
      # A failed pull is not evidence of divergence — an unreachable remote, a
      # dead network or an expired credential fails the same way. Claiming it
      # writes a marker that then gets committed, so every fresh clone boots into
      # a permanent false alarm. Only claim divergence against a LIVE remote.
      if _git -C "$vroot" ls-remote --exit-code origin >/dev/null 2>&1; then
        if ! git -C "$vroot" merge-base --is-ancestor "$(git -C "$vroot" rev-parse '@{u}' 2>/dev/null || echo HEAD)" HEAD 2>/dev/null; then
          touch "$vroot/.sync-diverged" 2>/dev/null
        fi
      fi
    else
      rm -f "$vroot/.sync-diverged" 2>/dev/null
    fi
  ) 9>"$(vault_git_lock "$vroot")" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# Warnings assembled for the context block: sync divergence + unswept session tails.
extra_notices() {
  if [[ -f "$vroot/.sync-diverged" ]]; then
    printf '\n⚠ VAULT SYNC DIVERGED: local and remote history do not fast-forward. Do NOT auto-merge — tell the user; resolve by hand (see the vault skill), then delete %s/.sync-diverged.\n' "$vroot"
  fi
  # The listing is capped, but NEVER silently. A truncated list with no count is
  # the same silent-omission bug the entry-bullet budget was fixed for, and here
  # the dropped rows are unswept sessions nobody would ever look for again.
  local spool="$HOME/.claude/vault-spool" shown=0 total=0 f
  if [[ -d "$spool" ]]; then
    for f in "$spool"/*.json; do
      [[ -e "$f" ]] || break
      local tp
      tp=$(jq -r '.transcript_path // ""' "$f" 2>/dev/null)
      if [[ -n "$tp" && ! -f "$tp" ]]; then rm -f "$f" 2>/dev/null; continue; fi
      if (( total == 0 )); then
        printf '\n⚠ UNSWEPT SESSION TAILS pending (ended without a fresh capture sweep):\n'
      fi
      total=$(( total + 1 ))
      if (( total <= 5 )); then
        shown=$(( shown + 1 ))
        printf '  - %s (cwd %s, ended %s)\n' "${tp:-unknown-transcript}" "$(jq -r '.cwd // "?"' "$f" 2>/dev/null)" "$(jq -r '.ended_at // "?"' "$f" 2>/dev/null)"
      fi
    done
    if (( total > shown )); then
      printf '  … and %d more pending, not listed above — see %s/\n' "$(( total - shown ))" "$spool"
    fi
    if (( total > 0 )); then
      printf 'When convenient: mine each transcript for vault candidates (actualize rules apply), then delete its spool file from %s/.\n' "$spool"
    fi
  fi
}

# A pause used to exit here in silence, which made it the one control in the
# system whose failure mode is invisible in BOTH directions: nobody could tell it
# was on, and nobody could tell it had never engaged (it hadn't, for months —
# the flag was keyed on an unset variable until 1.1.0). It is deliberately NOT
# auto-expiring: lapsing a pause would resume capture inside exactly the
# sensitive work it was turned on for, and auto-push would put that on a remote
# within seconds. The safe design is a pause that persists and cannot hide.
if [[ -n "$paused_flag" ]]; then
  since=""; age_note=""
  if [[ -f "$paused_flag" ]]; then
    set_at=$(stat -c %Y "$paused_flag" 2>/dev/null || echo 0)
    if (( set_at > 0 )); then
      hours=$(( ( $(date +%s) - set_at ) / 3600 ))
      since=" (paused $(date -d "@$set_at" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
      if (( hours >= 24 )); then
        since+=", $(( hours / 24 ))d $(( hours % 24 ))h ago)"
        age_note="
This pause is over a day old. If it outlived the work it was for, everything learned
in this workspace since then was never captured — resume and sweep while the
transcripts still exist."
      else
        since+=", ${hours}h ago)"
      fi
    fi
  fi
  emit_context "## Vault context

⏸ VAULT PAUSED for this workspace${since}.

No context was injected, no capture sweep will run, and no crash-recovery pointer
will be spooled if this session dies. Knowledge earned here goes nowhere until the
pause is lifted with \`/vault-resume\`.

  cwd:  $HOOK_CWD
  flag: $paused_flag${age_note}"
  exit 0
fi

mapfile -t match_ids < <("$self_dir/match.sh" "$HOOK_CWD" 2>/dev/null)
first="${match_ids[0]:-MISS}"

if [[ "$first" == "MISS" || -z "$first" ]]; then
  emit_context "$(cat <<EOF
## Vault context

NO SUBGRAPH MATCHED.
  cwd: $HOOK_CWD
  session: $HOOK_SESSION_ID

If knowledge work happens this session, you MUST invoke the vault skill in 'enroll' mode before capturing anything. Ask the user where this repo's knowledge should live (new top-level subgraph, under an existing namespace, attached to an existing subgraph, or skip).

Cross-cutting facts may still exist: you can search the whole vault with the \`vault_search\` MCP tool (keyword + semantic when embeddings are up) even with no subgraph matched.
$(extra_notices)
EOF
)"
  exit 0
fi

# HIT: for each matched subgraph, look up its entry _index.md and extract the
# "Entry nodes" bullet list (the next-best curated jump-off points).
emit_entry_nodes() {
  local sid="$1"
  local entry_path
  entry_path=$(REGISTRY="$vroot/_registry.yaml" SUBGRAPH_ID="$sid" python3 - <<'PY'
import os, sys, yaml
try:
    with open(os.environ["REGISTRY"]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
sid = os.environ["SUBGRAPH_ID"]
for sg in data.get("subgraphs") or []:
    if sg.get("id") == sid:
        print(sg.get("entry") or ""); break
PY
)
  printf '### %s\n' "$sid"
  if [[ -n "$entry_path" ]]; then
    # Absolute, because the budget below may cut the bullet list and point the reader here — a
    # vault-relative path would make them guess the root before they could open it.
    printf 'Entry: %s\n' "$vroot/$entry_path"
  fi
  if [[ -n "$entry_path" && -f "$vroot/$entry_path" ]]; then
    awk '
      /^## Entry nodes/ { in_block=1; next }
      /^## / && in_block { in_block=0 }
      in_block && /^- / { print }
    ' "$vroot/$entry_path"
  else
    printf '(no _index.md / Entry nodes list — consider curating one)\n'
  fi
  printf '\n'
}

ctx=$(
  printf '## Vault context\n\n'
  if (( ${#match_ids[@]} > 1 )); then
    printf 'Matched subgraphs: %s\n\n' "${match_ids[*]}"
  else
    printf 'Matched subgraph: %s\n\n' "${match_ids[0]}"
  fi
  for sid in "${match_ids[@]}"; do
    emit_entry_nodes "$sid"
  done
  cat <<EOF
Retrieval: read individual entry nodes lazily as the task touches them, OR use the \`vault_search\` MCP tool for keyword + (when embeddings are up) semantic search across all matched subgraphs (ranked, decay-aware). Prefer vault_search when you don't already know which node holds the answer.

Vault skill is loaded. A capture sweep fires on Stop whenever the last sweep is older than 30 minutes. Capture only durable, non-obvious knowledge — skip anything re-derivable from a single source file.
EOF
  extra_notices
)
emit_context "$ctx"
exit 0
