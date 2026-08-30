#!/usr/bin/env python3
"""Minimal MCP stdio server exposing `vault_search` over the Markdown vault.

Newline-delimited JSON-RPC 2.0 on stdin/stdout (MCP stdio transport). No external
deps beyond what vault_search needs (sqlite3, numpy, pyyaml, urllib). All diagnostics
go to stderr so stdout stays a clean JSON-RPC channel.
"""
import sys, os, json, time, threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vault_search as V

PROTOCOL = "2024-11-05"
_CON = None
_EMBED_OK = False
_LAST_SIG = None
_EMBED_LAST_PROBE = 0.0
EMBED_REPROBE_SECONDS = 300  # when embeddings are down, retry the probe this often
_LOCK = threading.Lock()     # ensure_index runs from the pre-warm thread AND handle()


def log(*a):
    print("[vault_mcp]", *a, file=sys.stderr, flush=True)


def _prewarm():
    try:
        ensure_index()
    except Exception as e:
        log("prewarm failed (first call will retry):", repr(e))


def _tree_sig():
    """Cheap fingerprint of the vault (max mtime + .md count) — one stat-walk, no file
    reads / YAML / hashing. Lets ensure_index skip the ~150ms reindex when nothing changed."""
    mx, n = 0.0, 0
    for dp, dn, fns in os.walk(V.VAULT_ROOT):
        dn[:] = [d for d in dn if d not in V.SKIP_DIRS]
        for f in fns:
            if f.endswith(".md") and not f.startswith("."):
                n += 1
                try:
                    mx = max(mx, os.stat(os.path.join(dp, f)).st_mtime)
                except OSError:
                    pass
    return (mx, n)


def ensure_index():
    global _CON, _EMBED_OK, _LAST_SIG, _EMBED_LAST_PROBE
    with _LOCK:
        if _CON is None:
            _CON, _EMBED_OK = V.open_and_index()
            _LAST_SIG = _tree_sig()
            _EMBED_LAST_PROBE = time.time()
            log("index ready, embeddings=", _EMBED_OK)
            return
        # Embeddings down at startup must not stay down for the server's lifetime
        # (the old frozen _EMBED_OK hid a never-populated semantic layer for months):
        # when off, re-probe on a timer; on recovery, backfill vectors.
        if not _EMBED_OK and time.time() - _EMBED_LAST_PROBE > EMBED_REPROBE_SECONDS:
            _EMBED_LAST_PROBE = time.time()
            if V.embed("ping") is not None:
                _EMBED_OK = True
                log("embeddings recovered — backfilling vectors")
                V.reindex(_CON, embed_enabled=True)
                _LAST_SIG = _tree_sig()
                return
        # Debounce: only re-walk/read/hash when the tree fingerprint changed (add/edit/delete).
        sig = _tree_sig()
        if sig != _LAST_SIG:
            V.reindex(_CON, embed_enabled=_EMBED_OK)
            _LAST_SIG = sig


TOOL = {
    "name": "vault_search",
    "description": (
        "Search the personal knowledge vault by keyword AND — when the local embedding "
        "model is up — by meaning (each result line reports vector=on/off honestly). "
        "Returns ranked nodes (Markdown file paths) with title, subgraph and score. "
        "Use this when you need prior knowledge — bugs, gotchas, architecture decisions, domain "
        "models, env facts — and don't already know which node holds it. Then Read the top paths. "
        "Searches across ALL subgraphs (cross-project), not just the current repo."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Natural-language or keyword query."},
            "k": {"type": "integer", "description": "Max results (default 8).", "default": 8},
            "subgraphs": {"type": "array", "items": {"type": "string"},
                          "description": "Optional filter: registry ids or path labels "
                                         "('shared' and 'lifedl/shared' both work)."},
        },
        "required": ["query"],
    },
}


def handle(msg):
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "vault-search", "version": "1.1.0"}}}

    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no reply

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL]}}

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "vault_search":
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32601, "message": f"unknown tool {name}"}}
        try:
            ensure_index()
            q = args.get("query", "")
            try:
                k = max(1, min(int(args.get("k", 8)), 50))
            except (TypeError, ValueError):
                k = 8
            subs = args.get("subgraphs") or None
            scope_note = ""
            if subs:
                resolved, unknown, known = V.resolve_scopes(_CON, subs)
                if unknown:
                    scope_note = (f"\n(unknown subgraph name(s) {unknown} — "
                                  f"valid labels: {', '.join(known)})")
                if resolved is None:
                    text = ("vault_search: no such subgraph(s) "
                            f"{list(subs)}. Valid labels: {', '.join(known)}. "
                            "Retry unscoped or with a label from the list.")
                    return {"jsonrpc": "2.0", "id": mid,
                            "result": {"content": [{"type": "text", "text": text}]}}
            res, vec_used = V.search(_CON, q, k=k, subgraphs=subs)
            lines = [f"vault_search: {len(res)} results (vector={'on' if vec_used else 'off'})", ""]
            for r in res:
                flag = "  [ARCHIVED]" if r.get("archived") else ""
                lines.append(f"- {r['path']}  [{r['subgraph']}]  (score {r['score']}){flag}")
                lines.append(f"    {r['title']}")
            text = ("\n".join(lines) if res else "vault_search: no matches.") + scope_note
            return {"jsonrpc": "2.0", "id": mid,
                    "result": {"content": [{"type": "text", "text": text}]}}
        except Exception as e:
            log("search error:", repr(e))
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32603, "message": f"search failed: {e}"}}

    if mid is not None:
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": f"unknown method {method}"}}
    return None


def main():
    log("starting; vault=", V.VAULT_ROOT)
    # Pre-warm in the background so the first tools/call never pays the index
    # build (or, right after embeddings are enabled, the full embed pass) inside
    # a client timeout window.
    threading.Thread(target=lambda: _prewarm(), daemon=True).start()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as e:
            log("bad json:", e)
            continue
        if not isinstance(msg, dict):
            log("ignoring non-object frame (JSON-RPC batch arrays unsupported)")
            continue
        resp = handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
