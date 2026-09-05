# Re-audit remediation → 1.2.0

Source: 58-agent re-audit of 1.1.1, 2026-08-30.
Report: https://claude.ai/code/artifact/b46a008a-bf6a-49b4-b201-043b6e88d505

Ordering is by damage prevented. Each item gets a test before the fix.

## C1 — sync.sh in-progress-operation guard (THE SEVERE)

- [x] Refuse to stage/commit when `MERGE_HEAD` resolves or a rebase directory exists — loud, exit 2, before touching the index
- [x] Make the `rebase --abort` conditional on *this* invocation having started the rebase
- [x] Tests: mid-rebase sweep preserves the node + the human's rebase; mid-merge sweep never commits conflict markers

## C2 — sync.sh scoped staging

- [x] `sync.sh "msg" [path...]` stages only the given paths; `git add -A` only as the no-args fallback
- [x] SKILL.md passes the capture agent's returned `updated:`/`created:` paths
- [x] Test: a file changed by another session is not swept into our commit

## C3 — network failure is not divergence

- [x] `sync.sh`: probe remote reachability before writing `.sync-diverged`; unreachable → fail-open, no marker
- [x] `inject-context.sh`: same probe on the background pull path
- [x] `.sync-diverged` into `~/Vaults/.gitignore` so it can never be committed again
- [x] Test: unreachable remote + dirty tree writes no marker

## C4 — enforcement that can enforce

- [x] `registry-lint.py`: bullet-overflow becomes an **error** (so `--quiet` prints it and exits non-zero)
- [x] SKILL.md: drop `--quiet` from the capture step's enforcement instruction
- [x] Test: a planted 200-char bullet fails the lint in both modes

## C5 — spool correctness

- [x] `inject-context.sh`: print `+N more` instead of silently dropping past the 5th tail
- [x] `spool-tail.sh`: own threshold (`VAULT_SPOOL_MIN_AGE_SECONDS`, default 120) instead of reusing the 1800 s re-arm constant, which made the spool decline exactly the crash window the re-arm leaves open
- [x] Tests: 8 records show a count; a 200 s-old sentinel still spools

## C6 — documentation truth

- [x] SKILL.md: remove the `PostToolUse` trigger from the description and the actualize section (no such hook exists); name `SessionEnd`
- [x] Global `CLAUDE.md:200`: same correction

## C7 — sqlite resilience

- [x] `busy_timeout` + WAL so a concurrent embed pass cannot blank `vault_search` in another session

## C8 — health-check resolves the wrong plugin version (pantheon repo)

- [x] Replace `find … | head -1` and `ls -dt` heuristics with the highest installed version

## Ship

- [x] 61+ tests green, registry-lint clean, bench not regressed
- [x] Version → 1.2.0, install, marketplace sync

## Review — shipped 2026-08-30 as 1.2.0 (`ae5a0c8`)

All of C1–C8 landed. 81/81 tests (was 61: +5 sync cases, +4 spool cases, all written before their
fix and each observed failing first). Bench unchanged at 71/92/96 @ 37.8 ms. registry-lint 0 errors.
Installed copy verified byte-identical to source, and the store's own `.gitignore` commit was made
*through* the new scoped `sync.sh` as a live test of the path-passing contract.

Two things worth remembering about the fix itself:

- **The severe needed no second machine.** The guard is what makes the conditional `rebase --abort`
  safe: because a pre-existing rebase is now refused before staging, any rebase still in flight at
  the abort must be one this invocation started. The two changes only work as a pair.
- **The tests caught a real ordering trap.** `git grep` exits 1 on no-match, and with `pipefail` that
  killed the whole suite silently the moment the fix started working — the suite printed its header
  and no report. Any new test that greps for absence needs `|| true` inside the pipeline.

Not fixed, deliberately: the fixes reach only sessions started after the install, because hook paths
resolve at launch. Existing sessions keep running 1.1.1 (or 1.0.5) until restarted.

## Deferred (needs measurement design, not a patch)

- ~~/vault-pause never expires and is silent~~ → SHIPPED in 1.3.2: SessionStart now announces the
  pause with its age and escalates past a day, and says crash-spooling is off too. Deliberately NOT
  auto-expiring — lapsing would resume capture inside the sensitive work it was set for, and sweeps
  auto-push. Also fixed en route: the git lock was global (`/tmp/vault-git.lock`), so any fixture
  vault serialized against the real one — it is now keyed per vault root.

- ~~D6 secrets guard on the push path~~ → SHIPPED in 1.3.0 (`5aa920e`): `secret-scan.sh`, fail-closed
  before staging, redacted findings, `vault-allow-secret` escape hatch. Live store scanned clean
  (1,124 files, 1 true false positive marked). Working tree and full history were already clean,
  so it is preventive.
- ~~Held-out bench battery~~ → SHIPPED: `battery_heldout.json` (30 symptom-voice queries) + `bench.py`
  now measures query/target word overlap and stratifies every result by it, so a battery reports its own
  overfit. Honest number is **33/63/83 @ 42% overlap** vs the legacy harness's 71/92/96 @ 79% overlap.
  Follow-up this UNBLOCKS (new work, not audit debt): 5 of 30 miss at hit@8 on very reasonable queries
  (H08 disk-full, H10 tv gateway, H11 lockscreen password, H13 theme not listed, H25 stale rows on error).
  There is now a metric to tune against — before this there was only a number that could not move.
- ~~Archived downrank buries nodes past default k=8~~ → SHIPPED in 1.3.1: ARCHIVED_PENALTY 0.5 -> 0.95.
  Measured on the real store: 49 archived nodes queried by their own titles went from 0 ranked #1 /
  4 reachable within k=8, to 23 ranked #1 / 49 reachable. Pinned by tests/test_archived_rank.sh, which
  needs a 40-doc fixture — the burial cannot reproduce in a small corpus, so a naive test passes at any
  penalty. NOT 1.0: without a penalty an archived copy outranks the live node that superseded it.
- ~~Legacy `vault.db` at v1 schema for still-running 1.0.5 servers~~ → CLOSED: self-resolving. The only
  affected session (algos) has ended and will come up on the current plugin when resumed with `claude -c`.
- ~~Recovering the six facts commit `3cead8e` erased~~ → DONE 2026-08-30: restored into
  `machine/architecture/tizen-tv-remote-monitor-plan.md` as an "Alternatives considered" section
  (VNC Remote Access, noVNC, the xrdp trap, Miracast, the 2-free-CRTC capacity fact, the alternative
  sideload route). The node had been rewritten plan->WORKING, which was right; deleting the decision
  record was not. Audited the rest of that commit: every other removal was a frontmatter date bump
  except installability.md, which was rewritten in place and lost nothing.
- ~~PreCompact never fired~~ → RETRACTED, not fixed: the claim came from grepping an undocumented,
  version-unstable transcript format. 1.4.0 makes the hook log its own firings instead.
- ~~rejected.log on tmpfs~~ → SHIPPED: `rejected-log.sh` writes to ~/.claude/vault-state/.

## 1.6.0 — spool auto-drain (2026-09-05)

Five dead-session tails piled up in `~/.claude/vault-spool/` and every SessionStart nagged
"mine each transcript when convenient" until a live session spent ~25 minutes and four
subagents on them. Two of the five tails were empty (the sweep's own closing output). The
SessionEnd hook cannot prompt a model, but it can spawn one.

- [x] `transcript-digest.py`: render a transcript JSONL to a readable digest, mark every
      Stop-hook sweep boundary, print `tail_bytes=` for the part after the last boundary
- [x] `spool-drain.sh`: detached launcher — render, measure, under the floor → delete the
      spool + log; else spawn `claude -p --model sonnet` as a spool worker in the dead cwd;
      attempts counter in the spool record, dry-run mode for tests
- [x] `spool-tail.sh` calls the drain after spooling; worker sessions never spool themselves
- [x] `prompt-actualize.sh` stays silent for worker sessions (no self-sweep loop)
- [x] `inject-context.sh`: worker sessions get no spool listing; normal sessions relaunch
      stale spools (no live worker, attempts left) and only list what auto-drain gave up on
- [x] tests: `test_spool_drain.sh`
- [x] SKILL.md spool-worker variant + state-file rows; README + ARCHITECTURE one-liners
- [x] bump 1.6.0, run suite, commit, push, reinstall

### Review (2026-09-05, shipped as 1.6.0 → 1.6.2)
- Floor validated on the five real tails: 12531 / 6668 B spawned, 3080 / 807 / 227 B dropped —
  the same 2-of-5 verdict a live session reached by hand. Text-only counting is what makes the
  bookkeeping tails (tool traffic, one "no knowledge delta" line) fall under 4 KB.
- 1.6.0's first real worker died in 3 s: `--allowedTools` is variadic and ate the positional
  prompt. 1.6.1 feeds the prompt over stdin; a test now asserts the prompt is absent from argv.
- 1.6.1's first real worker (machine tail, 6668 B, facts already captured that day) ran 3 min on
  sonnet, ended `no knowledge delta`, cleared its record, left the vault untouched, and was not
  spooled by its own SessionEnd. It located the plugin scripts with `find /` — 1.6.2 puts the
  scripts directory in the prompt.
- Not changed: sessions already open keep their old hooks (hook paths pin at session start), so
  their ends still only write pointer records; the next fresh SessionStart relaunches those.
- Open question, not a patch: a fresh miner over a WHOLE transcript (not just the tail) found four
  durable algos facts that nine in-session sweeps had missed. The drain deliberately mines only the
  tail; whether a periodic whole-transcript re-mine pays for itself needs a measurement, not a guess.
