#!/usr/bin/env python3
"""Hybrid retrieval over the Markdown vault.

- SQLite FTS5 (BM25) keyword ranking + nomic-embed-text (Ollama) vector cosine,
  fused with Reciprocal Rank Fusion (RRF, k=60).
- Chunked embeddings: long bodies are split into ~1500-char paragraph-aware chunks,
  each embedded; query similarity is the MAX over a doc's chunks (so content deep in
  a long node is reachable — a single whole-doc vector would dilute it).
- Decay-aware: a MILD recency nudge from frontmatter `updated`. The multiplier is
  deliberately shallow (0.95–1.0): the 2026-08-30 audit measured the old 0.6–1.0
  span displacing stable reference nodes 15–40 ranks — burying 3-month-old
  canonical nodes below k=8 for their own names. Dampening it was worth +5–6 hit@1.
- Frontmatter `tags` are indexed into FTS (they were curated but retrieval-inert
  for the vault's whole life — 1,696 occurrences invisible to search).
- Soft-delete: nodes with `status: archived` stay INDEXED but score ×0.5 and are
  labeled archived in results (fully hiding them made archived-unique content
  unreachable by search — 46 nodes, at least one holding facts that exist nowhere else).
- Incremental: only re-embeds files whose content hash changed.
- Degrades gracefully to FTS5-only when Ollama is unreachable.
- Subgraph scope filters accept BOTH registry ids and path-derived labels
  (`shared` == `lifedl/shared`); unknown names are reported, never silently empty.

CLI:  python3 vault_search.py "query text"      # search
      python3 vault_search.py --reindex          # force full reindex
"""
import os, sys, re, json, sqlite3, hashlib, urllib.request, math, datetime, struct

VAULT_ROOT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
INDEX_DIR  = os.path.join(VAULT_ROOT, ".index")
# Schema-versioned FILENAME, not just a PRAGMA: a schema bump in a shared file
# crashes every still-running old server process ("docs has 8 columns but 7
# values") the moment its next tree-change reindex fires. Old code keeps its own
# working vault.db; each schema generation gets its own file. Derived state —
# .index/ is gitignored, a fresh build costs ~90s with embeddings.
DB_PATH    = os.path.join(INDEX_DIR, "vault-v2.db")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.environ.get("VAULT_EMBED_MODEL", "nomic-embed-text")
RRF_K = 60
DECAY_HALFLIFE_DAYS = 120.0   # mild recency prior
CHUNK_CHARS = 1500            # embedding chunk size (well under nomic's ~2048-token window)
SKIP_DIRS = {".index", ".obsidian", ".git", ".claude", "_templates"}
SCHEMA_VERSION = 2            # bump forces a clean rebuild (v2: tags column, archived indexed)
ARCHIVED_PENALTY = 0.5

try:
    import numpy as np
except Exception:
    np = None
try:
    import yaml
except Exception:
    yaml = None


def _today():
    # Date.now-free in agents, but this is a normal CLI/server process.
    return datetime.date.today()


def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    fm_raw = text[3:end].strip()
    body = text[end + 4:]
    meta = {}
    if yaml:
        try:
            meta = yaml.safe_load(fm_raw) or {}
            if not isinstance(meta, dict):
                meta = {}
        except Exception:
            meta = {}
    return meta, body


def iter_nodes():
    for dirpath, dirnames, filenames in os.walk(VAULT_ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".md") or fn.startswith("."):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, VAULT_ROOT)
            yield full, rel


_NS_CACHE = None
def _namespaces():
    """2-level namespaces derived from the registry: any subgraph that declares
    `namespace:` or whose `path` has a parent dir. Portable — no hardcoded names."""
    global _NS_CACHE
    if _NS_CACHE is None:
        _NS_CACHE = set()
        reg = os.path.join(VAULT_ROOT, "_registry.yaml")
        if yaml and os.path.exists(reg):
            try:
                data = yaml.safe_load(open(reg)) or {}
                for sg in data.get("subgraphs") or []:
                    if not isinstance(sg, dict):
                        continue
                    ns = sg.get("namespace")
                    if not ns:
                        p = sg.get("path") or ""
                        ns = p.split("/")[0] if "/" in p else None
                    if ns:
                        _NS_CACHE.add(ns)
            except Exception:
                pass
    return _NS_CACHE


def subgraph_of(rel):
    parts = rel.split(os.sep)
    if len(parts) > 1 and parts[0] in _namespaces():
        return parts[0] + "/" + parts[1]
    return parts[0]


def days_since(date_str):
    if not date_str:
        return 9999
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", str(date_str))
    if not m:
        return 9999
    try:
        d = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        return max(0, (_today() - d).days)
    except Exception:
        return 9999


def connect():
    os.makedirs(INDEX_DIR, exist_ok=True)
    # check_same_thread=False: the MCP server's pre-warm THREAD creates this
    # connection and the request loop then uses it; access is serialized by the
    # server's own lock, so cross-thread use is safe — without the flag it raises.
    con = sqlite3.connect(DB_PATH, check_same_thread=False)
    ver = con.execute("PRAGMA user_version").fetchone()[0]
    if ver != SCHEMA_VERSION:
        for t in ("docs", "fts", "chunks"):
            con.execute(f"DROP TABLE IF EXISTS {t}")
        con.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    con.execute("""CREATE TABLE IF NOT EXISTS docs(
        path TEXT PRIMARY KEY, title TEXT, subgraph TEXT, body TEXT,
        updated TEXT, hash TEXT, archived INTEGER DEFAULT 0, emb BLOB)""")
    con.execute("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(path, title, body, subgraph, tags)")
    con.execute("""CREATE TABLE IF NOT EXISTS chunks(
        path TEXT, idx INTEGER, emb BLOB, PRIMARY KEY(path, idx))""")
    return con


def embed(text):
    """Return a float32 list from Ollama, or None if unavailable."""
    try:
        req = urllib.request.Request(
            OLLAMA_URL + "/api/embeddings",
            data=json.dumps({"model": EMBED_MODEL, "prompt": text[:4000]}).encode(),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r).get("embedding")
    except Exception:
        return None


def split_chunks(title, body):
    """Paragraph-aware packing of body into ~CHUNK_CHARS windows; the title leads every
    chunk for topical grounding. Oversized paragraphs are hard-split. Always >=1 chunk."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", (body or "").strip()) if p.strip()]
    units = []
    for p in paras:
        while len(p) > CHUNK_CHARS:
            units.append(p[:CHUNK_CHARS]); p = p[CHUNK_CHARS:]
        if p:
            units.append(p)
    chunks, cur = [], ""
    for u in units:
        if cur and len(cur) + len(u) + 2 > CHUNK_CHARS:
            chunks.append(cur); cur = u
        else:
            cur = (cur + "\n\n" + u) if cur else u
    if cur:
        chunks.append(cur)
    if not chunks:
        chunks = [""]
    return [(f"{title}\n{c}").strip() for c in chunks]


def reindex(con, force=False, embed_enabled=True):
    cur = con.cursor()
    existing = {row[0]: [row[1], False] for row in cur.execute("SELECT path, hash FROM docs")}
    # "has embeddings" = has >=1 chunk row (so an outage-indexed doc re-embeds next run).
    for (path,) in cur.execute("SELECT DISTINCT path FROM chunks"):
        if path in existing:
            existing[path][1] = True
    seen, changed = set(), 0
    for full, rel in iter_nodes():
        try:
            text = open(full, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        meta, body = parse_frontmatter(text)
        archived = 1 if str(meta.get("status", "")).lower() == "archived" else 0
        seen.add(rel)
        h = hashlib.sha1(text.encode("utf-8", "ignore")).hexdigest()
        prev = existing.get(rel)
        # Skip only if unchanged AND (embeddings off this run, or it already has chunks).
        if not force and prev and prev[0] == h and (not embed_enabled or prev[1]):
            continue
        changed += 1
        mt = re.search(r"^#\s+(.+)$", body, re.M)
        title = mt.group(1).strip() if mt else os.path.basename(rel)[:-3]
        sg = subgraph_of(rel)
        updated = str(meta.get("updated") or meta.get("created") or "")
        raw_tags = meta.get("tags")
        if isinstance(raw_tags, (list, tuple)):
            tags = " ".join(str(t) for t in raw_tags)
        else:
            tags = str(raw_tags or "")
        cur.execute("INSERT OR REPLACE INTO docs VALUES(?,?,?,?,?,?,?,?)",
                    (rel, title, sg, body, updated, h, archived, None))
        cur.execute("DELETE FROM fts WHERE path=?", (rel,))
        cur.execute("INSERT INTO fts(path,title,body,subgraph,tags) VALUES(?,?,?,?,?)",
                    (rel, title, body, sg, tags))
        # Chunked embeddings: replace this doc's chunk vectors.
        cur.execute("DELETE FROM chunks WHERE path=?", (rel,))
        if embed_enabled:
            for i, ch in enumerate(split_chunks(title, body)):
                vec = embed(ch)
                if vec:
                    cur.execute("INSERT INTO chunks(path, idx, emb) VALUES(?,?,?)",
                                (rel, i, struct.pack("<%df" % len(vec), *vec)))
    # prune deleted files (archived nodes stay indexed, downranked at score time)
    for rel in list(existing):
        if rel not in seen:
            cur.execute("DELETE FROM docs WHERE path=?", (rel,))
            cur.execute("DELETE FROM fts WHERE path=?", (rel,))
            cur.execute("DELETE FROM chunks WHERE path=?", (rel,))
    con.commit()
    return changed


def resolve_scopes(con, requested):
    """Map requested scope names (registry ids OR path labels OR bare last
    segments) to the path-derived subgraph labels the index actually stores.
    Returns (resolved_label_set_or_None, unknown_names, known_labels)."""
    labels = {row[0] for row in con.execute("SELECT DISTINCT subgraph FROM docs")}
    if not requested:
        return None, [], sorted(labels)
    id2label = {}
    reg = os.path.join(VAULT_ROOT, "_registry.yaml")
    if yaml and os.path.exists(reg):
        try:
            data = yaml.safe_load(open(reg)) or {}
            for sg in data.get("subgraphs") or []:
                if isinstance(sg, dict) and sg.get("id") and sg.get("path"):
                    p = str(sg["path"]).strip("/")
                    parts = p.split("/")
                    label = "/".join(parts[:2]) if len(parts) > 1 else parts[0]
                    id2label[str(sg["id"])] = label
        except Exception:
            pass
    resolved, unknown = set(), []
    for name in requested:
        name = str(name).strip().strip("/")
        if name in labels:
            resolved.add(name)
            continue
        if name in id2label and id2label[name] in labels:
            resolved.add(id2label[name])
            continue
        suffix = {l for l in labels if l.endswith("/" + name)}
        if suffix:
            resolved |= suffix
            continue
        unknown.append(name)
    return (resolved or None), unknown, sorted(labels)


def _fts_query(q):
    # OR the alnum tokens so partial-overlap queries still match; quote each token.
    # \w is Unicode-aware in Py3, so Cyrillic tokens survive (the FTS5 unicode61
    # tokenizer already indexes them) — ASCII-only would silently drop all Russian.
    toks = re.findall(r"\w+", q, re.UNICODE)
    if not toks:
        return None
    return " OR ".join('"%s"' % t for t in toks)


def search(con, query, k=8, subgraphs=None):
    cur = con.cursor()
    sub_meta = {row[0]: row[1] for row in cur.execute("SELECT path, subgraph FROM docs")}
    sub_set = resolve_scopes(con, subgraphs)[0] if subgraphs else None
    def in_scope(path):
        return sub_set is None or sub_meta.get(path) in sub_set
    # keyword ranks via BM25. When a subgraph filter is set, over-fetch then scope so
    # the top-60 cap is drawn from the FILTERED set (not the global corpus, which can
    # starve a non-dominant subgraph below k).
    kw = {}
    fq = _fts_query(query)
    if fq:
        limit = 60 if sub_set is None else 2000
        rows = cur.execute(
            "SELECT path, bm25(fts) AS r FROM fts WHERE fts MATCH ? ORDER BY r LIMIT ?", (fq, limit)
        ).fetchall()
        rank = 0
        for path, _r in rows:
            if not in_scope(path):
                continue
            kw[path] = rank
            rank += 1
            if rank >= 60:
                break
    # vector ranks via cosine over CHUNK embeddings, max-pooled per doc — scope-filtered
    # before the cap so a long node ranks by its single best-matching chunk.
    vec = {}
    qv = embed(query)
    vector_used = bool(qv) and np is not None   # numpy gates the only consumer of qv
    if vector_used:
        qa = np.array(qv, dtype="float32")
        qa /= (np.linalg.norm(qa) + 1e-9)
        best = {}
        for path, blob in cur.execute("SELECT path, emb FROM chunks"):
            if not in_scope(path):
                continue
            arr = np.frombuffer(blob, dtype="float32")
            if arr.shape[0] != qa.shape[0]:
                continue
            s = float(np.dot(arr, qa) / (np.linalg.norm(arr) + 1e-9))
            if path not in best or s > best[path]:
                best[path] = s
        for rank, (path, _s) in enumerate(sorted(best.items(), key=lambda x: -x[1])[:60]):
            vec[path] = rank
    # Reciprocal Rank Fusion + decay (candidates are already scope-filtered).
    # Decay is a shallow nudge (0.95–1.0): the old 0.6–1.0 span was measured
    # displacing aged canonical nodes 15–40 ranks — a burial, not a nudge.
    meta = {row[0]: (row[1], row[2]) for row in
            cur.execute("SELECT path, updated, archived FROM docs")}
    scores = {}
    for path in set(kw) | set(vec):
        s = 0.0
        if path in kw:  s += 1.0 / (RRF_K + kw[path])
        if path in vec: s += 1.0 / (RRF_K + vec[path])
        updated, archived = meta.get(path, ("", 0))
        decay = math.exp(-math.log(2) * days_since(updated) / DECAY_HALFLIFE_DAYS)
        s *= (0.95 + 0.05 * decay)
        if archived:
            s *= ARCHIVED_PENALTY
        scores[path] = s
    ranked = sorted(scores.items(), key=lambda x: -x[1])[:k]
    out = []
    for path, sc in ranked:
        title = cur.execute("SELECT title FROM docs WHERE path=?", (path,)).fetchone()
        row = {"path": path, "title": title[0] if title else path,
               "subgraph": sub_meta.get(path), "score": round(sc, 5)}
        if meta.get(path, ("", 0))[1]:
            row["archived"] = True
        out.append(row)
    return out, vector_used


def open_and_index():
    con = connect()
    # probe ollama once; if down, index/search keyword-only
    embed_ok = embed("ping") is not None
    reindex(con, embed_enabled=embed_ok)
    return con, embed_ok


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--reindex":
        con = connect()
        ok = embed("ping") is not None
        n = reindex(con, force=True, embed_enabled=ok)
        print(f"reindexed {n} nodes (embeddings={'on' if ok else 'OFF'})")
        sys.exit(0)
    q = " ".join(args) or "auth flow"
    con, embed_ok = open_and_index()
    res, vec_used = search(con, q)
    print(f"query: {q!r}  (vector={'on' if vec_used else 'OFF'})\n")
    for r in res:
        print(f"  {r['score']:.4f}  [{r['subgraph']}]  {r['path']}")
        print(f"          {r['title']}")
