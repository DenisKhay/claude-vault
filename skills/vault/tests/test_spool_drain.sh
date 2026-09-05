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
  (( markers >= 2 )) && _m
  _u "TAILQUESTION about the palette"
  _a "TAILANSWER the wine accent lives under --blue"
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
assert_contains "--allowedTools" "$cmd" "drain: the worker runs with an explicit tool allowlist"
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
