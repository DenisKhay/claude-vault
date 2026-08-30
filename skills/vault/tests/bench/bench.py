#!/usr/bin/env python3
"""Retrieval-quality benchmark for the vault index.

TWO batteries, because they answer different questions and only one of them is a
quality measure:

  battery.json          the 2026-08-30 audit's 24 queries, kept verbatim so every
                        run stays comparable to that baseline. They were authored
                        FROM the text of the nodes they target, so they largely
                        restate a node's own vocabulary. That makes them a fine
                        REGRESSION harness and a poor quality measure — the
                        re-audit confirmed the headline 71/92/96 does not survive
                        queries phrased in anyone else's words.

  battery_heldout.json  30 queries in symptom voice — how someone searches BEFORE
                        they know a node's vocabulary ("the lock screen keeps
                        rejecting my correct password", not "kscreenlocker pam
                        service fprintd"). This is the quality measure.

Neither claim rests on trusting how the queries were written, because the harness
MEASURES the thing that was wrong: `overlap` is the fraction of a query's content
words that literally appear in its target node, and every result is stratified by
it. A battery whose queries share most of their words with their targets says so
in its own report.

It also runs a keyword-only ablation, so the semantic layer's real contribution is
a first-class number instead of something re-derived by hand during an audit.

Run:  python3 bench.py                 both batteries + overlap bands + ablation
      python3 bench.py --legacy        only the comparable audit battery
      python3 bench.py --heldout       only the held-out battery
      python3 bench.py --no-ablate     skip the keyword-only pass
      python3 bench.py --json          machine-readable summary

GT paths that no longer exist are reported and scored as skipped — a renamed node
should be updated in the battery, not silently dropped.
"""
import json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "retrieval"))
import vault_search as V  # noqa: E402

STOP = {
    "the", "and", "for", "was", "are", "but", "not", "you", "your", "with", "that",
    "this", "from", "have", "has", "had", "its", "it", "is", "in", "on", "of", "to",
    "a", "an", "my", "me", "i", "at", "by", "or", "as", "be", "been", "do", "does",
    "did", "so", "if", "when", "what", "how", "why", "can", "could", "would",
    "should", "will", "there", "here", "they", "them", "then", "than", "into",
    "out", "up", "off", "all", "any", "some", "no", "yes", "get", "got", "even",
    "still", "after", "before", "while", "once", "keeps", "keep", "actually",
}

BANDS = [(0.0, 0.20, "0-20%"), (0.20, 0.40, "20-40%"),
         (0.40, 0.60, "40-60%"), (0.60, 1.01, "60-100%")]


def words(text):
    return {w for w in re.findall(r"[a-z0-9]+", text.lower())
            if len(w) >= 3 and w not in STOP}


def overlap(con, query, gt_paths):
    """Fraction of the query's content words that literally appear in the target.

    The instrument the old battery lacked. High overlap means the query restates
    the node, so a hit measures little more than string matching.
    """
    qw = words(query)
    if not qw:
        return 0.0
    best = 0.0
    for p in gt_paths:
        row = con.execute("SELECT title, body FROM docs WHERE path=?", (p,)).fetchone()
        if not row:
            continue
        dw = words((row[0] or "") + " " + (row[1] or "")) | words(p)
        best = max(best, len(qw & dw) / len(qw))
    return best


def run_battery(con, battery, keyword_only=False):
    rows, skipped, t_total = [], [], 0.0
    real_embed = V.embed
    if keyword_only:
        V.embed = lambda _t: None          # the only consumer of the query vector
    try:
        for item in battery:
            gt = set(item["gt"])
            exists = {g for g in gt
                      if con.execute("SELECT 1 FROM docs WHERE path=?", (g,)).fetchone()}
            if not exists:
                skipped.append(item["id"])
                continue
            ov = overlap(con, item["q"], exists)
            t0 = time.perf_counter()
            res, _vec = V.search(con, item["q"], k=8)
            dt = (time.perf_counter() - t0) * 1000
            t_total += dt
            paths = [r["path"] for r in res]
            rows.append({
                "id": item["id"], "cat": item["cat"], "overlap": ov, "ms": dt,
                "h1": any(p in exists for p in paths[:1]),
                "h3": any(p in exists for p in paths[:3]),
                "h8": any(p in exists for p in paths[:8]),
            })
    finally:
        V.embed = real_embed
    return rows, skipped, t_total


def pct(n, d):
    return f"{round(100 * n / d)}%" if d else "n/a"


def summarize(rows):
    n = len(rows)
    return {
        "n": n,
        "h1": sum(r["h1"] for r in rows),
        "h3": sum(r["h3"] for r in rows),
        "h8": sum(r["h8"] for r in rows),
        "overlap": (sum(r["overlap"] for r in rows) / n) if n else 0.0,
        "ms": (sum(r["ms"] for r in rows) / n) if n else 0.0,
    }


def report(label, rows, skipped, ablated=None):
    s = summarize(rows)
    n = s["n"]
    print(f"\n=== {label} ===")
    print(f"  n={n}  hit@1 {s['h1']}/{n} ({pct(s['h1'], n)})"
          f"   hit@3 {s['h3']}/{n} ({pct(s['h3'], n)})"
          f"   hit@8 {s['h8']}/{n} ({pct(s['h8'], n)})"
          f"   avg {s['ms']:.1f} ms")
    print(f"  mean query/target word overlap: {s['overlap'] * 100:.0f}%")
    if ablated is not None:
        a = summarize(ablated)
        delta = round(100 * (s["h1"] - a["h1"]) / max(n, 1))
        print(f"  keyword-only ablation: hit@1 {pct(a['h1'], a['n'])}"
              f"   hit@3 {pct(a['h3'], a['n'])}   hit@8 {pct(a['h8'], a['n'])}"
              f"   -> semantic layer worth {delta:+d} pts of hit@1")

    print("  by query/target overlap:")
    for lo, hi, name in BANDS:
        band = [r for r in rows if lo <= r["overlap"] < hi]
        if not band:
            continue
        b = summarize(band)
        print(f"    {name:>8}  n={b['n']:<3} hit@1 {pct(b['h1'], b['n']):>4}"
              f"  hit@3 {pct(b['h3'], b['n']):>4}  hit@8 {pct(b['h8'], b['n']):>4}")

    cats = {}
    for r in rows:
        cats.setdefault(r["cat"], []).append(r)
    print("  by category:")
    for c, rs in sorted(cats.items()):
        b = summarize(rs)
        print(f"    {c:>10}  n={b['n']:<3} hit@1 {pct(b['h1'], b['n']):>4}"
              f"  hit@3 {pct(b['h3'], b['n']):>4}  hit@8 {pct(b['h8'], b['n']):>4}")

    misses = [r["id"] for r in rows if not r["h8"]]
    if misses:
        print(f"  MISS@8: {', '.join(misses)}")
    if skipped:
        print(f"  SKIPPED (ground truth no longer in the vault): {', '.join(skipped)}")


def main():
    want_legacy = "--heldout" not in sys.argv
    want_heldout = "--legacy" not in sys.argv
    ablate = "--no-ablate" not in sys.argv

    con = V.connect()
    embed_ok = V.embed("ping") is not None
    V.reindex(con, embed_enabled=embed_ok)
    if not embed_ok:
        print("NOTE: embeddings unavailable — the numbers below ARE keyword-only.")

    out = {}
    for flag, fname, label in (
        (want_legacy, "battery.json",
         "LEGACY battery - regression harness only (queries written from node text)"),
        (want_heldout, "battery_heldout.json",
         "HELD-OUT battery - the quality measure (symptom-voice queries)"),
    ):
        if not flag:
            continue
        path = os.path.join(HERE, fname)
        if not os.path.exists(path):
            continue
        battery = json.load(open(path))
        rows, skipped, _t = run_battery(con, battery)
        abl = run_battery(con, battery, keyword_only=True)[0] if ablate else None
        report(label, rows, skipped, abl)
        s = summarize(rows)
        out[fname] = {"n": s["n"], "vector": embed_ok,
                      "hit@1": round(s["h1"] / s["n"], 3) if s["n"] else 0,
                      "hit@3": round(s["h3"] / s["n"], 3) if s["n"] else 0,
                      "hit@8": round(s["h8"] / s["n"], 3) if s["n"] else 0,
                      "mean_overlap": round(s["overlap"], 3),
                      "avg_ms": round(s["ms"], 1)}

    if "--json" in sys.argv:
        print("\n" + json.dumps(out, sort_keys=True))
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
