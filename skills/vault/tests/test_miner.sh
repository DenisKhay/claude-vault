# test_miner.sh — the 1.8.0 miner daemon. Sourced by run.sh (test_helper.sh already loaded).
#
# Every case runs against an isolated VAULT_STATE_DIR/VAULT_SPOOL_DIR and a FAKE claude on PATH, so the
# suite never touches the real audit trail and never spends a token.

miner_dir=$(mktemp -d)
miner_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
miner_scripts="$(cd "$miner_self_dir/../scripts" && pwd)"
_exists() { [[ -e "$1" ]] && echo yes || echo no; }

# A fake worker that prints the protocol line the miner parses, and a process whose comm is `claude` so
# session_is_live() answers true for a fixture session.
mkdir -p "$miner_dir/bin"
cat > "$miner_dir/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
echo "${VAULT_FAKE_WORKER_OUTPUT:-spool-worker fixture: 2 updated, 0 new (synced)}"
FAKE
chmod +x "$miner_dir/bin/claude"
# comm == "claude" is what session_is_live checks, and comm is the BASENAME of the executable — so the
# stand-in has to be named exactly `claude`, in a dir that is NOT on PATH (bin/claude is the fake worker).
mkdir -p "$miner_dir/proc"
cp /bin/sleep "$miner_dir/proc/claude"

miner_transcript() {   # file, count, marker
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, n, mark = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, "a") as f:
    for i in range(n):
        f.write(json.dumps({"type": "assistant", "timestamp": "2026-09-12T10:00:00Z",
                            "message": {"content": [{"type": "text", "text": "%s %d: %s" % (mark, i, "y" * 1000)}]}}) + "\n")
PY
}

miner_record() {   # sid, transcript, live, pid
  jq -n --arg s "$1" --arg tp "$2" --argjson live "$3" --arg pid "$4" \
    '{session_id:$s, cwd:"/tmp", transcript_path:$tp, live:$live,
      pid:($pid|if .=="" then null else tonumber end), ended_at:null, touched_at:"now", drain_attempts:0}' \
    > "$miner_dir/spool/$1.json"
}

miner_run() {   # extra env assignments are inherited from the caller
  PATH="$miner_dir/bin:$PATH" VAULT_STATE_DIR="$miner_dir/state" VAULT_SPOOL_DIR="$miner_dir/spool" \
    bash "$miner_scripts/miner.sh" --once >/dev/null 2>&1
}

miner_reset() {
  rm -rf "$miner_dir/state" "$miner_dir/spool"
  mkdir -p "$miner_dir/state" "$miner_dir/spool"
}

# --- digest boundary ----------------------------------------------------------------------------
miner_reset
t="$miner_dir/t1.jsonl"; : > "$t"; miner_transcript "$t" 40 first
full=$(python3 "$miner_scripts/transcript-digest.py" "$t" /dev/null | sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p')
at_eof=$(python3 "$miner_scripts/transcript-digest.py" "$t" /dev/null --boundary-at-byte "$(stat -c %s "$t")" | sed -n 's/.*tail_bytes=\([0-9]*\).*/\1/p')
assert_eq "0" "$at_eof" "digest: a boundary at EOF leaves no tail (a just-mined session is not re-mined)"
assert_eq yes "$( (( full > 30000 )) && echo yes || echo no )" "digest: without the flag the whole transcript is the tail"

# --- a live session is mined, and its record survives --------------------------------------------
miner_reset
t="$miner_dir/t2.jsonl"; : > "$t"; miner_transcript "$t" 40 live
"$miner_dir/proc/claude" 60 & live_pid=$!
sleep 0.2
miner_record live-a "$t" true "$live_pid"
miner_run
assert_eq yes "$(_exists "$miner_dir/spool/live-a.json")" "miner: a LIVE record is kept after mining (it is still crash insurance)"
assert_contains "mode=live" "$(grep 'Miner	mine	' "$miner_dir/state/hook-events.log")" "miner: a session whose pid is a live claude is mined in LIVE mode"
off=$(jq -r '.sessions["live-a"].mined_offset // 0' "$miner_dir/state/miner.json")
assert_eq "$(stat -c %s "$t")" "$off" "miner: the mined offset is the transcript size at spawn"

# --- nothing new appended → no second worker -----------------------------------------------------
before=$(grep -c 'Miner	mine	' "$miner_dir/state/hook-events.log" 2>/dev/null || echo 0)
miner_run
after=$(grep -c 'Miner	mine	' "$miner_dir/state/hook-events.log" 2>/dev/null || echo 0)
assert_eq "$before" "$after" "miner: an unchanged transcript is not mined again"

# --- new text past the floor → mined from the marker, not from zero -------------------------------
miner_transcript "$t" 40 later
miner_run
from=$(grep 'Miner	mine	' "$miner_dir/state/hook-events.log" | tail -1 | sed -n 's/.*from=\([0-9]*\).*/\1/p')
assert_eq "$off" "$from" "miner: the next run mines from the recorded marker (only the new tail)"
kill $live_pid 2>/dev/null || true

# --- an old hook rewriting the record must NOT lose the marker ------------------------------------
# spool_write_record keeps only drain_attempts, which is exactly why the marker lives in miner.json.
source "$miner_scripts/common.sh"
before_rewrite=$(jq -r '.sessions["live-a"].mined_offset // "gone"' "$miner_dir/state/miner.json")
VAULT_SPOOL_DIR="$miner_dir/spool" spool_write_record live-a /tmp "$t" true 99999
kept=$(jq -r '.sessions["live-a"].mined_offset // "gone"' "$miner_dir/state/miner.json")
assert_eq "$before_rewrite" "$kept" "miner: a Stop-hook record rewrite does not wipe the mined marker"
assert_eq "0" "$(jq -r '.drain_attempts' "$miner_dir/spool/live-a.json")" "miner: live mining never burns the record's drain_attempts"

# --- a live session under the floor is left alone (never deleted) ---------------------------------
miner_reset
t="$miner_dir/t3.jsonl"; : > "$t"; miner_transcript "$t" 2 small
"$miner_dir/proc/claude" 60 & live_pid=$!
sleep 0.2
miner_record live-small "$t" true "$live_pid"
miner_run
assert_eq yes "$(_exists "$miner_dir/spool/live-small.json")" "miner: a live record under the floor is kept, not retired"
assert_eq "null" "$(jq -r '.sessions["live-small"] // "null"' "$miner_dir/state/miner.json")" "miner: a sub-floor live session is not mined"
kill $live_pid 2>/dev/null || true

# --- an ENDED session under the floor is retired (1.6.0 behaviour, unchanged) ---------------------
miner_reset
t="$miner_dir/t4.jsonl"; : > "$t"; miner_transcript "$t" 2 tiny
miner_record ended-small "$t" false ""
miner_run
assert_eq no "$(_exists "$miner_dir/spool/ended-small.json")" "miner: an ended sub-floor record is retired"

# --- a paused session is never mined ---------------------------------------------------------------
miner_reset
t="$miner_dir/t5.jsonl"; : > "$t"; miner_transcript "$t" 40 paused
miner_record paused-a "$t" false ""
touch "/tmp/vault-paused-a/paused" 2>/dev/null || { mkdir -p /tmp/vault-paused-a && touch /tmp/vault-paused-a/paused; }
miner_run
assert_eq yes "$(_exists "$miner_dir/spool/paused-a.json")" "miner: a paused session is skipped entirely"
rm -rf /tmp/vault-paused-a

# --- an API error backs off instead of burning attempts -------------------------------------------
miner_reset
t="$miner_dir/t6.jsonl"; : > "$t"; miner_transcript "$t" 40 err
miner_record api-a "$t" false ""
VAULT_FAKE_WORKER_OUTPUT="API Error: 403 Request not allowed" miner_run
assert_contains "Miner	backoff" "$(cat "$miner_dir/state/hook-events.log")" "miner: an API error triggers backoff"
until_ts=$(jq -r '.backoff_until // 0' "$miner_dir/state/miner.json")
assert_eq yes "$( (( until_ts > $(date +%s) )) && echo yes || echo no )" "miner: backoff_until is set in the future"

# --- heartbeat + miner_alive ------------------------------------------------------------------------
# run.sh runs under `set -e`, so a bare non-zero return — which is exactly what this asserts — would
# abort the whole suite. Capture it in a condition instead.
if VAULT_STATE_DIR="$miner_dir/state" miner_alive; then miner_rc=0; else miner_rc=1; fi
assert_exit 1 "$miner_rc" "miner_alive: a finished --once run does not read as a live daemon"
beat=$(jq -r '.beat_at // ""' "$miner_dir/state/miner.json")
assert_eq yes "$( [[ -n "$beat" ]] && echo yes || echo no )" "miner: every pass writes a heartbeat"

rm -rf "$miner_dir"
