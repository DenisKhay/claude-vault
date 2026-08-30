#!/usr/bin/env bash
# sync.sh — the git write path. Every case here comes from the 2026-08-30 re-audit,
# which reproduced a severe defect: sweeps fired during an in-progress rebase or
# merge either destroyed the sweep or committed conflict markers into node files.

sync_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$(cd "$sync_self_dir/../scripts" && pwd)/sync.sh"

# Two clones over one origin, with B's pushed commit conflicting against A's local
# one — so A is genuinely diverged against a reachable remote.
_sync_fixture() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root"
  git init -q --bare -b main "$root/origin.git"
  git clone -q "$root/origin.git" "$root/A" 2>/dev/null
  git -C "$root/A" config user.email t@t; git -C "$root/A" config user.name t
  mkdir -p "$root/A/sg"
  printf '# index\n\n## Entry nodes\n\n- [[sg/one]] — base\n' > "$root/A/sg/_index.md"
  git -C "$root/A" add -A; git -C "$root/A" commit -qm base
  git -C "$root/A" push -q -u origin main

  git clone -q "$root/origin.git" "$root/B" 2>/dev/null
  git -C "$root/B" config user.email t@t; git -C "$root/B" config user.name t
  printf '# index\n\n## Entry nodes\n\n- [[sg/two]] — from B\n' > "$root/B/sg/_index.md"
  git -C "$root/B" add -A; git -C "$root/B" commit -qm B; git -C "$root/B" push -q

  printf '# index\n\n## Entry nodes\n\n- [[sg/three]] — from A\n' > "$root/A/sg/_index.md"
  git -C "$root/A" add -A; git -C "$root/A" commit -qm A
  # A cloned before B pushed, so its origin/main ref is stale — without this fetch
  # a `rebase origin/main` in the tests below is a silent no-op.
  git -C "$root/A" fetch -q origin
}

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
