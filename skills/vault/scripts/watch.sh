#!/usr/bin/env bash
# watch.sh — OPTIONAL read-only view of the miner. Open it to confirm capture is working; close it and
# nothing changes. It never schedules, never mines, never writes: every fact here is read from
# miner.json, the spool records and the drain logs.
#
#   vault-watch          refresh every 2s until Ctrl-C
#   vault-watch --once   print one frame (tests, and a quick check over ssh)

set -uo pipefail
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

state="$(vault_state_dir)"
miner_json="$state/miner.json"
once=0
[[ "${1:-}" == "--once" ]] && once=1

hb() {
  local pid beat age
  if [[ ! -f "$miner_json" ]]; then printf '\033[31mMINER NOT INSTALLED\033[0m — capture only when a session ends'; return; fi
  pid=$(jq -r '.pid // "?"' "$miner_json" 2>/dev/null)
  beat=$(jq -r '.beat_at // ""' "$miner_json" 2>/dev/null)
  age=$(( $(date +%s) - $(date -d "$beat" +%s 2>/dev/null || echo 0) ))
  if miner_alive; then printf '\033[32m● running\033[0m  pid %s   heartbeat %ss ago' "$pid" "$age"
  else printf '\033[31m● DOWN\033[0m  pid %s   last heartbeat %sm ago — systemctl --user restart vault-miner' "$pid" "$((age/60))"; fi
}

frame() {
  local floor="${VAULT_MINER_LIVE_FLOOR_BYTES:-32768}" spool f sid cwd tp live pid off tail state_s mark now where
  now=$(date +%s)
  printf '\033[1mvault miner\033[0m   %s\n' "$(hb)"
  local run until
  run=$(jq -r 'if .running then "mining \(.running.sid[0:8]) (\(.running.mode))" else "" end' "$miner_json" 2>/dev/null)
  until=$(jq -r '.backoff_until // 0' "$miner_json" 2>/dev/null)
  [[ -n "$run" ]] && printf '   \033[33m%s\033[0m\n' "$run"
  (( until > now )) && printf '   \033[31mbacked off\033[0m for %sm (API error)\n' "$(( (until-now)/60 ))"
  printf '\n  %-10s %-34s %7s %9s  %s\n' SESSION WHERE TAIL 'OF FLOOR' 'LAST MINE'
  spool="$(spool_dir)"
  for f in "$spool"/*.json; do
    [[ -e "$f" ]] || break
    sid=$(jq -r '.session_id // ""' "$f" 2>/dev/null); cwd=$(jq -r '.cwd // ""' "$f" 2>/dev/null)
    tp=$(jq -r '.transcript_path // ""' "$f" 2>/dev/null); live=$(jq -r '.live // false' "$f" 2>/dev/null)
    pid=$(jq -r '.pid // ""' "$f" 2>/dev/null)
    [[ -f "$tp" ]] || continue
    off=$(jq -r --arg s "$sid" '.sessions[$s].mined_offset // 0' "$miner_json" 2>/dev/null)
    tail=$(python3 "$self_dir/transcript-digest.py" "$tp" /dev/null --boundary-at-byte "${off:-0}" 2>/dev/null | sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p')
    [[ -n "$tail" ]] || tail=0
    if [[ "$live" == "true" ]] && session_is_live "$pid"; then state_s=live; else state_s=ended; fi
    mark=$(jq -r --arg s "$sid" 'if .sessions[$s] then "\(.sessions[$s].mined_at[0:16]) — \(.sessions[$s].result)" else "never" end' "$miner_json" 2>/dev/null)
    [[ -n "$mark" ]] || mark=never
    where=$(echo "$cwd" | sed "s#$HOME/Projects/##")
    (( ${#where} > 33 )) && where="…${where: -32}"
    printf '  %-10s %-34s %6sK %8s%%  %s\n' "${sid:0:8}" "$where" "$(( tail / 1024 ))" "$(( tail * 100 / floor ))" "$mark"
  done
  local gave
  gave=$(grep -c 'max-attempts' "$state/hook-events.log" 2>/dev/null || echo 0)
  (( gave > 0 )) && printf '\n  %s record(s) auto-drain gave up on — see %s/spool-drain/\n' "$gave" "$state"
  printf '\n  %s\n' "$(grep -a 'Miner' "$state/hook-events.log" 2>/dev/null | tail -3 | cut -f1,2,4,5 | tr '\t' ' ' | paste -sd'\n  ' -)"
}

if (( once )); then frame; exit 0; fi
trap 'printf "\033[?25h\n"; exit 0' INT TERM
printf '\033[?25l'
while :; do
  out=$(frame)
  printf '\033[H\033[2J%s\n' "$out"
  sleep 2
done
