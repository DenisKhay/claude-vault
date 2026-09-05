#!/usr/bin/env bash
# spool-drain.sh — turns a spool record into a headless capture worker.
#
# SessionEnd cannot prompt a model, so spool-tail.sh only wrote a pointer and every
# SessionStart nagged "mine it when convenient". Five records piled up in five days
# (2026-09-01..05); a live session then spent ~25 minutes and four subagents draining them,
# and two of the five tails were empty — the sweep's own closing output. SessionEnd cannot
# prompt a model, but it can spawn one. This script does what the nag asked for.
#
#   --launch <spool.json>   detach and return at once (hook-safe); dry-run runs inline
#   --run    <spool.json>   render the digest, measure the unswept tail, then either
#                           delete an empty record or spawn `claude -p` as a spool worker
#
# Env: VAULT_SPOOL_DRAIN_MIN_TAIL_BYTES (4096)  below this the record is deleted, not mined
#      VAULT_SPOOL_DRAIN_MAX_ATTEMPTS (3)       then the record is left for a live session
#      VAULT_SPOOL_DRAIN_MODEL (sonnet)         the worker's model
#      VAULT_SPOOL_DRAIN_DRY_RUN=1              write the command to the log, run nothing
#      VAULT_SPOOL_AUTODRAIN=0                  disable launching entirely
# Every decision lands in <state>/hook-events.log; a worker's output in <state>/spool-drain/<sid>.log.

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

mode="${1:-}"
spool_file="${2:-}"
[[ -n "$spool_file" && -f "$spool_file" ]] || exit 0

state="$(vault_state_dir)/spool-drain"
events="$(vault_state_dir)/hook-events.log"
mkdir -p "$state" 2>/dev/null || exit 0

sid=$(jq -r '.session_id // ""' "$spool_file" 2>/dev/null)
[[ -n "$sid" ]] || exit 0

log_event() {   # decision, detail
  printf '%s\t%s\tSpoolDrain\t%s\t%s\n' "$(date -Is)" "$sid" "$1" "${2:-}" >> "$events" 2>/dev/null || true
}

dry_run=0
[[ "${VAULT_SPOOL_DRAIN_DRY_RUN:-}" == "1" ]] && dry_run=1

case "$mode" in
  --launch)
    [[ "${VAULT_SPOOL_AUTODRAIN:-1}" == "0" ]] && exit 0
    if (( dry_run )); then
      bash "$0" --run "$spool_file" >/dev/null 2>&1
    elif command -v setsid >/dev/null 2>&1; then
      setsid -f bash "$0" --run "$spool_file" >/dev/null 2>&1 </dev/null
    else
      nohup bash "$0" --run "$spool_file" >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null || true
    fi
    exit 0
    ;;
  --run) ;;
  *) exit 0 ;;
esac

cwd=$(jq -r '.cwd // ""' "$spool_file" 2>/dev/null)
transcript=$(jq -r '.transcript_path // ""' "$spool_file" 2>/dev/null)
ended_at=$(jq -r '.ended_at // "?"' "$spool_file" 2>/dev/null)
attempts=$(jq -r '.drain_attempts // 0' "$spool_file" 2>/dev/null)
max_attempts="${VAULT_SPOOL_DRAIN_MAX_ATTEMPTS:-3}"
floor="${VAULT_SPOOL_DRAIN_MIN_TAIL_BYTES:-4096}"
model="${VAULT_SPOOL_DRAIN_MODEL:-sonnet}"

if [[ -z "$transcript" || ! -f "$transcript" ]]; then
  rm -f "$spool_file" 2>/dev/null
  log_event transcript-gone "path=${transcript:-none}"
  exit 0
fi

if (( attempts >= max_attempts )); then
  log_event max-attempts "attempts=$attempts — left for a live session"
  exit 0
fi

pidfile="$state/$sid.pid"
if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  log_event already-running "pid=$(cat "$pidfile")"
  exit 0
fi

digest="$state/$sid.digest.md"
measure=$(python3 "$self_dir/transcript-digest.py" "$transcript" "$digest" 2>/dev/null) || measure=""
tail_bytes=$(sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p' <<<"$measure")
boundaries=$(sed -n 's/.*boundaries=\([0-9]*\).*/\1/p' <<<"$measure")
if [[ -z "$tail_bytes" ]]; then
  log_event digest-failed "transcript=$transcript"
  exit 0
fi

if (( tail_bytes < floor )); then
  rm -f "$spool_file" "$digest" 2>/dev/null
  log_event tail-empty "tail=${tail_bytes}B floor=${floor}B boundaries=$boundaries"
  exit 0
fi

attempts=$(( attempts + 1 ))
tmp=$(mktemp "$state/.spool.XXXXXX") && jq --argjson n "$attempts" '.drain_attempts = $n' "$spool_file" > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$spool_file"

prompt=$(cat <<PROMPT
You are a vault SPOOL WORKER: a headless session mining the unswept tail of a DEAD Claude Code session so its knowledge is not lost. That session (id $sid, cwd $cwd) ended $ended_at without a final capture sweep. You are not that session; you have none of its context beyond the digest below.

1. Load the vault skill with the Skill tool (skill "vault:vault", args "actualize spool-worker") and follow its actualize algorithm in the spool-worker variant. Its scripts live in $self_dir (match.sh, rejected-log.sh, sync.sh, index-regen.py, registry-lint.py) — use that path; do not search the filesystem for them.
2. Digest of the dead session: $digest — read it in chunks. It has $boundaries sweep boundary line(s) of the form "#### ===== VAULT SWEEP BOUNDARY"; everything ABOVE the last one was already captured by that session. Mine ONLY the part after the last boundary (${tail_bytes} bytes of text). Read earlier parts solely for context the tail refers to.
3. Apply the salience gate to every candidate; log each rejection with rejected-log.sh; dispatch ONE capture subagent (model sonnet) with the full candidate brief; verify its machine-countable return line and zero removed lines; then sync with sync.sh passing exactly the reported paths.
4. On success (synced, or a genuine no-delta), delete the spool record: rm -f "$spool_file". On any failure — capture agent error, DIVERGED or REFUSING from sync.sh — leave the record in place and say why.
Never mine other spool records, never touch files outside the vault, never re-add ssh keys or resolve git divergence.
Finish with exactly one line: "spool-worker $sid: <N> updated, <M> new (synced)" or "spool-worker $sid: no knowledge delta" or "spool-worker $sid: FAILED — <reason>".
PROMPT
)

claude_bin=$(command -v claude 2>/dev/null || true)
[[ -z "$claude_bin" && -x "$HOME/.local/bin/claude" ]] && claude_bin="$HOME/.local/bin/claude"

# The prompt goes over STDIN, never argv: --allowedTools is variadic and swallowed a
# positional prompt as one more tool name — the first real worker died in three seconds
# with "Input must be provided either through stdin or as a prompt argument".
cmd=(env VAULT_SPOOL_WORKER=1 "${claude_bin:-claude}" -p --model "$model" --max-turns 60 --output-format text
     --allowedTools Bash Read Write Edit Glob Grep Agent Skill mcp__plugin_vault_vault-search__vault_search)

log_event spawn "attempt=$attempts tail=${tail_bytes}B boundaries=$boundaries model=$model dry_run=$dry_run"

if (( dry_run )); then
  { printf '%q ' "${cmd[@]}"; printf '\n--- stdin prompt ---\n%s\n' "$prompt"; } > "$state/$sid.log"
  exit 0
fi

if [[ -z "$claude_bin" ]]; then
  log_event no-claude-binary "PATH=$PATH"
  exit 0
fi

workdir="$cwd"
[[ -d "$workdir" ]] || workdir="$HOME"
cd "$workdir" || exit 0
echo $$ > "$pidfile"
_run() { if command -v timeout >/dev/null 2>&1; then timeout 1800 "$@"; else "$@"; fi; }
printf '%s' "$prompt" | _run "${cmd[@]}" > "$state/$sid.log" 2>&1
code=$?
rm -f "$pidfile" 2>/dev/null
if [[ -f "$spool_file" ]]; then
  log_event worker-exit "code=$code record-kept attempt=$attempts"
else
  log_event worker-exit "code=$code record-cleared attempt=$attempts"
fi
exit 0
