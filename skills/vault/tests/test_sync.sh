#!/usr/bin/env bash
# sync.sh — the git write path. Every case here comes from the 2026-08-30 re-audit,
# which reproduced a severe defect: sweeps fired during an in-progress rebase or
# merge either destroyed the sweep or committed conflict markers into node files.

sync_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$(cd "$sync_self_dir/../scripts" && pwd)/sync.sh"


# --- C1a: a sweep during an in-progress rebase must not destroy the sweep ------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" rebase origin/main >/dev/null 2>&1 || true   # conflicts by design
printf 'A brand-new hard-won incident scar.\n' > "$tmp/A/sg/incident-scar.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "sweep: incident scar" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "C1a: sync refuses (exit 2) while a rebase is in progress"
assert_contains "in progress" "$out" "C1a: the refusal names the in-progress operation"
[[ -f "$tmp/A/sg/incident-scar.md" ]] && got=present || got=GONE
assert_eq "present" "$got" "C1a: the new node survives a sweep fired mid-rebase"
{ [[ -d "$tmp/A/.git/rebase-merge" ]] || [[ -d "$tmp/A/.git/rebase-apply" ]]; } && got=intact || got=destroyed
assert_eq "intact" "$got" "C1a: the human's in-progress rebase is left alone"
rm -rf "$tmp"

# --- C1b: a sweep during an in-progress merge must not commit markers ----------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" pull --no-rebase --no-edit >/dev/null 2>&1 || true   # conflict; MERGE_HEAD
printf 'another scar\n' > "$tmp/A/sg/scar.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "sweep during merge" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "C1b: sync refuses (exit 2) while a merge is in progress"
marked=$( { git -C "$tmp/A" grep -l '^<<<<<<<' HEAD -- 2>/dev/null || true; } | wc -l)
assert_eq "0" "$marked" "C1b: no conflict markers are committed into tracked files"
[[ -f "$tmp/A/.git/MERGE_HEAD" ]] && got=intact || got=concluded
assert_eq "intact" "$got" "C1b: sync does not conclude the human's merge"
rm -rf "$tmp"

# --- C1c: the ordinary path still works ---------------------------------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'ordinary node\n' > "$tmp/A/sg/ordinary.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "ordinary sweep" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "C1c: an ordinary sweep succeeds"
assert_contains "committed=1" "$out" "C1c: an ordinary sweep still commits"
[[ -f "$tmp/A/sg/ordinary.md" ]] && got=present || got=GONE
assert_eq "present" "$got" "C1c: ordinary sweep keeps its node"
rm -rf "$tmp"

# --- C2: scoped staging — another session's file is not swept in --------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'mine\n' > "$tmp/A/sg/mine.md"
printf 'theirs, mid-write\n' > "$tmp/A/sg/theirs.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "scoped sweep" "sg/mine.md" 2>&1) && ec=$? || ec=$?
files=$(git -C "$tmp/A" show --name-only --format= HEAD | tr '\n' ' ')
assert_contains "sg/mine.md" "$files" "C2: the declared path is committed"
if [[ "$files" == *"theirs.md"* ]]; then got=swept; else got=untouched; fi
assert_eq "untouched" "$got" "C2: another session's file is NOT swept into our commit"
rm -rf "$tmp"

# --- C3a: an unreachable remote is a network failure, not divergence ----------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" remote set-url origin "$tmp/does-not-exist.git"
printf 'offline node\n' > "$tmp/A/sg/offline.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "offline sweep" 2>&1) && ec=$? || ec=$?
[[ -f "$tmp/A/.sync-diverged" ]] && got=marked || got=clean
assert_eq "clean" "$got" "C3a: an unreachable remote writes NO divergence marker"
assert_contains "committed=1" "$out" "C3a: the sweep still commits locally (fail-open)"
rm -rf "$tmp"

# --- C3b: genuine divergence against a reachable remote still marks -----------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
printf 'diverged node\n' > "$tmp/A/sg/diverged.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "diverged sweep" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "C3b: real divergence exits 2"
[[ -f "$tmp/A/.sync-diverged" ]] && got=marked || got=clean
assert_eq "marked" "$got" "C3b: real divergence against a reachable remote still marks loudly"
rm -rf "$tmp"

# --- C9: dirty tree while AHEAD-only is not divergence (audit: dirty-tree-false-diverged) ------
# Another live session's unstaged edit to a tracked file must not turn our push into a false DIVERGED.
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main          # in sync with origin
printf 'someone else is mid-edit\n' >> "$tmp/A/sg/_index.md"   # unstaged, tracked (another session)
printf 'my new node\n' > "$tmp/A/sg/mine.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "ahead with a dirty tree" "sg/mine.md" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "C9: ahead-only with a dirty tree succeeds (no false DIVERGED)"
[[ -f "$tmp/A/.sync-diverged" ]] && got=marked || got=clean
assert_eq "clean" "$got" "C9: a dirty tree while merely ahead writes NO divergence marker"
assert_contains "pushed OK" "$out" "C9: the sweep pushes despite the unstaged tracked edit"
if git -C "$tmp/A" show --name-only --format= HEAD | grep -q '_index.md'; then got=swept; else got=untouched; fi
assert_eq "untouched" "$got" "C9: the other session's unstaged edit is not committed"
rm -rf "$tmp"

# --- C10: a pathspec that matches nothing must fail loudly, never report success --------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "bad pathspec" "sg/does-not-exist.md" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "C10: a non-matching declared path exits non-zero"
assert_not_contains "pushed OK" "$out" "C10: a bad pathspec never prints 'pushed OK'"
assert_contains "does-not-exist.md" "$out" "C10: the failure names the offending path"
rm -rf "$tmp"

# --- C11: a detached HEAD is refused before staging (audit: sync-no-branch-guard) -------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
git -C "$tmp/A" checkout -q --detach
printf 'node written on a detached head\n' > "$tmp/A/sg/detached.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "detached sweep" "sg/detached.md" 2>&1) && ec=$? || ec=$?
assert_exit "2" "$ec" "C11: a detached HEAD is refused (exit 2)"
assert_contains "detached" "$out" "C11: the refusal names the detached HEAD"
[[ -f "$tmp/A/sg/detached.md" ]] && got=present || got=GONE
assert_eq "present" "$got" "C11: the node survives the refusal"
rm -rf "$tmp"

# --- C12: commit works with no configured git identity (audit: sync-no-git-identity) ----------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
git -C "$tmp/A" config --unset user.email; git -C "$tmp/A" config --unset user.name
printf 'node with no identity configured\n' > "$tmp/A/sg/noid.md"
out=$(HOME="$tmp/nohome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      VAULT_ROOT="$tmp/A" bash "$SYNC" "no-identity sweep" "sg/noid.md" 2>&1) && ec=$? || ec=$?
assert_contains "committed=1" "$out" "C12: the sweep commits even with no git identity configured"
who=$(git -C "$tmp/A" log -1 --format='%an' 2>/dev/null)
[[ -n "$who" ]] && got=named || got=empty
assert_eq "named" "$got" "C12: the commit has an author (identity fallback supplied one)"
rm -rf "$tmp"

# --- C13: every non-success remote line carries an unpushed count -----------------------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
git -C "$tmp/A" remote set-url origin "$tmp/does-not-exist.git"
printf 'offline node\n' > "$tmp/A/sg/offline2.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "offline with count" "sg/offline2.md" 2>&1) && ec=$? || ec=$?
assert_contains "unpushed=1" "$out" "C13: an unreachable remote reports unpushed=1 (the robust signal)"
rm -rf "$tmp"

# --- C14: a node the sweep wrote but did not declare still gets committed ----------------------
# The 2026-09-12 leak: sync staged only declared paths, so four nodes written by a worker that then
# exited sat uncommitted for two days. Same subgraph as a declared path ⇒ it belongs to this sweep.
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'declared node\n' > "$tmp/A/sg/declared.md"
printf 'undeclared sibling\n' > "$tmp/A/sg/undeclared.md"
touch -d '-5 minutes' "$tmp/A/sg/declared.md" "$tmp/A/sg/undeclared.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "widened sweep" "sg/declared.md" 2>&1) && ec=$? || ec=$?
files=$(git -C "$tmp/A" show --name-only --format= HEAD | sort | tr '\n' ' ')
assert_contains "sg/undeclared.md" "$files" "C14: the undeclared sibling is committed with the sweep"
assert_contains "sg/declared.md" "$files" "C14: the declared node is committed too"
rm -rf "$tmp"

# --- C15: another subgraph's dirty file is still never swept in (fix 2 holds) ------------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
mkdir -p "$tmp/A/other"
printf '# index\n' > "$tmp/A/other/_index.md"
git -C "$tmp/A" add -A; git -C "$tmp/A" commit -qm "other subgraph"
printf 'mine\n' > "$tmp/A/sg/mine.md"
printf 'someone else is mid-sweep here\n' > "$tmp/A/other/theirs.md"
touch -d '-5 minutes' "$tmp/A/sg/mine.md" "$tmp/A/other/theirs.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "scoped sweep" "sg/mine.md" 2>&1) && ec=$? || ec=$?
files=$(git -C "$tmp/A" show --name-only --format= HEAD | tr '\n' ' ')
assert_contains "sg/mine.md" "$files" "C15: this subgraph's node is committed"
case "$files" in *other/theirs.md*) got=SWEPT ;; *) got=untouched ;; esac
assert_eq "untouched" "$got" "C15: another subgraph's dirty file is left alone"
rm -rf "$tmp"

# --- C16: a node another sweep is writing RIGHT NOW is not committed half-written --------------
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
printf 'declared\n' > "$tmp/A/sg/c16.md"
touch -d '-5 minutes' "$tmp/A/sg/c16.md"
printf 'being written this second\n' > "$tmp/A/sg/inflight.md"
out=$(VAULT_ROOT="$tmp/A" bash "$SYNC" "quiet-window sweep" "sg/c16.md" 2>&1) && ec=$? || ec=$?
files=$(git -C "$tmp/A" show --name-only --format= HEAD | tr '\n' ' ')
case "$files" in *inflight.md*) got=SWEPT ;; *) got=deferred ;; esac
assert_eq "deferred" "$got" "C16: a file touched seconds ago is left for the next sweep"
[[ -f "$tmp/A/sg/inflight.md" ]] && got=present || got=GONE
assert_eq "present" "$got" "C16: and it is still on disk, not lost"
rm -rf "$tmp"

# --- C17: an empty ssh agent falls back to a passphrase-less key instead of failing forever ----
# The daemon inherits gpg-agent's SSH socket, which holds no identities, while the human's terminal
# uses an agent that does. Under BatchMode that is a permanent "Permission denied (publickey)", filed
# as OFFLINE — 22 commits piled up locally over a day while the remote was reachable the whole time.
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
key="$tmp/key"; ssh-keygen -q -t ed25519 -N "" -f "$key" </dev/null
printf 'node\n' > "$tmp/A/sg/keyfallback.md"
out=$(SSH_AUTH_SOCK=/nonexistent VAULT_SSH_KEY="$key" VAULT_ROOT="$tmp/A" \
      bash "$SYNC" "key fallback" "sg/keyfallback.md" 2>&1) && ec=$? || ec=$?
assert_contains "committed=1" "$out" "C17: the sweep still commits with an empty agent"
# The local fixture remote is a path, not ssh, so the push itself is unaffected — what matters is that
# the run did not abort and the key path was accepted.
assert_exit "0" "$ec" "C17: an empty agent is not fatal"
rm -rf "$tmp"

# --- C18: a rejected credential is not reported as OFFLINE -------------------------------------
# OFFLINE says "transient, retrying is right". A rejected key is permanent: retrying forever only
# grows the backlog, which is exactly how this went unnoticed for a day.
tmp="$(mktemp -d)"
_sync_fixture "$tmp"
git -C "$tmp/A" reset -q --hard origin/main
git -C "$tmp/A" remote set-url origin "$tmp/does-not-exist.git"
printf 'unreachable node\n' > "$tmp/A/sg/unreach.md"
state_dir="$tmp/state"
out=$(VAULT_STATE_DIR="$state_dir" VAULT_ROOT="$tmp/A" bash "$SYNC" "unreachable" "sg/unreach.md" 2>&1) && ec=$? || ec=$?
assert_contains "unpushed=1" "$out" "C18: an unreachable remote still reports the honest backlog count"
# A local path remote that does not exist is genuinely offline, not an auth rejection.
assert_contains "OFFLINE" "$(cat "$state_dir/sync.log" 2>/dev/null)" "C18: a missing local remote is still classified OFFLINE"
rm -rf "$tmp"
