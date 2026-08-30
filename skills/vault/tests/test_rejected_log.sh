#!/usr/bin/env bash
# The salience gate's audit trail. SKILL.md calls this log "the only way the
# gate's false-negative rate is ever measurable" — and it was being written to
# /tmp, which is tmpfs, so the instrument was destroyed at every reboot. The
# 2026-08-30 re-audit tried to compute a rate from it and found 4 surviving files
# across 38 session dirs, with no knowable denominator.

rej_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REJ="$(cd "$rej_self_dir/../scripts" && pwd)/rejected-log.sh"

state="$(mktemp -d)"
export VAULT_STATE_DIR="$state"

# --- it records, outside /tmp-by-session, and accumulates --------------------
out=$(bash "$REJ" "a route table for /orders" "re-derivable from one router file" "sess-1" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "rejected-log: a rejection is recorded"
bash "$REJ" "the exact wording of a banner" "implementation detail" "sess-2" >/dev/null 2>&1
n=$(wc -l < "$state/rejected.log")
assert_eq "2" "$n" "rejected-log: rejections from different sessions pool into one file"

# --- the row is parseable: ts, session, candidate, reason --------------------
fields=$(awk -F'\t' 'NR==1{print NF}' "$state/rejected.log")
assert_eq "4" "$fields" "rejected-log: each row has 4 tab-separated fields"
sid=$(awk -F'\t' 'NR==1{print $2}' "$state/rejected.log")
assert_eq "sess-1" "$sid" "rejected-log: the session id is recorded, so a rate has a denominator"

# --- a multi-line candidate must not break the format for every later parse --
bash "$REJ" "$(printf 'line one\nline two\twith a tab')" "$(printf 'why\nspanning lines')" "sess-3" >/dev/null 2>&1
bad=$(awk -F'\t' 'NF!=4' "$state/rejected.log" | wc -l)
assert_eq "0" "$bad" "rejected-log: newlines and tabs in the payload cannot corrupt the row format"
n=$(wc -l < "$state/rejected.log")
assert_eq "3" "$n" "rejected-log: a multi-line candidate is still exactly one row"

# --- refuses a half-filled record rather than logging a useless one ----------
out=$(bash "$REJ" "candidate with no reason" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "rejected-log: a rejection without a reason is refused"

rm -rf "$state"
unset VAULT_STATE_DIR
