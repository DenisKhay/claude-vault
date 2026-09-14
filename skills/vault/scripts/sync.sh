#!/usr/bin/env bash
# sync.sh — the vault's write-side git contract. Run at the END of every capture
# sweep (the skill instructs it). Turns store durability from operator habit into
# machinery: the audit found 13 commits ever, a 73-day gap, and a 22h uncommitted
# window observed live.
#
# Flow: refuse-if-inflight → branch guard → secret scan → stage (declared paths) →
#       commit → FETCH → compare HEAD vs origin/<branch> → push (ahead) /
#       rebase-then-push (behind, clean tree) / defer (behind, dirty tree) /
#       DIVERGED (real conflict). flock-serialized against the SessionStart pull.
#
# Conflict policy is LOUD-DUMB by design (multi-machine research 2026-08-30):
# never auto-merge — on a genuine rebase conflict, abort, restore the local commit,
# write the .sync-diverged marker (surfaced at every SessionStart), exit 2.
# Network/auth failure is fail-open: the commit stands locally and every non-success
# remote line carries unpushed=N (the count is the robust signal — an auth failure
# and a dead network print the same words, so the number, not the words, is trusted).
#
# Usage: sync.sh ["commit message"] [path ...]
#
# Defects prevented (2026-08-30 re-audit + 2026-09-08 audit III):
#  1. SEVERE — a sweep during a human's rebase/merge destroyed the sweep or committed
#     conflict markers. Now: refuse before touching the index if any op is in flight.
#  2. `git add -A` swept in OTHER live sessions' files. Now: stage only declared paths.
#  3. Network/auth failure was reported as DIVERGED. Now: divergence is claimed only
#     after a successful FETCH shows the branches genuinely conflict on a clean tree.
#  4. DIRTY-TREE FALSE DIVERGED (audit III, high) — `git pull --rebase` refused before
#     fetching whenever another session had an unstaged tracked edit, and that refusal
#     was mislabelled DIVERGED. Both live DIVERGEDs were this. Now: fetch first; when
#     merely AHEAD, push without rebasing (a dirty tree never blocks a push); when
#     BEHIND with a dirty tree, defer (fail-open) rather than touch another session's
#     files; rebase only a clean tree, and only a real rebase conflict marks DIVERGED.
#  5. BAD PATHSPEC SILENT SUCCESS (audit III, regression) — a declared path that
#     matched nothing left `git add` failing under `2>/dev/null`, nothing staged, and
#     the run still printed "pushed OK". Now: a failed stage exits 2 naming the path.
#  6. NO BRANCH GUARD (audit III) — a detached HEAD or a committed-off-branch sweep
#     misreported forever. Now: refuse a detached HEAD before staging.
#  7. NO GIT IDENTITY (audit III, cold start) — an empty HOME made the commit fail and
#     left the sweep staged. Now: a `-c user.name/email=vault@<host>` fallback commits.

set -uo pipefail

VROOT="${VAULT_ROOT:-$HOME/Vaults}"
HOST="$(hostname -s 2>/dev/null || echo host)"
MSG="${1:-vault: capture sweep $(date +%F) [$HOST]}"
shift 2>/dev/null || true
PATHS=("$@")

# Never hang a hook on a credential or host-key prompt.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes -oConnectTimeout=10}"

[[ -d "$VROOT/.git" ]] || { echo "sync.sh: $VROOT is not a git repo — nothing to sync"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "sync.sh: git not found"; exit 0; }

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
[[ -f "$self_dir/common.sh" ]] && source "$self_dir/common.sh"

# Durable one-line trail per outcome (audit III: sync wrote no on-disk row for any
# result, so a lying "pushed OK" left nothing to contradict it after the fact).
slog() {
  local dir
  if declare -f vault_state_dir >/dev/null 2>&1; then dir="$(vault_state_dir)"; else dir="$HOME/.claude/vault-state"; fi
  mkdir -p "$dir" 2>/dev/null && printf '%s\t%s\t%s\n' "$(date -Is 2>/dev/null || date)" "$HOST" "$1" >> "$dir/sync.log" 2>/dev/null || true
}

if declare -f vault_git_lock >/dev/null 2>&1; then
  LOCKFILE="$(vault_git_lock "$VROOT")"
else
  LOCKFILE="/tmp/vault-git-$(printf '%s' "$VROOT" | md5sum 2>/dev/null | cut -c1-12).lock"
fi
exec 9>"$LOCKFILE"
flock -w 30 9 || { echo "sync.sh: could not take the vault git lock (another sync running?)"; exit 1; }

cd "$VROOT" || exit 1

# --- Refuse while any git operation is in flight -------------------------------
inflight=""
[[ -d .git/rebase-merge || -d .git/rebase-apply ]] && inflight="a rebase"
git rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1 && inflight="a merge"
git rev-parse --verify -q CHERRY_PICK_HEAD >/dev/null 2>&1 && inflight="a cherry-pick"
git rev-parse --verify -q REVERT_HEAD >/dev/null 2>&1 && inflight="a revert"
if [[ -n "$inflight" ]]; then
  echo "sync.sh: ⚠ REFUSING — $inflight is in progress in $VROOT."
  echo "sync.sh: the sweep is NOT committed and nothing was staged; your files are untouched on disk."
  echo "sync.sh: finish or abort that operation by hand, then re-run the sweep."
  slog "REFUSED inflight=$inflight"
  exit 2
fi

# --- Branch guard (audit III: sync-no-branch-guard) ----------------------------
# A commit on a detached HEAD is orphaned the moment HEAD moves, and every later
# fetch/rebase compares against the wrong ref. Refuse before staging so the node
# stays on disk for a human to place on a real branch.
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
if [[ -z "$branch" ]]; then
  echo "sync.sh: ⚠ REFUSING — $VROOT is on a detached HEAD, not a branch."
  echo "sync.sh: nothing was staged or committed; your sweep is untouched on disk."
  echo "sync.sh: check out the store's branch (e.g. \`git -C $VROOT checkout main\`), then re-run."
  slog "REFUSED detached-head"
  exit 2
fi

# --- Credential guard (locked decision D6) ------------------------------------
# Scanned BEFORE staging, so a refusal leaves the index exactly as it was found.
if [[ -x "$self_dir/secret-scan.sh" || -f "$self_dir/secret-scan.sh" ]]; then
  if (( ${#PATHS[@]} )); then
    candidates=("${PATHS[@]}")
  else
    mapfile -t candidates < <( { git diff --name-only HEAD -- 2>/dev/null; \
                                 git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
  fi
  if (( ${#candidates[@]} )); then
    if ! scan_out=$(bash "$self_dir/secret-scan.sh" "${candidates[@]}" 2>&1); then
      echo "sync.sh: ⚠ REFUSING — the sweep carries what looks like a credential."
      printf '%s\n' "$scan_out"
      echo "sync.sh: nothing was staged or committed; your files are untouched on disk."
      slog "REFUSED secret-scan"
      exit 2
    fi
  fi
fi

# --- Stage (declared paths, widened to their subgraph; never the whole vault) --
# Declared-paths-only (fix 2, 2026-08-30) stopped a sweep from committing OTHER sessions' files, and in
# doing so created the opposite leak: a node the agent wrote but did not name was staged by nobody, and
# once that worker exited nothing ever committed it. Four care-space-assistant nodes sat uncommitted from
# 2026-09-12 to 09-14 that way — on disk, absent from origin, reported as success everywhere. So widen
# each declared path to its SUBGRAPH (nearest ancestor holding _index.md) and stage what is dirty there.
# A different subgraph is still untouchable, which is the property fix 2 was protecting.
STAGE_QUIET_S="${VAULT_SYNC_QUIET_SECONDS:-30}"

subgraph_root() {   # path → nearest ancestor dir holding _index.md, or nothing
  local d="$1"
  [[ -d "$d" ]] || d="$(dirname "$d")"
  while [[ -n "$d" && "$d" != "." && "$d" != "/" ]]; do
    [[ -f "$d/_index.md" ]] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

if (( ${#PATHS[@]} )); then
  if ! add_err="$(git add -- "${PATHS[@]}" 2>&1)"; then
    echo "sync.sh: ⚠ REFUSING — a declared path did not match anything in $VROOT:"
    printf '%s\n' "$add_err"
    echo "sync.sh: nothing was committed; your files are untouched on disk."
    slog "REFUSED bad-pathspec"
    exit 2
  fi
  declare -A _roots=()
  for _p in "${PATHS[@]}"; do
    if _r="$(subgraph_root "$_p")"; then _roots["$_r"]=1; fi
  done
  _now=$(date +%s)
  _widened=()
  for _r in "${!_roots[@]}"; do
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      # A deletion is never swept in on someone else's behalf — removing knowledge is a deliberate act.
      [[ -f "$_f" ]] || continue
      # A file touched in the last few seconds belongs to a sweep still writing it; staging it here would
      # commit half a node. It is not lost — the next sweep in that subgraph picks it up.
      _m=$(stat -c %Y "$_f" 2>/dev/null || echo 0)
      (( _now - _m < STAGE_QUIET_S )) && continue
      _widened+=("$_f")
    done < <( { git diff --name-only -- "$_r"; git ls-files --others --exclude-standard -- "$_r"; } | sort -u )
  done
  if (( ${#_widened[@]} )); then
    git add -- "${_widened[@]}" 2>/dev/null
    slog "WIDENED files=${#_widened[@]} subgraphs=${#_roots[@]}"
  fi
else
  git add -A 2>/dev/null
fi

# The divergence marker is local operator state, never store content.
git reset -q -- .sync-diverged 2>/dev/null

# --- Commit (with a git-identity fallback for a bare HOME) ---------------------
idargs=()
if ! git config user.email >/dev/null 2>&1 || ! git config user.name >/dev/null 2>&1; then
  idargs=(-c "user.name=vault" -c "user.email=vault@${HOST}")
fi
if ! git diff --cached --quiet 2>/dev/null; then
  if ! git ${idargs[@]+"${idargs[@]}"} commit -q -m "$MSG"; then
    echo "sync.sh: COMMIT FAILED — sweep output is UNCOMMITTED in $VROOT"
    slog "COMMIT-FAILED"
    exit 2
  fi
  committed=1
else
  committed=0
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "sync.sh: committed=$committed, no remote configured — local only"
  slog "LOCAL-ONLY committed=$committed no-remote"
  exit 0
fi

# Commits on HEAD not yet on the remote-tracking ref — the count is the honest
# signal on every non-success line below.
unpushed() { git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo '?'; }

# --- FETCH first: an exit code is not a verdict; the compared refs are ----------
if ! git fetch --quiet origin "$branch" 2>/dev/null; then
  # A failed fetch is a dead network OR a bad credential — indistinguishable by
  # message (DNS failures also say "Permission denied"), so classify best-effort
  # and let unpushed=N be authoritative.
  cls="network/auth"
  if git ls-remote --exit-code origin >/dev/null 2>&1; then cls="fetch failed but remote is reachable"; fi
  echo "sync.sh: committed=$committed, remote unreachable ($cls) — local only, unpushed=$(unpushed), retries next sweep"
  slog "OFFLINE committed=$committed unpushed=$(unpushed) $cls"
  exit 0
fi

# origin/$branch may not exist yet (first push of a new branch).
if ! git rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
  if git push --quiet -u origin "$branch" 2>/dev/null; then
    rm -f "$VROOT/.sync-diverged" 2>/dev/null
    echo "sync.sh: committed=$committed, pushed OK (new branch origin/$branch)"
    slog "PUSHED-NEW committed=$committed branch=$branch"
  else
    echo "sync.sh: committed=$committed, push FAILED (network?) — unpushed=$(git rev-list --count HEAD 2>/dev/null || echo '?'), retries next sweep"
    slog "PUSH-FAILED-NEW committed=$committed"
  fi
  exit 0
fi

behind="$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"

do_push() {
  if git push --quiet origin "$branch" 2>/dev/null; then
    rm -f "$VROOT/.sync-diverged" 2>/dev/null
    echo "sync.sh: committed=$committed, ${1:-in sync with origin}, pushed OK"
    slog "PUSHED committed=$committed ahead=$ahead behind=$behind"
    return 0
  fi
  # A rejected push means the remote moved between our fetch and our push — a race,
  # not divergence. Leave the commit; the next sweep re-fetches and integrates.
  echo "sync.sh: committed=$committed, push FAILED (remote moved or network?) — unpushed=$(unpushed), retries next sweep"
  slog "PUSH-FAILED committed=$committed unpushed=$(unpushed)"
  return 0
}

if (( behind == 0 )); then
  rm -f "$VROOT/.sync-diverged" 2>/dev/null
  if (( ahead > 0 )); then
    do_push "ahead $ahead"
  else
    echo "sync.sh: committed=$committed, already in sync with origin/$branch — nothing to push"
    slog "IN-SYNC committed=$committed"
  fi
  exit 0
fi

# behind>0: the remote has commits we lack. Integrating means moving the working
# tree, which git refuses (and must, per C2) while another session has unstaged
# edits. Defer rather than stash/clobber their work.
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  echo "sync.sh: committed=$committed, behind origin by $behind but the tree is busy (another session is writing) — local only, unpushed=$ahead, integrate next sweep"
  slog "DEFERRED-DIRTY committed=$committed behind=$behind unpushed=$ahead"
  exit 0
fi

# Clean tree + behind: rebase our commits onto the remote. Only a real content
# conflict here is DIVERGED.
if git rebase --quiet "origin/$branch" 2>/dev/null; then
  ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  do_push "rebased on origin"
  exit 0
fi
[[ -d .git/rebase-merge || -d .git/rebase-apply ]] && git rebase --abort 2>/dev/null
touch "$VROOT/.sync-diverged" 2>/dev/null
echo "sync.sh: ⚠ DIVERGED — local sweep is committed but rebase onto origin/$branch conflicts."
echo "sync.sh: NOT auto-merging (an LLM reads this store; silent bad merges become its context)."
echo "sync.sh: resolve by hand in $VROOT, push, then: rm $VROOT/.sync-diverged"
slog "DIVERGED committed=$committed behind=$behind ahead=$ahead"
exit 2
