#!/usr/bin/env bash
# sync.sh — the vault's write-side git contract. Run at the END of every capture
# sweep (the skill instructs it). Turns store durability from operator habit into
# machinery: the audit found 13 commits ever, a 73-day gap, and a 22h uncommitted
# window observed live.
#
# Flow: stage → commit (if anything) → pull --rebase (linear, no merge commits)
#       → push. flock-serialized against the SessionStart background pull.
#
# Conflict policy is LOUD-DUMB by design (multi-machine research 2026-08-30):
# never auto-merge — on rebase conflict, abort, restore the local commit, write
# the .sync-diverged marker (surfaced at every SessionStart), print loudly, exit 2.
# Network failure is fail-open: commit stands locally, push retries next sweep.
#
# Usage: sync.sh ["commit message"] [path ...]
#
# Three defects the 2026-08-30 re-audit reproduced, and what now prevents them:
#  1. SEVERE — an unguarded `git add -A` + commit fired during a human's rebase or
#     merge either destroyed the sweep (the unconditional `rebase --abort` discarded
#     the commit and deleted the node) or CONCLUDED the merge, committing conflict
#     markers into node files that the next SessionStart feeds to an LLM as prose.
#     Now: refuse before touching the index whenever any git operation is in flight.
#  2. `git add -A` staged whatever OTHER live sessions had written, so a sweep's
#     removed-lines certification covered files it never opened. Now: stage only the
#     paths the caller declares; -A is the explicit no-args fallback.
#  3. Network/auth failure was reported as DIVERGED — the marker got committed and
#     would make every fresh clone boot permanently diverged. Now: divergence is
#     claimed only when the remote is reachable AND the rebase genuinely conflicts.

set -uo pipefail

VROOT="${VAULT_ROOT:-$HOME/Vaults}"
MSG="${1:-vault: capture sweep $(date +%F) [$(hostname -s 2>/dev/null || echo host)]}"
shift 2>/dev/null || true
PATHS=("$@")

# Never hang a hook on a credential or host-key prompt.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes -oConnectTimeout=10}"

[[ -d "$VROOT/.git" ]] || { echo "sync.sh: $VROOT is not a git repo — nothing to sync"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "sync.sh: git not found"; exit 0; }

exec 9>/tmp/vault-git.lock
flock -w 30 9 || { echo "sync.sh: could not take the vault git lock (another sync running?)"; exit 1; }

cd "$VROOT" || exit 1

# --- Refuse while any git operation is in flight -------------------------------
# Staging here would either be discarded by the abort below or would mark the
# human's conflicts resolved and commit the markers. Neither is recoverable from
# anything but the reflog, and both present as success. Reachable on ONE machine:
# an abandoned `git rebase -i` is enough, because `git pull --rebase` then fails
# merely because a rebase directory exists.
inflight=""
[[ -d .git/rebase-merge || -d .git/rebase-apply ]] && inflight="a rebase"
git rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1 && inflight="a merge"
git rev-parse --verify -q CHERRY_PICK_HEAD >/dev/null 2>&1 && inflight="a cherry-pick"
git rev-parse --verify -q REVERT_HEAD >/dev/null 2>&1 && inflight="a revert"
if [[ -n "$inflight" ]]; then
  echo "sync.sh: ⚠ REFUSING — $inflight is in progress in $VROOT."
  echo "sync.sh: the sweep is NOT committed and nothing was staged; your files are untouched on disk."
  echo "sync.sh: finish or abort that operation by hand, then re-run the sweep."
  exit 2
fi

# --- Credential guard (locked decision D6) ------------------------------------
# Scanned BEFORE staging, so a refusal leaves the index exactly as it was found.
# Auto-push means an accidentally captured token reaches a remote — permanently,
# in history — within seconds of being written, with no human in the loop.
scan_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$scan_self_dir/secret-scan.sh" || -f "$scan_self_dir/secret-scan.sh" ]]; then
  if (( ${#PATHS[@]} )); then
    candidates=("${PATHS[@]}")
  else
    mapfile -t candidates < <( { git diff --name-only HEAD -- 2>/dev/null; \
                                 git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
  fi
  if (( ${#candidates[@]} )); then
    if ! scan_out=$(bash "$scan_self_dir/secret-scan.sh" "${candidates[@]}" 2>&1); then
      echo "sync.sh: ⚠ REFUSING — the sweep carries what looks like a credential."
      printf '%s\n' "$scan_out"
      echo "sync.sh: nothing was staged or committed; your files are untouched on disk."
      exit 2
    fi
  fi
fi

if (( ${#PATHS[@]} )); then
  git add -- "${PATHS[@]}" 2>/dev/null
else
  git add -A 2>/dev/null
fi
# The divergence marker is local operator state, never store content.
git reset -q -- .sync-diverged 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -q -m "$MSG" || { echo "sync.sh: COMMIT FAILED — sweep output is UNCOMMITTED in $VROOT"; exit 2; }
  committed=1
else
  committed=0
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "sync.sh: committed=$committed, no remote configured — local only"
  exit 0
fi

if ! git pull --rebase --quiet 2>/dev/null; then
  # A failed pull is not evidence of divergence: an unreachable remote, a dead
  # network or an expired credential fails identically. Claiming DIVERGED there
  # writes a marker that gets committed and makes every future clone boot into a
  # false alarm — poisoning the one channel the loud-stop policy depends on.
  if ! git ls-remote --exit-code origin >/dev/null 2>&1; then
    # Any rebase this pull started is ours to clean up; a pre-existing one was
    # refused above, so this can never abort the human's work.
    [[ -d .git/rebase-merge || -d .git/rebase-apply ]] && git rebase --abort 2>/dev/null
    echo "sync.sh: committed=$committed, remote unreachable (network/auth) — local only, retries next sweep"
    exit 0
  fi
  [[ -d .git/rebase-merge || -d .git/rebase-apply ]] && git rebase --abort 2>/dev/null
  touch "$VROOT/.sync-diverged" 2>/dev/null
  echo "sync.sh: ⚠ DIVERGED — local sweep is committed but remote does not fast-forward/rebase cleanly."
  echo "sync.sh: NOT auto-merging (an LLM reads this store; silent bad merges become its context)."
  echo "sync.sh: resolve by hand in $VROOT, push, then: rm $VROOT/.sync-diverged"
  exit 2
fi
rm -f "$VROOT/.sync-diverged" 2>/dev/null

if git push --quiet 2>/dev/null; then
  echo "sync.sh: committed=$committed, rebased on origin, pushed OK"
else
  echo "sync.sh: committed=$committed, push FAILED (network?) — will retry on the next sweep"
fi
exit 0
