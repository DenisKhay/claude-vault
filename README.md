# claude-vault

A persistent **knowledge graph for Claude Code** — one global vault of Markdown notes, automatically routed per repo, searchable by meaning *and* keyword, and kept fresh by hooks so durable project knowledge survives across sessions instead of evaporating when the context window closes.

It ships as a single Claude Code **plugin** bundling four things that have to work together:

| Component | What it does |
|-----------|--------------|
| **Skill** (`vault`) | The capture/recall algorithm: `init`, `actualize` (sweep what was learned into nodes), `enroll` (register a repo). |
| **Hooks** | `SessionStart` injects the matched subgraph; `PostToolUse` nudges (non-blocking) after N edits; `Stop`/`PreCompact` guarantee a capture sweep. |
| **MCP server** (`vault-search`) | Hybrid retrieval — SQLite **FTS5 (BM25)** + **`nomic-embed-text`** embeddings fused with Reciprocal Rank Fusion, decay-aware, archived-excluding. |
| **Commands** | `/vault-update`, `/vault-enroll`, `/vault-pause`, `/vault-resume`. |

A bare skill can't carry hooks or an MCP server — which is exactly why this is a plugin.

---

## Why

The default pattern — knowledge living as ad-hoc rules in `CLAUDE.md` — has two failure modes:

1. **Enrollment gap.** Rules scoped to a hardcoded project list mean new repos get zero capture.
2. **Compliance gap.** "Remember to write things down" relies on the model remembering mid-task. It doesn't.

This system closes both: identity-based routing enrolls any repo, and hooks enforce the capture sweep so it isn't optional.

---

## How it works (short version)

```
repo cwd ──match.sh──▶ subgraph id(s)        ~/Vaults/
  (git_remote │ repo_name │ path_prefix)     ├── _registry.yaml      identity → subgraph
        │                                     ├── _templates/         node scaffolds
        ▼                                     ├── .index/vault.db     FTS5 + embeddings
  SessionStart hook injects the subgraph's    └── <namespace>/<subgraph>/
  entry nodes into context                         ├── _index.md
        │                                           ├── bugs/ components/ api/
  vault_search MCP  ◀── recall on demand            ├── architecture/ patterns/
        │                                           └── domain/ dependencies/
  Stop / PreCompact hook ──▶ actualize sweep ──▶ new / updated nodes
```

Full details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Requirements

| | |
|---|---|
| **Required** | `bash`, `git`, **Python 3.8+**, **`pyyaml`** (`pip install pyyaml`), **`jq`** |
| **Recommended** | **`numpy`** (vector search; without it search is keyword-only) · **[Ollama](https://ollama.com)** running `nomic-embed-text` (`ollama pull nomic-embed-text`) for semantic embeddings |
| **Platform** | Linux (GNU coreutils — uses `stat -c`, `touch -d`, `/tmp`). macOS works for search/capture but the freshness timer in the tick hook needs a BSD-`stat` tweak. |

Everything **degrades gracefully**: no Ollama → keyword-only (BM25); no numpy → keyword-only; Ollama returns later → next reindex backfills the missing embeddings automatically.

---

## Install

```text
# 1. add this repo as a plugin marketplace, then install the plugin
/plugin marketplace add DenisKhay/claude-vault
/plugin install vault@claude-vault

# 2. (new shell) scaffold the data root ~/Vaults — idempotent, never clobbers
bash ~/.claude/plugins/<...>/claude-vault/scripts/bootstrap.sh
#   or clone + run directly:  git clone … && bash claude-vault/scripts/bootstrap.sh

# 3. build the search index (optional but recommended)
python3 <plugin>/skills/vault/retrieval/vault_search.py --reindex
```

Plugins resolve their own location via `${CLAUDE_PLUGIN_ROOT}`, so the hooks and MCP server work wherever Claude Code installs them — no path editing.

> The **data** (`~/Vaults`) is intentionally separate from the **code** (this plugin). Your notes are yours; the plugin is just the engine over them. Nothing personal is committed here — only generic templates and an example registry.

---

## Usage

- **Enroll a repo** — in a new project, run `/vault-enroll` and pick where its subgraph lives. Future sessions auto-load it.
- **Capture** — happens automatically on `Stop`/`PreCompact`. Force it anytime with `/vault-update`. The skill applies a *salience gate*: it only writes durable, non-obvious knowledge (the *why*, the gotcha, the cross-repo synthesis) — never what's trivially re-derivable from one source file.
- **Recall** — ask Claude something; it calls the `vault_search` MCP tool (semantic + keyword across all subgraphs) and reads the top nodes.
- **Pause/resume** — `/vault-pause` silences all hooks for sensitive or throwaway work; `/vault-resume` re-enables.
- **Lint** — `python3 <plugin>/skills/vault/scripts/vault_lint.py` reports orphans, duplicate basenames, frontmatter defects, and unlinked-mention suggestions.

---

## Configuration (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `VAULT_ROOT` | `~/Vaults` | Vault data location |
| `OLLAMA_URL` | `http://localhost:11434` | Embedding server |
| `VAULT_EMBED_MODEL` | `nomic-embed-text` | Embedding model |
| `VAULT_TICK_THRESHOLD` | `40` | Mutating tool calls before the optional mid-session nudge |
| `VAULT_TICK_FRESHNESS_SECONDS` | `300` | Skip the nudge if an actualize happened within this window |

---

## Uninstall

```text
/plugin uninstall vault@claude-vault
```

Your `~/Vaults` data is untouched. Delete it manually if you also want the notes gone.

---

## Development

```bash
bash skills/vault/tests/run.sh     # 53 unit tests (bash hook scripts + match routing)
```

## License

MIT © Denis Khaydarshin. See [LICENSE](LICENSE).
