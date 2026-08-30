#!/usr/bin/env python3
"""Retrieval-quality benchmark: replay tests/bench/battery.json against the live
index and score hit@1 / hit@3 / hit@8 + latency, per category and overall.

The battery is the 2026-08-30 audit's 24 ground-truth queries (categories:
exact / paraphrase / cross / vague / recency), kept verbatim so every future run
is comparable to the audit's baselines:
    live keyword-only (pre-fix):        38% hit@1 / 67% hit@3
    hybrid + decay-dampen (predicted):  71% hit@1 / 92% hit@3

Run:  python3 bench.py            (uses the real vault + index)
      python3 bench.py --json     (machine-readable summary line)

GT paths that no longer exist in the vault are reported and scored as skipped —
a renamed node should be updated in battery.json, not silently dropped.
"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "retrieval"))
import vault_search as V  # noqa: E402


def main():
    battery = json.load(open(os.path.join(HERE, "battery.json")))
    con = V.connect()
    embed_ok = V.embed("ping") is not None
    V.reindex(con, embed_enabled=embed_ok)

    cats, rows = {}, []
    skipped = []
    t_total = 0.0
    for item in battery:
        gt = set(item["gt"])
        exists = {g for g in gt
                  if con.execute("SELECT 1 FROM docs WHERE path=?", (g,)).fetchone()}
        if not exists:
            skipped.append(item["id"])
            continue
        t0 = time.perf_counter()
        res, _vec = V.search(con, item["q"], k=8)
        dt = (time.perf_counter() - t0) * 1000
        t_total += dt
        paths = [r["path"] for r in res]
        h1 = any(p in exists for p in paths[:1])
        h3 = any(p in exists for p in paths[:3])
        h8 = any(p in exists for p in paths[:8])
        rows.append((item["id"], item["cat"], h1, h3, h8, dt))
        c = cats.setdefault(item["cat"], [0, 0, 0, 0])
        c[0] += 1
        c[1] += h1
        c[2] += h3
        c[3] += h8

    n = len(rows)
    H1 = sum(1 for r in rows if r[2])
    H3 = sum(1 for r in rows if r[3])
    H8 = sum(1 for r in rows if r[4])

    if "--json" in sys.argv:
        print(json.dumps({
            "n": n, "vector": embed_ok,
            "hit@1": round(H1 / n, 3), "hit@3": round(H3 / n, 3), "hit@8": round(H8 / n, 3),
            "avg_ms": round(t_total / n, 1),
            "cats": {k: {"n": v[0], "hit@1": v[1], "hit@3": v[2], "hit@8": v[3]}
                     for k, v in sorted(cats.items())},
            "skipped": skipped,
        }))
        return 0

    print(f"vault bench: {n} queries, vector={'on' if embed_ok else 'OFF'}")
    print(f"  hit@1 {H1}/{n} ({H1/n:.0%})   hit@3 {H3}/{n} ({H3/n:.0%})   "
          f"hit@8 {H8}/{n} ({H8/n:.0%})   avg {t_total/n:.1f} ms")
    for cat, (cn, c1, c3, c8) in sorted(cats.items()):
        print(f"  {cat:12} hit@1 {c1}/{cn}  hit@3 {c3}/{cn}  hit@8 {c8}/{cn}")
    for rid, cat, h1, h3, h8, dt in rows:
        if not h3:
            print(f"  MISS@3 {rid} ({cat})")
    if skipped:
        print(f"  SKIPPED (gt path gone — update battery.json): {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
