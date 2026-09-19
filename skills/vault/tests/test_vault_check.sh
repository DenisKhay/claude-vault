#!/usr/bin/env bash
# vault-check.sh — each invariant is a real 2026-09-14..16 incident that reported success while losing
# knowledge. A green fixture must print NOTHING; each red must name what a human should do.
check_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$check_self_dir/../scripts" && pwd)"
CHECK="$SCRIPTS/vault-check.sh"

# A clean, pushed store with a matching deployed plugin and an idle miner: the baseline every case
# below perturbs in exactly one way.
_check_fixture() {   # dir
  local d="$1"
  _sync_fixture "$d"
  git -C "$d/A" reset -q --hard origin/main
  git -C "$d/A" push -q origin main 2>/dev/null || true
  mkdir -p "$d/state" "$d/spool" "$d/plugins" "$d/repo/.claude-plugin"
  printf '{"version":"9.9.9"}\n' > "$d/repo/.claude-plugin/plugin.json"
  printf '{"claude-vault":{"source":{"source":"directory","path":"%s"}}}\n' "$d/repo" > "$d/plugins/known_marketplaces.json"
  printf '{"version":2,"plugins":{"vault@claude-vault":[{"version":"9.9.9"}]}}\n' > "$d/plugins/installed_plugins.json"
  # a live miner heartbeat from THIS process, so miner_alive is true and the starved check runs
  printf '{"pid":%s,"beat_at":"%s","sessions":{}}\n' "$$" "$(date -Is)" > "$d/state/miner.json"
}
_run_check() {   # dir [args]
  local d="$1"; shift
  VAULT_ROOT="$d/A" VAULT_STATE_DIR="$d/state" VAULT_SPOOL_DIR="$d/spool" VAULT_PLUGINS_DIR="$d/plugins" \
    bash "$CHECK" "$@" 2>&1
}

# --- green is silent ---------------------------------------------------------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a healthy vault exits 0"
assert_eq "" "$out" "check: a healthy vault prints nothing — green must not become noise"
out=$(_run_check "$tmp" --json)
assert_eq "true" "$(jq -r .ok <<<"$out")" "check --json: ok=true on a healthy vault"
rm -rf "$tmp"

# --- 1. a node dirty for longer than a sweep takes is lost, not in flight ------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf 'orphan\n' > "$tmp/A/sg/orphan.md"; touch -d '-3 hours' "$tmp/A/sg/orphan.md"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: an old dirty node is red"
assert_contains "never committed" "$out" "check: the red names the failure"
assert_contains "3h ago" "$out" "check: and how long it has been lost"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf 'being written right now\n' > "$tmp/A/sg/inflight.md"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a node touched seconds ago belongs to a live sweep and is NOT red"
rm -rf "$tmp"

# --- 2. unpushed commits: say WHY, and only then touch the network ------------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf 'local only\n' > "$tmp/A/sg/local.md"
git -C "$tmp/A" add -A; GIT_COMMITTER_DATE="$(date -d '-10 minutes' -Is)" git -C "$tmp/A" commit -q -m local --date="$(date -d '-10 minutes' -Is)"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: an unpushed commit older than the grace window is red"
assert_contains "1 commit(s) not on origin" "$out" "check: the backlog count is stated"
assert_contains "remote IS reachable" "$out" "check: a reachable remote means the PUSH is failing — said so"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf 'just now\n' > "$tmp/A/sg/fresh.md"
git -C "$tmp/A" add -A; git -C "$tmp/A" commit -q -m fresh
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a commit seconds old may still be mid-push — not red yet"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf 'offline\n' > "$tmp/A/sg/off.md"
git -C "$tmp/A" add -A; git -C "$tmp/A" commit -q -m off --date="$(date -d '-10 minutes' -Is)"
GIT_COMMITTER_DATE="$(date -d '-10 minutes' -Is)" git -C "$tmp/A" commit -q --amend --no-edit --date="$(date -d '-10 minutes' -Is)"
git -C "$tmp/A" remote set-url origin "$tmp/does-not-exist.git"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: unpushed + unreachable local remote is red"
assert_contains "unreachable" "$out" "check: a missing non-ssh remote is reported unreachable, not auth"
rm -rf "$tmp"

# --- 3. deployed plugin != repo: sessions run old scripts ---------------------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf '{"version":2,"plugins":{"vault@claude-vault":[{"version":"1.7.0"}]}}\n' > "$tmp/plugins/installed_plugins.json"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: deploy drift is red"
assert_contains "deployed at 1.7.0 but the repo is at 9.9.9" "$out" "check: both versions are named"
assert_contains "claude plugin update" "$out" "check: the fix command is in the line"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf '{"claude-vault":{"source":{"source":"github","repo":"x/y"}}}\n' > "$tmp/plugins/known_marketplaces.json"
printf '{"version":2,"plugins":{"vault@claude-vault":[{"version":"1.0.0"}]}}\n' > "$tmp/plugins/installed_plugins.json"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a GitHub-sourced plugin cannot be compared without the network — not red"
rm -rf "$tmp"

# --- 4. miner up but starved: an ENDED tail unmined for hours ------------------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
t="$tmp/ended.jsonl"; : > "$t"
printf '{"session_id":"dead-1","cwd":"/x","transcript_path":"%s","live":false,"pid":"","drain_attempts":0}\n' "$t" > "$tmp/spool/dead-1.json"
touch -d '-8 hours' "$tmp/spool/dead-1.json"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: an ended record unmined for 8h with a live miner is red"
assert_contains "has not mined 1 ended session" "$out" "check: starvation is named as the miner's failure, not the session's"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
t="$tmp/live.jsonl"; : > "$t"
printf '{"session_id":"live-1","cwd":"/x","transcript_path":"%s","live":true,"pid":"%s","drain_attempts":0}\n' "$t" "$$" > "$tmp/spool/live-1.json"
touch -d '-8 hours' "$tmp/spool/live-1.json"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a LIVE session's record may sit unmined (tail below the floor) — not starvation"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
t="$tmp/mined.jsonl"; : > "$t"
printf '{"session_id":"mined-1","cwd":"/x","transcript_path":"%s","live":false,"pid":"","drain_attempts":0}\n' "$t" > "$tmp/spool/mined-1.json"
touch -d '-8 hours' "$tmp/spool/mined-1.json"
printf '{"pid":%s,"beat_at":"%s","sessions":{"mined-1":{"mined_at":"%s","mined_offset":10,"result":"ok"}}}\n' "$$" "$(date -Is)" "$(date -Is)" > "$tmp/state/miner.json"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: an ended record WITH a mined marker is not starved"
rm -rf "$tmp"

# --- 5. the last sync outcome was a refusal ------------------------------------------------------
tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf '%s\tmiku\tAUTH-DENIED committed=1 unpushed=22 AUTH REJECTED\n' "$(date -Is)" > "$tmp/state/sync.log"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: a last-sync AUTH-DENIED is red"
assert_contains "AUTH-DENIED" "$out" "check: the sync label is surfaced verbatim"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
printf '%s\tmiku\tPUSHED committed=1 ahead=1 behind=0\n' "$(date -Is)" > "$tmp/state/sync.log"
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: a last-sync PUSHED is green"
rm -rf "$tmp"

# --- the check is wired: SessionStart carries it, and the miner records it -----------------------
assert_contains "vault-check.sh" "$(cat "$SCRIPTS/inject-context.sh")" "wiring: inject-context runs the check"
assert_contains "vault-check.sh" "$(cat "$SCRIPTS/miner.sh")" "wiring: the miner runs the check"
assert_contains "|| true" "$(grep vault-check "$SCRIPTS/inject-context.sh")" "wiring: a broken check can never fail the session hook"

# --- 6. the spool ceiling counts ENDED records, not live seats ---------------------------------
# 2026-09-18: 25 records, 15 of them the 15 live seats. Counting every record would red a healthy
# fleet — "a live session's record is not a backlog, it is a session".
tmp="$(mktemp -d)"; _check_fixture "$tmp"
t="$tmp/live.jsonl"; : > "$t"
for i in $(seq 1 60); do
  printf '{"session_id":"live-%s","cwd":"/x","transcript_path":"%s","live":true,"pid":"%s","drain_attempts":0}\n' "$i" "$t" "$$" > "$tmp/spool/live-$i.json"
done
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "0" "$ec" "check: 60 LIVE seats are not a backlog"
assert_eq "" "$out" "check: and say nothing at all"
rm -rf "$tmp"

tmp="$(mktemp -d)"; _check_fixture "$tmp"
t="$tmp/ended.jsonl"; : > "$t"
# attempts spent, so the starvation rule skips them — this isolates the ceiling itself.
for i in $(seq 1 41); do
  printf '{"session_id":"dead-%s","cwd":"/x","transcript_path":"%s","live":false,"pid":"","drain_attempts":3}\n' "$i" "$t" > "$tmp/spool/dead-$i.json"
done
out=$(_run_check "$tmp") && ec=$? || ec=$?
assert_exit "1" "$ec" "check: 41 ENDED records is over the ceiling and red"
assert_contains "41 ENDED records" "$out" "check: the red counts only what is actually a backlog"
rm -rf "$tmp"
