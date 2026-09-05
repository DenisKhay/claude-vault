# Architecture

How the vault system actually works, as shipped. (This supersedes the original
paused-redesign design docs — it documents the running implementation.)

## Data model

The vault is a tree of Markdown **nodes** under `~/Vaults/` (`$VAULT_ROOT`). Each node
has YAML frontmatter (`type`, `project`, `created`, `updated`, `tags`, type-specific
fields) and a body. Nodes link to each other with `[[wiki-links]]`.

```
~/Vaults/
├── _registry.yaml          identity → subgraph map (the routing table)
├── _templates/             node scaffolds (bug, component, api, architecture, …)
├── .index/vault.db         SQLite: FTS5 table + docs table (body, embedding blob)
├── _index.md               root index
└── <namespace>/<subgraph>/ or <subgraph>/
    ├── _index.md           entry node (links to the subgraph's key nodes)
    ├── bugs/ components/ api/ architecture/ patterns/ domain/ dependencies/
```

- **Subgraph** — one repo's knowledge, e.g. `web-app` or `acme/web-app`.
- **Namespace** — a 2-level root (`acme/`) grouping sibling subgraphs. Namespaces are
  **auto-derived** from the registry (a subgraph whose `path` has a parent dir, or that
  sets `namespace:`) — there is no hardcoded list, so the engine is vault-agnostic.
- **`status: archived`** nodes are soft-deleted: kept on disk, excluded from the index
  and from search.

## Identity routing — `scripts/match.sh`

Given a cwd, `match.sh` reads `_registry.yaml` and returns every matching subgraph id
(or `MISS`). A subgraph matches on any of `git_remote`, `repo_name`, or `path_prefix`
(matched against both the logical and the symlink-resolved cwd). Multiple subgraphs can
match one cwd (e.g. a monorepo's frontend + backend). `always_in_namespace` subgraphs
(like a shared/ area) are appended whenever a sibling in their namespace matched.
Malformed registry entries (missing `id`) are skipped — a bad entry degrades to `MISS`,
never a crash.

## Hook lifecycle

| Event | Script | Behavior |
|-------|--------|----------|
| `SessionStart` | `inject-context.sh` | Runs `match.sh`, injects the matched subgraph's entry nodes (or reports `MISS` + offers enroll). |
| `PostToolUse` (`Edit│Write│Bash`) | `tick-and-maybe-prompt.sh` | Counts mutating calls. Every `VAULT_TICK_THRESHOLD` (40), emits a **non-blocking** advisory to optionally actualize — unless one happened within the freshness window. Never blocks. |
| `PreCompact` | `prompt-actualize.sh --reason=compact` | Requests an actualize sweep before context is compacted. |
| `Stop` | `prompt-actualize.sh` | Guarantees **one** capture sweep per session (blocks once via exit 2, then lets the session end). |
| `SessionEnd` | `spool-tail.sh` → `spool-drain.sh` | Writes a pointer record for a session that ends unswept, then launches a detached headless `claude -p` worker (sonnet) that renders the transcript with `transcript-digest.py`, mines only the tail after the last sweep boundary, syncs, and deletes the record. Tails under `VAULT_SPOOL_DRAIN_MIN_TAIL_BYTES` (4 KB of text) are dropped as empty. SessionStart relaunches stale records and lists only those auto-drain gave up on (3 attempts). Worker sessions carry `VAULT_SPOOL_WORKER=1`, which silences their own Stop/SessionEnd hooks. |

Per-session state lives in `/tmp/vault-<session_id>/`: `tick` (counter), `last-actualize`
(timestamp), `paused` (flag), `cwd` (marker). `/vault-pause` writes `paused`; while present
all hooks no-op.

## The skill — `skills/vault/SKILL.md`

Three modes the hooks/commands invoke:

- **init** (passive) — read entry nodes lazily as the task touches them; prefer wiki-link
  traversal over grep.
- **actualize** (the capture sweep) — scan the session for durable knowledge and write
  new/updated nodes. Gated by:
  - **Salience gate** — skip anything re-derivable in <2 min from one source file (route
    tables, prop lists, "page X shows Y"). Capture the *why*, the gotcha, the incident
    scar, the cross-repo synthesis.
  - **Dedup before write** — query `vault_search` for an existing node on the topic;
    UPDATE/MERGE rather than minting a duplicate.
- **enroll** — register a new repo into `_registry.yaml` and scaffold its `_index.md`.

## Search engine — `skills/vault/retrieval/`

**Indexing** (`vault_search.py reindex`): walks the vault (skipping `.git`, `.index`,
`.obsidian`, `.claude`, `_templates`, and dotfiles), and for each non-archived node stores
body + metadata + a content hash in `docs`, and **per-chunk embeddings** in `chunks` — the
body is split into ~1500-char paragraph-aware chunks (title-prefixed for grounding) and each
chunk is embedded, so content deep in a long node stays reachable instead of being clipped by
a single whole-doc vector. It is **hash-incremental**: unchanged files are skipped,
deleted/newly-archived files have their docs+chunks pruned. A file indexed while the embedder
was down (no chunks) is **re-embedded on the next run** once it returns — the skip check
requires both an unchanged hash *and* existing chunk rows.

**Retrieval** (`vault_search.py search`):
1. **Keyword** — SQLite FTS5 `bm25()`, query tokenized Unicode-aware (`\w+`) so non-ASCII
   (e.g. Cyrillic) terms hit the `unicode61`-tokenized index. Each token is quoted, so FTS5
   operators in user input are inert (injection-safe).
2. **Vector** — cosine over `nomic-embed-text` chunk embeddings, **max-pooled per doc** (a
   node ranks by its single best-matching chunk), when numpy + Ollama are available, with a
   dimension guard against stale blobs.
3. **Fusion** — Reciprocal Rank Fusion (`1/(60+rank)`) over the two rank lists, times a mild
   recency factor (`0.6 + 0.4·decay`, 120-day half-life) that nudges ties but can never
   overturn a strong dual-modality match.
4. **Scope** — an optional `subgraphs` filter is applied to candidates *before* the per-modality
   top-N cap, so a scoped search returns a full result set even for a small subgraph.

Degradation is graceful at every layer: no numpy / no Ollama → keyword-only; the result
reports whether the vector path actually ran.

## MCP server — `skills/vault/retrieval/vault_mcp.py`

A minimal JSON-RPC 2.0 stdio server exposing the `vault_search` tool. stdout is a pure
JSON-RPC channel (all logs go to stderr). The index is built once on first call; subsequent
calls **debounce** the refresh behind a cheap tree fingerprint (max mtime + file count) — a
full reindex runs only when the vault actually changed, so a typical query is a few ms, not
a full re-walk. Bad frames and out-of-range `k` are tolerated without taking the loop down.

## Invariants worth preserving

- The data root (`~/Vaults`) and the engine (this plugin) are independent. Nodes outlive the
  plugin; the plugin is replaceable.
- Capture writes only what survives the salience gate. The vault is a *knowledge* store, not
  a transcript.
- Everything degrades to keyword-only rather than failing closed when the embedder is absent.
