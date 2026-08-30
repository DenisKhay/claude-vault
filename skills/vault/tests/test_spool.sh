#!/usr/bin/env bash
# spool-tail.sh + the SessionStart spool listing. Both cases come from the
# 2026-08-30 re-audit: the listing dropped tails past the 5th with no count, and
# the spool reused the Stop re-arm's 1800s constant, so it declined to insure the
# exact crash window the re-arm leaves open.

spool_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
spool_script_dir="$(cd "$spool_self_dir/../scripts" && pwd)"

_spool_run() {   # session_id, sentinel age in seconds ("" = no sentinel)
  local sid="$1" age="${2:-}"
  rm -rf "/tmp/vault-${sid}"
  if [[ -n "$age" ]]; then
    mkdir -p "/tmp/vault-${sid}"
    touch -d "@$(( $(date +%s) - age ))" "/tmp/vault-${sid}/last-actualize"
  fi
  local tp="/tmp/vault-spool-test-${sid}.jsonl"
  : > "$tp"
  jq -nc --arg sid "$sid" --arg tp "$tp" \
     '{session_id:$sid, cwd:"/x", hook_event_name:"SessionEnd", transcript_path:$tp}' \
    | "$spool_script_dir/spool-tail.sh" >/dev/null 2>&1
  [[ -f "$HOME/.claude/vault-spool/${sid}.json" ]] && echo spooled || echo skipped
  rm -f "$tp" "$HOME/.claude/vault-spool/${sid}.json"
  rm -rf "/tmp/vault-${sid}"
}

# --- C5: the spool covers the window the re-arm cannot ------------------------
got=$(_spool_run "spooltest-stale" 200)
assert_eq "spooled" "$got" "C5: a 200s-old sentinel still spools (re-arm has not fired yet)"

got=$(_spool_run "spooltest-fresh" 10)
assert_eq "skipped" "$got" "C5: a sweep that just finished is not spooled"

got=$(_spool_run "spooltest-none" "")
assert_eq "spooled" "$got" "C5: a session that never swept is always spooled"

# --- C5: the listing never drops tails silently -------------------------------
spool_dir="$HOME/.claude/vault-spool"
mkdir -p "$spool_dir"
tp="/tmp/vault-spool-listing-test.jsonl"; : > "$tp"
for i in 1 2 3 4 5 6 7 8; do
  jq -nc --arg sid "listtest-$i" --arg tp "$tp" \
     '{session_id:$sid, cwd:"/x", transcript_path:$tp, ended_at:"2026-08-30T00:00:00+03:00"}' \
     > "$spool_dir/zz-listtest-$i.json"
done
out=$(VAULT_ROOT="$(mktemp -d)" bash -c '
  source "'"$spool_script_dir"'/common.sh" 2>/dev/null || true
  vroot="'"$(mktemp -d)"'"
  '"$(sed -n '/^extra_notices()/,/^}/p' "$spool_script_dir/inject-context.sh")"'
  extra_notices
' 2>/dev/null)
assert_contains "and 3 more pending" "$out" "C5: 8 pending tails report the 3 not listed"
rm -f "$spool_dir"/zz-listtest-*.json "$tp"
