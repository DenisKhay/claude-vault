# Re-audit remediation → 1.2.0

Source: 58-agent re-audit of 1.1.1, 2026-08-30.
Report: https://claude.ai/code/artifact/b46a008a-bf6a-49b4-b201-043b6e88d505

Ordering is by damage prevented. Each item gets a test before the fix.

## C1 — sync.sh in-progress-operation guard (THE SEVERE)

- [ ] Refuse to stage/commit when `MERGE_HEAD` resolves or a rebase directory exists — loud, exit 2, before touching the index
- [ ] Make the `rebase --abort` conditional on *this* invocation having started the rebase
- [ ] Tests: mid-rebase sweep preserves the node + the human's rebase; mid-merge sweep never commits conflict markers

## C2 — sync.sh scoped staging

- [ ] `sync.sh "msg" [path...]` stages only the given paths; `git add -A` only as the no-args fallback
- [ ] SKILL.md passes the capture agent's returned `updated:`/`created:` paths
- [ ] Test: a file changed by another session is not swept into our commit

## C3 — network failure is not divergence

- [ ] `sync.sh`: probe remote reachability before writing `.sync-diverged`; unreachable → fail-open, no marker
- [ ] `inject-context.sh`: same probe on the background pull path
- [ ] `.sync-diverged` into `~/Vaults/.gitignore` so it can never be committed again
- [ ] Test: unreachable remote + dirty tree writes no marker

## C4 — enforcement that can enforce

- [ ] `registry-lint.py`: bullet-overflow becomes an **error** (so `--quiet` prints it and exits non-zero)
- [ ] SKILL.md: drop `--quiet` from the capture step's enforcement instruction
- [ ] Test: a planted 200-char bullet fails the lint in both modes

## C5 — spool correctness

- [ ] `inject-context.sh`: print `+N more` instead of silently dropping past the 5th tail
- [ ] `spool-tail.sh`: own threshold (`VAULT_SPOOL_MIN_AGE_SECONDS`, default 120) instead of reusing the 1800 s re-arm constant, which made the spool decline exactly the crash window the re-arm leaves open
- [ ] Tests: 8 records show a count; a 200 s-old sentinel still spools

## C6 — documentation truth

- [ ] SKILL.md: remove the `PostToolUse` trigger from the description and the actualize section (no such hook exists); name `SessionEnd`
- [ ] Global `CLAUDE.md:200`: same correction

## C7 — sqlite resilience

- [ ] `busy_timeout` + WAL so a concurrent embed pass cannot blank `vault_search` in another session

## C8 — health-check resolves the wrong plugin version (pantheon repo)

- [ ] Replace `find … | head -1` and `ls -dt` heuristics with the highest installed version

## Ship

- [ ] 61+ tests green, registry-lint clean, bench not regressed
- [ ] Version → 1.2.0, install, marketplace sync

## Deferred (needs measurement design, not a patch)

- Held-out bench battery — the current 67/92/96 is not held out; build a low-overlap set and report both
- Archived downrank buries nodes ~16 ranks past default k=8
- Legacy `vault.db` left at v1 schema for still-running 1.0.5 servers
- Recovering the six facts commit `3cead8e` erased
