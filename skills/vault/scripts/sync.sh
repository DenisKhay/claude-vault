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
# Usage: sync.sh ["commit message"]

set -uo pipefail

VROOT="${VAULT_ROOT:-$HOME/Vaults}"
MSG="${1:-vault: capture sweep $(date +%F) [$(hostname -s 2>/dev/null || echo host)]}"

[[ -d "$VROOT/.git" ]] || { echo "sync.sh: $VROOT is not a git repo — nothing to sync"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "sync.sh: git not found"; exit 0; }

exec 9>/tmp/vault-git.lock
flock -w 30 9 || { echo "sync.sh: could not take the vault git lock (another sync running?)"; exit 1; }

cd "$VROOT" || exit 1

git add -A 2>/dev/null
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
  git rebase --abort 2>/dev/null
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
