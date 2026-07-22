---
name: vault
description: Use when vault hooks (SessionStart, Stop, PreCompact, PostToolUse) emit "invoke the vault skill in <mode> mode", or when vault slash commands (/vault-update, /vault-enroll) are run, or when no subgraph matched at session start and knowledge work is starting. Manages the single-entry-point knowledge graph at ~/Vaults/. Three modes: init (passive), actualize (capture sweep), enroll (register a new subgraph).
---

# Vault Skill

The vault is a single global knowledge graph at `~/Vaults/`. Each repo gets its own subgraph, matched at session start by this skill's `scripts/match.sh` against `~/Vaults/_registry.yaml`. Hooks enforce loading and capture; this skill is the algorithm those hooks invoke.

## Mode: init

Triggered implicitly by the SessionStart hook. The hook script has already done identity matching and printed a context block listing the matched subgraph and its entry nodes. You don't need to re-run matching.

Behavior:
- Read listed entry nodes lazily, with the Read tool, only when the user's task touches them.
- Prefer wiki-link traversal over grep: if an entry node says `[[orders/orders]]`, follow that link rather than re-discovering it.
- If the hook reported NO SUBGRAPH MATCHED and the user wants knowledge work, switch to enroll mode before doing anything else.
- Do not write to the vault in init mode. Capture happens in actualize mode.

## Mode: actualize

Triggered by Stop hook, PreCompact hook, the PostToolUse counter, or `/vault-update`. Sweeps everything Claude has learned this session into the matched subgraph as new or updated nodes.

**Two-phase, so the main transcript stays clean:** the MAIN agent only decides *what* is worth capturing (steps 1–4 — it's the only one holding the session context) and composes a candidate brief; ALL vault file I/O (dedup search, node reads/writes, index updates) runs inside ONE dispatched subagent (step 5), which renders as a single collapsed row. Never do vault file I/O inline in the main conversation — that litter is exactly what this structure removes.

### Algorithm

1. **Re-match identity**: `cwd` may have changed mid-session. Run this skill's `scripts/match.sh "$PWD"` and use the result. If MISS, switch to enroll mode and ask the user where this work belongs.

2. **Locate the subgraph root**: read `~/Vaults/_registry.yaml`, find the entry whose `id` matches, take its `path`. The subgraph root is `~/Vaults/<path>/`.

3. **Scan session deltas**. Apply the following capture rules to everything that happened this session — files read, edits made, conversation insights, errors fixed.

   **SALIENCE GATE (apply to every candidate first — when in doubt, DON'T write):** capture only durable, non-obvious knowledge that a competent dev could NOT trivially re-derive from a single source. Before creating any node, ask: *"Could I reconstruct this in <2 min by opening one file — a controller, router, props interface, Swagger doc, or component?"* If yes, **SKIP IT**. This kills the dominant failure mode (route tables, prop lists, "this page lives at /X and shows Y", controller-method enumerations) — those are 1:1 projections of a single artifact that the source documents better and keeps in sync. Capture the *why*, the *gotcha*, the *incident scar*, the *cross-repo synthesis*, the *unguessable env fact* — never the *what* that's already in code. A good node answers a question that cost real time to answer the first time.

   1. **Bug fix completed** → create/update node in `<subgraph>/bugs/`. Include symptoms, root cause, fix, ticket id (if any), `[[wiki-links]]` to affected components/endpoints.
   2. **Component read for first time** (file not yet referenced by any existing node in this subgraph) → create node in `<subgraph>/components/` with purpose, key props, gotchas.
   3. **API endpoint discovered** (in code, network requests, or docs) → create node in `<subgraph>/api/` with method, path, request/response shape.
   4. **Architecture insight learned** (an explanation of *why* something is built a certain way, especially if non-obvious from the code) → create/update node in `<subgraph>/architecture/`.
   5. **Same pattern seen twice** in the session → extract to `<subgraph>/patterns/`.
   6. **Domain / business logic clarified** → create/update node in `<subgraph>/domain/`.
   7. **Dependency gotcha found** → create/update node in `<subgraph>/dependencies/`.
   8. **Confluence / Jira / external doc read** → capture relevant knowledge with the source URL in the appropriate folder above.

4. **Cross-subgraph rule**: if a candidate node would apply to >=2 sibling subgraphs in the same namespace (e.g. several `<namespace>/*` subgraphs), write it to `<namespace>/shared/` instead.

5. **Dispatch ONE capture subagent** (synchronous `general-purpose` Task — wait for it; do NOT do this work inline). Its prompt must carry everything, since it has none of the session's context:
   - the target subgraph id + root path (and `shared/` path when step 4 applies);
   - **the full candidate brief** — per candidate: intended folder, proposed kebab-case filename, and the complete fact content (the why/gotcha/scar, 2–8 lines, links, ticket ids). Write facts out in full — the subagent cannot ask follow-ups;
   - its working rules, verbatim:
     a. **Dedup BEFORE writing**: query the `vault_search` MCP tool (and/or grep) for an existing node on the same topic, *across all subgraphs* (a near-duplicate may live in `shared/` or a sibling). If one exists → **UPDATE/MERGE into it** (fold in the new fact, refresh `updated:`, don't create a sibling). If genuinely new → create from the matching template in `~/Vaults/_templates/`. Provisional facts: mark provisional in-body, don't mint confident nodes.
     b. **Linking**: every new node MUST contain at least one `[[wiki-link]]` to an existing node in the same subgraph. No orphans. If entry-node-worthy, also add it to the subgraph's `_index.md` "Entry nodes" list.
     c. **Frontmatter**: every node carries `type/project/created/updated/tags` frontmatter (templates have the type-specific extras: bug `ticket`, component `path`, api `method`+`path`, dependency `version`).
     d. **Naming**: kebab-case filenames, short and greppable. No prefixes, no numbering. Folder provides context.
     e. **Return value**: a machine-countable last line — `updated: <paths> | created: <paths>` (empty lists allowed).

6. **On the subagent's return** (main agent): write the actualize timestamp — the hook message includes the exact `touch` command; run it. Then report to the user as ONE dim line — `vault: N updated, M new` — nothing more. Node paths live in the subagent's collapsed transcript for whoever wants the detail; never list them in chat.

### Empty-delta short-circuit
If after scanning you have no candidates (e.g. trivial typo session), still touch the timestamp file and print "no knowledge delta — nothing to capture this turn" so the Stop hook lets the session exit cleanly. Do not create empty nodes.

## Mode: enroll

Triggered when init reported MISS and the user wants to do knowledge work, or when `/vault-enroll` is run.

### Algorithm

1. **Detect identity** of the current repo:
   - `git -C "$PWD" remote get-url origin` (may be empty)
   - `git -C "$PWD" rev-parse --show-toplevel` then basename (or basename of `$PWD` if not a git repo)
   - `$PWD` (resolved to absolute path)

2. **Ask the user** where this subgraph should live. Present these options:
   - **a) New top-level subgraph** at `~/Vaults/<repo>/`
   - **b) Under an existing namespace** (e.g. `~/Vaults/<namespace>/<repo>/`) — list the existing top-level directories under `~/Vaults/` so they can pick
   - **c) Attach to an existing subgraph** (no new folder, just register the new repo under an existing subgraph id)
   - **d) Skip enrollment** — don't capture this session

3. **Create the folder and scaffold the entry index** from `~/Vaults/_templates/subgraph-index.md`. Substitute the subgraph name, namespace (if any), today's date.

4. **Append to the registry**: edit `~/Vaults/_registry.yaml` and add an entry like:
   ```yaml
     - id: <repo>
       path: <relative-path-from-vault-root>
       entry: <relative-path>/_index.md
       match:
         git_remote: <if available>
         repo_name: <basename>
         path_prefix: <absolute-path>
   ```
   If the user picked option (c), don't append a new entry — instead add the new identity fields to the existing subgraph's `match` section as alternates (use a list if there are multiple).

5. **Confirm**: "Enrolled `<repo>` as subgraph `<id>`. Future sessions in this repo will auto-load it."

6. **Optionally run actualize immediately** to capture what's already known about the repo from this session.

## State files

The skill (and the hook scripts that invoke it) use these per-session state files under `/tmp/vault-${SESSION_ID}/`:

| File | Owner | Purpose |
|---|---|---|
| `tick` | `tick-and-maybe-prompt.sh` | Counter of mutating tool calls since last actualize |
| `last-actualize` | this skill (actualize mode) | Timestamp of most recent actualize sweep |
| `paused` | `/vault-pause` slash command | When present, all hooks no-op |

## Slash commands

| Command | Mode |
|---|---|
| `/vault-update` | actualize |
| `/vault-enroll` | enroll |
| `/vault-pause` | (writes paused flag, no skill mode) |
| `/vault-resume` | (clears paused flag, no skill mode) |
