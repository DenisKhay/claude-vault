#!/usr/bin/env python3
"""Hybrid retrieval over the Markdown vault.

- SQLite FTS5 (BM25) keyword ranking + nomic-embed-text (Ollama) vector cosine,
  fused with Reciprocal Rank Fusion (RRF, k=60).
- Decay-aware: results get a mild recency boost from frontmatter `updated`.
- Soft-delete: nodes with `status: archived` are excluded from the index.
- Incremental: only re-embeds files whose content hash changed.
- Degrades gracefully to FTS5-only when Ollama is unreachable.

CLI:  python3 vault_search.py "query text"      # search
      python3 vault_search.py --reindex          # force full reindex
"""
import os, sys, re, json, sqlite3, hashlib, urllib.request, math, datetime, struct

VAULT_ROOT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
INDEX_DIR  = os.path.join(VAULT_ROOT, ".index")
DB_PATH    = os.path.join(INDEX_DIR, "vault.db")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.environ.get("VAULT_EMBED_MODEL", "nomic-embed-text")
RRF_K = 60
DECAY_HALFLIFE_DAYS = 120.0   # mild recency prior
SKIP_DIRS = {".index", ".obsidian", ".git", ".claude", "_templates"}

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
    con = sqlite3.connect(DB_PATH)
    con.execute("""CREATE TABLE IF NOT EXISTS docs(
        path TEXT PRIMARY KEY, title TEXT, subgraph TEXT, body TEXT,
        updated TEXT, hash TEXT, emb BLOB)""")
    con.execute("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(path, title, body, subgraph)")
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


def reindex(con, force=False, embed_enabled=True):
    cur = con.cursor()
    existing = {row[0]: (row[1], bool(row[2]))
                for row in cur.execute("SELECT path, hash, emb IS NOT NULL FROM docs")}
    seen, changed = set(), 0
    for full, rel in iter_nodes():
        try:
            text = open(full, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        meta, body = parse_frontmatter(text)
        if str(meta.get("status", "")).lower() == "archived":
            continue  # soft-deleted: out of the retrieval surface
        seen.add(rel)
        h = hashlib.sha1(text.encode("utf-8", "ignore")).hexdigest()
        prev = existing.get(rel)
        # Skip only if unchanged AND (embeddings off this run, or it already has one).
        # Otherwise a row indexed during an Ollama outage keeps a NULL emb forever.
        if not force and prev and prev[0] == h and (not embed_enabled or prev[1]):
            continue
        changed += 1
        title = None
        mt = re.search(r"^#\s+(.+)$", body, re.M)
        title = mt.group(1).strip() if mt else os.path.basename(rel)[:-3]
        sg = subgraph_of(rel)
        updated = str(meta.get("updated") or meta.get("created") or "")
        emb_blob = None
        if embed_enabled:
            vec = embed(title + "\n" + body)
            if vec:
                emb_blob = struct.pack("<%df" % len(vec), *vec)
        cur.execute("INSERT OR REPLACE INTO docs VALUES(?,?,?,?,?,?,?)",
                    (rel, title, sg, body, updated, h, emb_blob))
        cur.execute("DELETE FROM fts WHERE path=?", (rel,))
        cur.execute("INSERT INTO fts(path,title,body,subgraph) VALUES(?,?,?,?)",
                    (rel, title, body, sg))
    # prune deleted / newly-archived
    for rel in list(existing):
        if rel not in seen:
            cur.execute("DELETE FROM docs WHERE path=?", (rel,))
            cur.execute("DELETE FROM fts WHERE path=?", (rel,))
    con.commit()
    return changed


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
    sub_set = set(subgraphs) if subgraphs else None
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
    # vector ranks via cosine over stored embeddings — scope-filtered before the cap.
    vec = {}
    qv = embed(query)
    vector_used = bool(qv) and np is not None   # numpy gates the only consumer of qv
    if vector_used:
        qa = np.array(qv, dtype="float32")
        qa /= (np.linalg.norm(qa) + 1e-9)
        cand = []
        for path, blob in cur.execute("SELECT path, emb FROM docs WHERE emb IS NOT NULL"):
            if not in_scope(path):
                continue
            arr = np.frombuffer(blob, dtype="float32")
            if arr.shape[0] != qa.shape[0]:
                continue
            cand.append((path, float(np.dot(arr, qa) / (np.linalg.norm(arr) + 1e-9))))
        cand.sort(key=lambda x: -x[1])
        for rank, (path, _s) in enumerate(cand[:60]):
            vec[path] = rank
    # Reciprocal Rank Fusion + decay (candidates are already scope-filtered)
    meta = {row[0]: row[1] for row in cur.execute("SELECT path, updated FROM docs")}
    scores = {}
    for path in set(kw) | set(vec):
        s = 0.0
        if path in kw:  s += 1.0 / (RRF_K + kw[path])
        if path in vec: s += 1.0 / (RRF_K + vec[path])
        decay = math.exp(-math.log(2) * days_since(meta.get(path)) / DECAY_HALFLIFE_DAYS)
        scores[path] = s * (0.6 + 0.4 * decay)   # decay nudges, never dominates
    ranked = sorted(scores.items(), key=lambda x: -x[1])[:k]
    out = []
    for path, sc in ranked:
        title = cur.execute("SELECT title FROM docs WHERE path=?", (path,)).fetchone()
        out.append({"path": path, "title": title[0] if title else path,
                    "subgraph": sub_meta.get(path), "score": round(sc, 5)})
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
