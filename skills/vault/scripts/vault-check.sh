#!/usr/bin/env bash
# vault-check.sh — is the vault ACTUALLY working? Exit 0 = green (prints nothing), 1 = red (one ⚠ line
# per violated invariant, in the same voice as the other SessionStart notices).
#
# Every invariant here is a failure that happened for real, silently, while every surface reported
# success (2026-09-14..16): nodes never committed, commits never pushed, a plugin release never deployed,
# a miner that was up but not mining. Each was found by a human doing forensics after asking "is it
# working?". This script is the answer to that question that does not need the forensics.
#
#   vault-check.sh            print reds, exit 1 if any
#   vault-check.sh --json     {ok, at, reds:[...]} on stdout, same exit code
#
# The green path touches NO network: a remote probe runs only when there is already something unpushed,
# because that is the moment "is it the network or the credential?" becomes the question.
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

vroot="$(vault_root)"
state="$(vault_state_dir)"
spool="$(spool_dir)"
plugins="${VAULT_PLUGINS_DIR:-$HOME/.claude/plugins}"
now=$(date +%s)

dirty_s="${VAULT_CHECK_DIRTY_SECONDS:-1800}"        # a sweep still writing is younger than this
push_grace_s="${VAULT_CHECK_PUSH_GRACE_SECONDS:-120}" # a push right after a commit may still be in flight
starved_s="${VAULT_CHECK_STARVED_SECONDS:-21600}"    # an ENDED tail unmined for 6h is a miner not mining
spool_max="${VAULT_CHECK_SPOOL_MAX:-30}"

reds=()
red() { reds+=("$1"); }

# --- 1. store clean: nothing dirty longer than a sweep takes ------------------------------------
# 2026-09-14: four nodes sat modified-on-disk for two days because the sweep that wrote them never
# named them to sync. A node that is dirty and OLD belongs to no live sweep — it is simply lost.
if [[ -d "$vroot/.git" ]]; then
  stale=0; oldest=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    m=$(stat -c %Y "$vroot/$f" 2>/dev/null || echo "$now")
    age=$(( now - m ))
    if (( age >= dirty_s )); then stale=$(( stale + 1 )); (( age > oldest )) && oldest=$age; fi
  done < <( { git -C "$vroot" diff --name-only; git -C "$vroot" ls-files --others --exclude-standard; } 2>/dev/null | sort -u )
  if (( stale > 0 )); then
    red "VAULT STORE has $stale node(s) modified on disk but never committed, oldest $(( oldest / 3600 ))h ago — a sweep wrote them and no sync staged them. \`git -C $vroot status\`; commit them with sync.sh naming the paths."
  fi

  # --- 2. store pushed: local history is on the remote --------------------------------------------
  # 2026-09-15/16: 22 commits accumulated for 23h with the remote reachable the whole time. Sync labelled
  # a rejected credential as OFFLINE and retried forever. When something IS unpushed, ask why — that is
  # the one moment the network cost is worth paying.
  branch=$(git -C "$vroot" symbolic-ref --short HEAD 2>/dev/null || echo main)
  if git -C "$vroot" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    ahead=$(git -C "$vroot" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)
    head_age=$(( now - $(git -C "$vroot" log -1 --format=%ct 2>/dev/null || echo "$now") ))
    if (( ahead > 0 && head_age >= push_grace_s )); then
      why="cause unknown"
      export GIT_TERMINAL_PROMPT=0
      export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes -oConnectTimeout=10}"
      if timeout 20 git -C "$vroot" ls-remote --exit-code origin >/dev/null 2>&1; then
        why="the remote IS reachable, so the push itself is failing — run sync.sh by hand and read its output"
      else
        url=$(git -C "$vroot" remote get-url origin 2>/dev/null || echo "")
        if [[ "$url" == *@*:* ]]; then
          host="${url#*@}"; host="${host%%:*}"
          if timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 -T "git@$host" 2>&1 | grep -qi 'permission denied'; then
            why="AUTH DENIED — no agent in this environment offers a key the remote accepts (\`ssh-add -l\`); this will NOT fix itself"
          else
            why="remote unreachable (network) — will retry, but the backlog only grows until it is"
          fi
        else
          why="remote unreachable"
        fi
      fi
      red "VAULT STORE has $ahead commit(s) not on origin (newest $(( head_age / 60 ))m old): $why."
    fi
  fi
fi

# --- 3. deployed == source: the plugin sessions load is the code in the repo ----------------------
# 2026-09-14: the repo said 1.8.0, sessions ran 1.7.0's scripts, and had for four days — the whole
# miner release never reached a session. Only checkable for a directory-sourced marketplace, where the
# source of truth is on this disk; a GitHub source would need the network to answer.
km="$plugins/known_marketplaces.json"; ip="$plugins/installed_plugins.json"
if [[ -f "$km" && -f "$ip" ]]; then
  src=$(jq -r '.["claude-vault"] | select(.source.source=="directory") | .source.path // ""' "$km" 2>/dev/null)
  if [[ -n "$src" && -f "$src/.claude-plugin/plugin.json" ]]; then
    want=$(jq -r '.version // ""' "$src/.claude-plugin/plugin.json" 2>/dev/null)
    have=$(jq -r '.plugins["vault@claude-vault"][0].version // ""' "$ip" 2>/dev/null)
    if [[ -n "$want" && "$want" != "$have" ]]; then
      red "VAULT PLUGIN is deployed at ${have:-none} but the repo is at $want — sessions are running OLD scripts. \`claude plugin update vault@claude-vault\`, then restart sessions."
    fi
  fi
fi

# --- 4. miner productive: up is not the same as mining ---------------------------------------------
# miner_notice (inject-context.sh) already covers DOWN. This covers UP-BUT-STARVED: an ENDED session's
# tail, not given up on, with no mined marker, sitting for hours. A live session may legitimately sit
# unmined (its tail is below the floor); an ended one may not.
if miner_alive && [[ -d "$spool" ]]; then
  max_attempts="${VAULT_SPOOL_DRAIN_MAX_ATTEMPTS:-3}"
  starved=0; count=0
  for f in "$spool"/*.json; do
    [[ -e "$f" ]] || break
    count=$(( count + 1 ))
    [[ "$(jq -r '.live // false' "$f" 2>/dev/null)" == "false" ]] || continue
    (( $(jq -r '.drain_attempts // 0' "$f" 2>/dev/null) < max_attempts )) || continue
    sid=$(jq -r '.session_id // ""' "$f" 2>/dev/null)
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo "$now") ))
    (( age >= starved_s )) || continue
    mined=$(jq -r --arg s "$sid" '.sessions[$s].mined_at // ""' "$state/miner.json" 2>/dev/null)
    [[ -z "$mined" ]] && starved=$(( starved + 1 ))
  done
  if (( starved > 0 )); then
    red "VAULT MINER is up but has not mined $starved ended session(s) older than $(( starved_s / 3600 ))h — read $state/hook-events.log (Miner rows) for why it keeps skipping them."
  fi
  if (( count > spool_max )); then
    red "VAULT SPOOL holds $count records (ceiling $spool_max) — the miner is falling behind or records are not being cleared."
  fi
fi

# --- 5. the last sync outcome was a refusal ---------------------------------------------------------
# REFUSED means NOTHING was committed and the sweep is sitting on disk; AUTH-DENIED means it will
# never push. Both are permanent until a human acts, and both were previously one log line nobody read.
if [[ -f "$state/sync.log" ]]; then
  last=$(tail -1 "$state/sync.log" 2>/dev/null | cut -f3)
  case "$last" in
    REFUSED*|AUTH-DENIED*)
      red "VAULT SYNC last outcome: $last — the most recent sweep did not reach the remote (tail -5 $state/sync.log)." ;;
  esac
fi

# --- report ------------------------------------------------------------------------------------------
if [[ "${1:-}" == "--json" ]]; then
  printf '%s\n' "${reds[@]}" | jq -R . | jq -s --arg at "$(date -Is)" --argjson ok "$(( ${#reds[@]} == 0 ))" \
    '{ok: ($ok == 1), at: $at, reds: (map(select(length > 0)))}'
else
  for r in "${reds[@]}"; do printf '\n⚠ %s\n' "$r"; done
fi
(( ${#reds[@]} == 0 ))
