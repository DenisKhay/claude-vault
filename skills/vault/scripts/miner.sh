#!/usr/bin/env bash
# miner.sh — the vault miner daemon (1.8.0). Runs as a systemd user unit.
#
# WHY a daemon and not a hook. Hook paths PIN at session start, so a hook-side capture trigger reaches a
# seat only when that seat restarts — days later for a pantheon trunk. That pinning is exactly what made
# capture depend on launch time: the fleet relaunched onto 1.7.0 (silent Stop) and every live session
# went uncaptured, 5 of 9 never swept at all. A unit changes behaviour for every session after ONE
# restart, and re-execs itself when a newer plugin version lands so even that restart is automatic.
#
# Its own failure mode — not running — is the one thing a hook cannot have, so it is made LOUD instead of
# silent: a heartbeat in miner.json, a SessionStart warning when that heartbeat goes stale, Restart=always
# in the unit. Nothing is lost while it is down: transcripts live 180 days and the records simply wait.
#
#   miner.sh            run the loop in the foreground (the unit's ExecStart)
#   miner.sh --once     one pass, then exit (tests, and a manual catch-up)
#
# Env: VAULT_MINER_POLL_SECONDS (60)            seconds between passes
#      VAULT_MINER_LIVE_FLOOR_BYTES (32768)     unmined text before a RUNNING session is worth a worker;
#                                               measured: >=32KB tails produced nodes in 4/4 runs, <16KB in 7/22
#      VAULT_SPOOL_DRAIN_MIN_TAIL_BYTES (4096)  the ended/crashed floor (unchanged from 1.6.0)
#      VAULT_MINER_BACKOFF_MIN/MAX (300/3600)   API-error backoff, doubling
#      VAULT_MINER_DISABLE=1                    exit at once (kill switch without touching the unit)

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

poll="${VAULT_MINER_POLL_SECONDS:-60}"
live_floor="${VAULT_MINER_LIVE_FLOOR_BYTES:-32768}"
dead_floor="${VAULT_SPOOL_DRAIN_MIN_TAIL_BYTES:-4096}"
backoff_min="${VAULT_MINER_BACKOFF_MIN:-300}"
backoff_max="${VAULT_MINER_BACKOFF_MAX:-3600}"

state="$(vault_state_dir)"
mkdir -p "$state/spool-drain" 2>/dev/null
miner_json="$state/miner.json"
lock="$state/miner.lock"
events="$state/hook-events.log"
backoff=0
backoff_until=0

log_event() {   # decision, detail
  printf '%s\t%s\tMiner\t%s\t%s\n' "$(date -Is)" "${1:-}" "${2:-}" "${3:-}" >> "$events" 2>/dev/null || true
}

# Single writer (this daemon), read by `vault watch` and by inject-context.sh — written atomically so a
# reader never catches a half-file.
write_state() {   # running_sid, running_mode
  local tmp
  tmp=$(mktemp "$state/.miner.XXXXXX" 2>/dev/null) || return 0
  jq -n --arg pid "$$" --arg beat "$(date -Is)" --arg root "$self_dir" \
        --arg run "${1:-}" --arg mode "${2:-}" --argjson until "$backoff_until" \
        --slurpfile prev <(cat "$miner_json" 2>/dev/null || echo '{}') \
        '{pid: ($pid|tonumber), beat_at: $beat, root: $root,
          running: (if $run == "" then null else {sid: $run, mode: $mode} end),
          backoff_until: $until,
          sessions: (($prev[0].sessions // {}))}' > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$miner_json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# Record how far a session has been mined. Deliberately NOT in the spool record: spool_write_record
# rebuilds that JSON on every Stop and preserves only drain_attempts, so a session still running a
# PINNED older hook would wipe this marker and the same tail would be mined again, forever.
remember_mined() {   # sid, offset, result
  local tmp
  tmp=$(mktemp "$state/.miner.XXXXXX" 2>/dev/null) || return 0
  jq --arg sid "$1" --argjson off "$2" --arg res "$3" --arg at "$(date -Is)" \
     '.sessions[$sid] = {mined_offset: $off, mined_at: $at, result: $res}' "$miner_json" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$miner_json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

mined_offset() {   # sid
  jq -r --arg sid "$1" '.sessions[$sid].mined_offset // 0' "$miner_json" 2>/dev/null || echo 0
}

# A newer installed version takes over in place: a vault release must not wait for a human to remember
# `systemctl --user restart`. Only ever re-execs WITHIN the plugin cache — a repo checkout stays put.
self_update() {
  case "$self_dir" in
    "$HOME/.claude/plugins/cache/"*) ;;
    *) return 0 ;;
  esac
  local base newest
  base="$(cd "$self_dir/../../../.." && pwd)"   # …/cache/<marketplace>/<plugin>
  newest=$(ls -d "$base"/*/ 2>/dev/null | sort -V | tail -1)
  [[ -n "$newest" && -x "${newest}skills/vault/scripts/miner.sh" ]] || return 0
  [[ "$(cd "${newest}skills/vault/scripts" && pwd)" == "$self_dir" ]] && return 0
  log_event "" self-update "→ ${newest}"
  exec bash "${newest}skills/vault/scripts/miner.sh" "$@"
}

mine_one() {   # spool file, mode(live|ended), tail
  local f="$1" mode="$2" sid transcript snapshot prev log result
  sid=$(jq -r '.session_id // ""' "$f" 2>/dev/null)
  transcript=$(jq -r '.transcript_path // ""' "$f" 2>/dev/null)
  [[ -n "$sid" && -f "$transcript" ]] || return 0
  snapshot=$(stat -c %s "$transcript" 2>/dev/null || echo 0)
  prev=$(mined_offset "$sid")
  log="$state/spool-drain/$sid.log"

  # The drain log is APPEND-ONLY across attempts, so "the last verdict in the file" can belong to a run
  # that finished hours ago. Remember where the log ended before launching and read ONLY what this run
  # appended — otherwise a pass that spawned nothing inherits an old success and advances the marker
  # across a tail nobody mined (caught on the first dry run against real state, 2026-09-12).
  local pre post slice
  pre=$(stat -c %s "$log" 2>/dev/null || echo 0)
  write_state "$sid" "$mode"
  log_event "$sid" mine "mode=$mode tail=$3 from=$prev to=$snapshot"
  if [[ "$mode" == "live" ]]; then
    VAULT_DRAIN_LIVE=1 VAULT_DRAIN_BOUNDARY_BYTES="$prev" bash "$self_dir/spool-drain.sh" --run "$f"
  else
    VAULT_DRAIN_BOUNDARY_BYTES="$prev" bash "$self_dir/spool-drain.sh" --run "$f"
  fi
  write_state "" ""

  # Only this run's output. A dry run truncates the log, so post <= pre and the slice is empty — which is
  # the honest answer: nothing ran, nothing is proven, the marker stays.
  post=$(stat -c %s "$log" 2>/dev/null || echo 0)
  slice=""
  (( post > pre )) && slice=$(tail -c "+$((pre + 1))" "$log" 2>/dev/null)
  # ANCHORED: the prompt itself contains 'Finish with exactly one line: "spool-worker <sid>: …"', and an
  # unanchored match reads that sentence as a verdict.
  result=$(printf '%s' "$slice" | tac | grep -m1 -E '^spool-worker [^:]+: ' | sed 's/^spool-worker [^:]*: //' | cut -c1-120)
  if printf '%s' "$slice" | grep -qiE 'API Error: (401|403|429)|usage limit|rate.?limit|Failed to authenticate|Request not allowed'; then
    backoff=$(( backoff == 0 ? backoff_min : backoff * 2 ))
    (( backoff > backoff_max )) && backoff=$backoff_max
    backoff_until=$(( $(date +%s) + backoff ))
    log_event "$sid" backoff "api-error — next attempt in ${backoff}s"
    write_state "" ""
    return 0
  fi
  backoff=0
  backoff_until=0
  # Only a finished run moves the marker. A FAILED sync leaves the tail unmined so the next pass retries
  # it; anything else (synced, or a genuine no-delta) means this snapshot is accounted for.
  if [[ -n "$result" && "$result" != FAILED* ]]; then
    remember_mined "$sid" "$snapshot" "$result"
    log_event "$sid" mined "$result"
  else
    log_event "$sid" incomplete "${result:-no final line}"
  fi
}

pass() {
  local spool f sid cwd transcript live pid tail off best_f="" best_mode="" best_tail=0
  spool="$(spool_dir)"
  [[ -d "$spool" ]] || return 0
  for f in "$spool"/*.json; do
    [[ -e "$f" ]] || break
    sid=$(jq -r '.session_id // ""' "$f" 2>/dev/null)
    cwd=$(jq -r '.cwd // ""' "$f" 2>/dev/null)
    transcript=$(jq -r '.transcript_path // ""' "$f" 2>/dev/null)
    live=$(jq -r '.live // false' "$f" 2>/dev/null)
    pid=$(jq -r '.pid // ""' "$f" 2>/dev/null)
    [[ -n "$sid" ]] || continue
    is_paused "$sid" "$cwd" && continue
    # A record whose transcript is gone is the drain's to retire, not the miner's to measure.
    if [[ -z "$transcript" || ! -f "$transcript" ]]; then bash "$self_dir/spool-drain.sh" --run "$f"; continue; fi

    local mode="ended" floor="$dead_floor"
    if [[ "$live" == "true" ]] && session_is_live "$pid"; then mode="live"; floor="$live_floor"; fi

    off=$(mined_offset "$sid")
    tail=$(python3 "$self_dir/transcript-digest.py" "$transcript" "$state/spool-drain/$sid.digest.md" --boundary-at-byte "$off" 2>/dev/null \
           | sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p')
    [[ -n "$tail" ]] || continue
    if (( tail < floor )); then
      # An ENDED session under the floor is bookkeeping noise: hand it to the drain, which retires it.
      [[ "$mode" == "ended" ]] && bash "$self_dir/spool-drain.sh" --run "$f"
      continue
    fi
    if (( tail > best_tail )); then best_tail=$tail; best_f="$f"; best_mode="$mode"; fi
  done
  # ONE worker at a time, machine-wide. Five concurrent workers on 2026-09-10 edited the shared
  # _index.md in one working tree and one of them failed DIVERGED; sync.sh's git lock does not cover
  # the capture subagent's file edits, so the serialization has to wrap the whole run.
  [[ -n "$best_f" ]] || return 0
  exec 9>"$lock"
  if ! flock -n 9; then log_event "" busy "another worker holds the lock"; return 0; fi
  mine_one "$best_f" "$best_mode" "$best_tail"
  flock -u 9
}

[[ "${VAULT_MINER_DISABLE:-0}" == "1" ]] && exit 0
command -v jq >/dev/null 2>&1 || { echo "miner: jq is required" >&2; exit 1; }

once=0
[[ "${1:-}" == "--once" ]] && once=1

log_event "" start "pid=$$ poll=${poll}s live_floor=${live_floor}B root=$self_dir"
while :; do
  write_state "" ""
  self_update "$@"
  if (( backoff_until <= $(date +%s) )); then pass; fi
  (( once )) && break
  sleep "$poll"
done
