#!/usr/bin/env bash
# spool-drain.sh + transcript-digest.py + the worker guards. 2026-09-05: five unswept
# tails accumulated and every SessionStart nagged until a live session spent ~25 min on
# them; two of the five were empty. SessionEnd cannot prompt a model but can spawn one.

drain_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
drain_script_dir="$(cd "$drain_self_dir/../scripts" && pwd)"

_drain_fixture() {   # path, marker_count (0..2) — writes a transcript JSONL
  local tp="$1" markers="${2:-2}"
  : > "$tp"
  _u() { jq -nc --arg t "$1" '{type:"user", timestamp:"2026-09-05T10:00:00Z", message:{role:"user", content:$t}}' >> "$tp"; }
  _a() { jq -nc --arg t "$1" '{type:"assistant", timestamp:"2026-09-05T10:01:00Z", message:{role:"assistant", content:[{type:"text", text:$t}]}}' >> "$tp"; }
  _m() { _u $'Stop hook feedback:\n[bash /x/skills/vault/scripts/prompt-actualize.sh]: Vault sync: invoke the vault skill in actualize mode.'; }
  _u "first question about the road"
  _a "long answer one $(head -c 6000 /dev/zero | tr '\0' 'a')"
  (( markers >= 1 )) && _m
  _a "no knowledge delta — nothing to capture this turn"
  (( markers >= 2 )) && { _m; _a "vault: 2 updated, 0 new (synced)"; }
  _u "TAILQUESTION about the palette"
  _a "TAILANSWER the wine accent lives under --blue"
}

# The crash case the audit found (digest-boundary-is-nag-not-sweep, HIGH): the nag arrived, the
# session died before the sweep finished. That tail was NEVER swept and must not be counted as such.
_drain_fixture_crashed() {   # path — one COMPLETED sweep, then knowledge, then a nag the session never finished
  local tp="$1"
  : > "$tp"
  _u() { jq -nc --arg t "$1" '{type:"user", timestamp:"2026-09-05T10:00:00Z", message:{role:"user", content:$t}}' >> "$tp"; }
  _a() { jq -nc --arg t "$1" '{type:"assistant", timestamp:"2026-09-05T10:01:00Z", message:{role:"assistant", content:[{type:"text", text:$t}]}}' >> "$tp"; }
  _t() { jq -nc '{type:"assistant", timestamp:"2026-09-05T10:02:00Z", message:{role:"assistant", content:[{type:"tool_use", name:"Bash", input:{command:"grep -rn something"}}]}}' >> "$tp"; }
  _u "first question"
  _a "answer one"
  _u $'Stop hook feedback:\n[bash /x/skills/vault/scripts/prompt-actualize.sh]: Vault sync: invoke the vault skill in actualize mode.'
  _a "no knowledge delta — nothing to capture this turn"
  _a "KNOWLEDGE a hard-won scar, thirty minutes of real findings $(head -c 5000 /dev/zero | tr '\0' 'b')"
  _u $'Stop hook feedback:\n[bash /x/skills/vault/scripts/prompt-actualize.sh]: Vault sync: last actualize was 1900s ago — sweep the DELTA.'
  _t
  _t
}

_drain_env() {   # sets up an isolated state/spool dir pair, echoes the root
  local root; root=$(mktemp -d /tmp/vault-drain-test.XXXXXX)
  mkdir -p "$root/state" "$root/spool"
  echo "$root"
}

_drain_spool() {   # root, sid, tp, attempts
  jq -n --arg sid "$2" --arg tp "$3" --argjson n "${4:-0}" \
    '{session_id:$sid, cwd:"/x", transcript_path:$tp, ended_at:"2026-09-05T18:00:00+03:00", drain_attempts:$n}' \
    > "$1/spool/$2.json"
}

# --- digest: boundaries and tail bytes ------------------------------------------
root=$(_drain_env)
_drain_fixture "$root/t2.jsonl" 2
out=$(python3 "$drain_script_dir/transcript-digest.py" "$root/t2.jsonl" "$root/t2.md" 2>/dev/null || true)
assert_contains "boundaries=2" "$out" "digest: two sweep markers are two boundaries"
tail_bytes=$(sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p' <<<"$out")
[[ "$tail_bytes" -gt 40 && "$tail_bytes" -lt 400 ]] && got=ok || got="bad:$tail_bytes"
assert_eq "ok" "$got" "digest: tail_bytes counts only the text after the last boundary"
assert_contains "VAULT SWEEP BOUNDARY #2" "$(cat "$root/t2.md")" "digest: boundary lines are rendered"
assert_contains "TAILANSWER" "$(sed -n '/BOUNDARY #2/,$p' "$root/t2.md")" "digest: tail text sits after the last boundary"

_drain_fixture "$root/t0.jsonl" 0
out=$(python3 "$drain_script_dir/transcript-digest.py" "$root/t0.jsonl" "$root/t0.md" 2>/dev/null || true)
assert_contains "boundaries=0" "$out" "digest: no marker → no boundary"
tail_bytes=$(sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p' <<<"$out")
[[ "$tail_bytes" -gt 6000 ]] && got=ok || got="bad:$tail_bytes"
assert_eq "ok" "$got" "digest: no marker → the whole transcript is the tail"

# --- digest: a nag with NO completion is NOT a boundary (the crash case) -----------------
_drain_fixture_crashed "$root/tc.jsonl"
out=$(python3 "$drain_script_dir/transcript-digest.py" "$root/tc.jsonl" "$root/tc.md" 2>/dev/null || true)
assert_contains "boundaries=1" "$out" "digest: only the COMPLETED sweep is a boundary; the unfinished nag is not"
tail_bytes=$(sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p' <<<"$out")
[[ "$tail_bytes" -gt 5000 ]] && got=ok || got="bad:$tail_bytes"
assert_eq "ok" "$got" "digest: knowledge written before an unfinished nag is UNSWEPT tail, not 'already captured'"
assert_contains "KNOWLEDGE" "$(sed -n '/BOUNDARY #1/,$p' "$root/tc.md")" "digest: that knowledge sits after the last real boundary, where the worker reads"

# --- drain: under the floor deletes the spool and logs ----------------------------
_drain_spool "$root" "drain-empty" "$root/t2.jsonl"
VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
  bash "$drain_script_dir/spool-drain.sh" --run "$root/spool/drain-empty.json" >/dev/null 2>&1 || true
[[ -f "$root/spool/drain-empty.json" ]] && got=kept || got=deleted
assert_eq "deleted" "$got" "drain: a tail under the floor deletes the spool record"
assert_contains "tail-empty" "$(cat "$root/state/hook-events.log" 2>/dev/null)" "drain: the empty-tail decision is logged"

# --- drain: above the floor spawns a worker (dry-run writes the command) ----------
_drain_spool "$root" "drain-full" "$root/t0.jsonl"
VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
  bash "$drain_script_dir/spool-drain.sh" --run "$root/spool/drain-full.json" >/dev/null 2>&1 || true
[[ -f "$root/spool/drain-full.json" ]] && got=kept || got=deleted
assert_eq "kept" "$got" "drain: a real tail keeps the spool record until the worker succeeds"
cmd=$(cat "$root/state/spool-drain/drain-full.log" 2>/dev/null || true)
assert_contains "--model sonnet" "$cmd" "drain: the worker runs on sonnet"
assert_contains "VAULT_SPOOL_WORKER=1" "$cmd" "drain: the worker is marked so hooks do not recurse"
assert_contains "drain-full" "$cmd" "drain: the worker prompt names the session"
assert_not_contains "spool-worker" "${cmd%%--- stdin prompt ---*}" "drain: the prompt travels over stdin, not argv (variadic --allowedTools would eat it)"
assert_contains "--allowedTools" "$cmd" "drain: the worker runs with an explicit tool allowlist"
assert_contains "rejected-log.sh" "$cmd" "drain: the prompt hands the worker the scripts directory (the first real worker ran find / for it)"
assert_eq "1" "$(jq -r '.drain_attempts' "$root/spool/drain-full.json")" "drain: the attempt is counted in the spool record"
assert_contains "spawn" "$(cat "$root/state/hook-events.log")" "drain: the spawn decision is logged"

# --- drain: attempts exhausted → no spawn, record kept for manual mining ----------
_drain_spool "$root" "drain-tired" "$root/t0.jsonl" 3
VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
  bash "$drain_script_dir/spool-drain.sh" --run "$root/spool/drain-tired.json" >/dev/null 2>&1 || true
[[ -f "$root/state/spool-drain/drain-tired.log" ]] && got=spawned || got=held
assert_eq "held" "$got" "drain: after max attempts nothing is spawned"
assert_contains "max-attempts" "$(cat "$root/state/hook-events.log")" "drain: giving up is logged"

# --- worker guards: a worker session never spools or self-sweeps ------------------
tp="$root/worker.jsonl"; : > "$tp"
jq -nc --arg tp "$tp" '{session_id:"drain-worker", cwd:"/x", hook_event_name:"SessionEnd", transcript_path:$tp}' \
  | VAULT_SPOOL_WORKER=1 VAULT_SPOOL_DIR="$root/spool" bash "$drain_script_dir/spool-tail.sh" >/dev/null 2>&1 || true
[[ -f "$root/spool/drain-worker.json" ]] && got=spooled || got=skipped
assert_eq "skipped" "$got" "guard: a worker session is never spooled"

rm -rf /tmp/vault-drain-worker-stop
code=0
out=$(jq -nc '{session_id:"drain-worker-stop", cwd:"/x", hook_event_name:"Stop", stop_hook_active:false}' \
  | VAULT_SPOOL_WORKER=1 bash "$drain_script_dir/prompt-actualize.sh" 2>&1) || code=$?
assert_exit 0 "$code" "guard: the Stop hook lets a worker session exit"
assert_eq "" "$out" "guard: the Stop hook says nothing to a worker session"

# --- SessionStart: a worker gets no spool listing; a normal session relaunches -----
_drain_spool "$root" "drain-pending" "$root/t0.jsonl"
touch -d '-30 minutes' "$root/spool/drain-pending.json"
out=$(jq -nc '{session_id:"drain-ss-worker", cwd:"/nonexistent-drain-test", hook_event_name:"SessionStart"}' \
  | VAULT_SPOOL_WORKER=1 VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
    bash "$drain_script_dir/inject-context.sh" 2>/dev/null || true)
assert_not_contains "UNSWEPT" "$out" "SessionStart: a worker session is not told about pending spools"

out=$(jq -nc '{session_id:"drain-ss-normal", cwd:"/nonexistent-drain-test", hook_event_name:"SessionStart"}' \
  | VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
    bash "$drain_script_dir/inject-context.sh" 2>/dev/null || true)
assert_contains "drain-pending" "$(cat "$root/state/hook-events.log")" "SessionStart: a stale pending spool is relaunched"
assert_contains "auto-drain" "$out" "SessionStart: the notice says workers were launched, not 'mine it yourself'"

_drain_spool "$root" "drain-gaveup" "$root/t0.jsonl" 3
touch -d '-30 minutes' "$root/spool/drain-gaveup.json"
out=$(jq -nc '{session_id:"drain-ss-normal2", cwd:"/nonexistent-drain-test", hook_event_name:"SessionStart"}' \
  | VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
    bash "$drain_script_dir/inject-context.sh" 2>/dev/null || true)
assert_contains "drain-gaveup" "$out" "SessionStart: a spool auto-drain gave up on is listed for manual mining"

rm -rf "$root"

# --- 1.7.0: a record for a LIVE session is never mined; a crashed one (dead pid) is ---------
root=$(_drain_env)
_drain_fixture "$root/live.jsonl" 0
# live=true with THIS shell's own ancestor claude (or, failing that, any live pid that is claude) → skip
livepid=$(pgrep -x claude | head -1)
if [[ -n "$livepid" ]]; then
  jq -n --arg sid "live-sess" --arg tp "$root/live.jsonl" --argjson pid "$livepid" \
    '{session_id:$sid, cwd:"/x", transcript_path:$tp, live:true, pid:$pid, ended_at:null, drain_attempts:0}' > "$root/spool/live-sess.json"
  VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
    bash "$drain_script_dir/spool-drain.sh" --run "$root/spool/live-sess.json" >/dev/null 2>&1 || true
  [[ -f "$root/spool/live-sess.json" ]] && got=kept || got=deleted
  assert_eq "kept" "$got" "drain: a live session's record is left alone (never mine a running session)"
  assert_contains "session-live" "$(cat "$root/state/hook-events.log" 2>/dev/null)" "drain: the live skip is logged"
  [[ -f "$root/state/live-sess.log" ]] && got=spawned || got=no-spawn
  assert_eq "no-spawn" "$got" "drain: no worker is spawned for a live session"
fi
# live=true but the pid is dead (a crashed session) → the drain proceeds like an ended one
jq -n --arg sid "crashed-sess" --arg tp "$root/live.jsonl" \
  '{session_id:$sid, cwd:"/x", transcript_path:$tp, live:true, pid:4194000, ended_at:null, drain_attempts:0}' > "$root/spool/crashed-sess.json"
VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_DRAIN_DRY_RUN=1 \
  bash "$drain_script_dir/spool-drain.sh" --run "$root/spool/crashed-sess.json" >/dev/null 2>&1 || true
assert_contains "spawn" "$(grep crashed-sess "$root/state/hook-events.log" 2>/dev/null)" "drain: a crashed session (dead pid) IS mined — that is the insurance"
rm -rf "$root"

# --- 1.7.0: the worker log appends per attempt instead of truncating (failures stay visible) --
grep -q '>> "$state/$sid.log"' "$drain_script_dir/spool-drain.sh" && got=append || got=truncate
assert_eq "append" "$got" "drain: the worker log is append-only across attempts"

# --- 1.7.0: SessionEnd preserves drain_attempts and marks the record ended -------------------
root=$(_drain_env)
_drain_fixture "$root/end.jsonl" 0
jq -n --arg sid "end-sess" --arg tp "$root/end.jsonl" \
  '{session_id:$sid, cwd:"/x", transcript_path:$tp, live:true, pid:4194000, ended_at:null, drain_attempts:2}' > "$root/spool/end-sess.json"
input=$(jq -nc --arg tp "$root/end.jsonl" '{session_id:"end-sess", cwd:"/x", hook_event_name:"SessionEnd", transcript_path:$tp}')
echo "$input" | VAULT_STATE_DIR="$root/state" VAULT_SPOOL_DIR="$root/spool" VAULT_SPOOL_AUTODRAIN=0 bash "$drain_script_dir/spool-tail.sh" >/dev/null 2>&1 || true
assert_eq "2" "$(jq -r .drain_attempts "$root/spool/end-sess.json" 2>/dev/null)" "spool-tail: SessionEnd keeps the attempts counter a Stop write started"
assert_eq "false" "$(jq -r .live "$root/spool/end-sess.json" 2>/dev/null)" "spool-tail: SessionEnd marks the record ended"
rm -rf "$root"
