#!/usr/bin/env python3
"""Probe the archived-node ranking contract against a throwaway fixture vault.

Two properties have to hold at once, and they pull in opposite directions —
which is why the penalty needs a test rather than a remembered number:

  findable  an archived node must still come back within the default k=8 when it
            is the only thing that answers the query. At 0.5 this failed for 45
            of the real vault's 49 archived nodes: halving an RRF score moves a
            result to roughly the bottom of the candidate pool, so the intended
            demotion worked as a delete. Consolidation archives superseded nodes,
            so that silently unfinds content the merge contract promised to keep.

  demoted   a LIVE node must still outrank an archived one on the same topic.
            Dropping the penalty entirely breaks this — the archived copy starts
            winning over the canonical node it was superseded by.

Prints "findable=<rank> demoted=<yes|no>" and exits non-zero if either fails.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def build_fixture(root):
    os.makedirs(os.path.join(root, "sg"), exist_ok=True)
    with open(os.path.join(root, "_registry.yaml"), "w") as f:
        f.write("subgraphs:\n  - id: sg\n    path: sg\n    entry: sg/_index.md\n"
                "    match:\n      repo_name: sg\n")
    with open(os.path.join(root, "sg", "_index.md"), "w") as f:
        f.write("# sg\n\n## Entry nodes\n\n- [[sg/live-topic]] — the canonical one\n")

    # Competition. The burial only reproduces in a corpus deep enough to have
    # somewhere to bury into: halving an RRF score puts a top hit behind whatever
    # sits ~20 ranks down, so without partial matches to fall behind, a 4-document
    # fixture passes at ANY penalty and tests nothing. These share the query's
    # weaker term ("husbandry") but never the distinctive one ("quokka").
    for i in range(40):
        with open(os.path.join(root, "sg", f"filler-{i:02d}.md"), "w") as f:
            f.write(f"---\ntype: reference\nproject: sg\ncreated: 2026-01-01\n"
                    f"updated: 2026-01-01\ntags: [husbandry]\n---\n\n"
                    f"# Husbandry note {i}\n\nGeneral husbandry guidance number {i}.\n")

    # Only this node mentions quokkas: nothing else can answer that query.
    with open(os.path.join(root, "sg", "archived-unique.md"), "w") as f:
        f.write("---\ntype: reference\nproject: sg\nstatus: archived\n"
                "created: 2026-01-01\nupdated: 2026-01-01\ntags: [quokka]\n---\n\n"
                "# Quokka husbandry notes\n\nQuokka husbandry: quokkas need shade and figs.\n")

    # A live/archived pair on ONE topic, so ordering between them is observable.
    with open(os.path.join(root, "sg", "live-topic.md"), "w") as f:
        f.write("---\ntype: reference\nproject: sg\ncreated: 2026-01-01\n"
                "updated: 2026-01-01\ntags: [wombat]\n---\n\n"
                "# Wombat burrow mechanics\n\nWombat burrow mechanics: burrows are cubic.\n")
    with open(os.path.join(root, "sg", "archived-topic.md"), "w") as f:
        f.write("---\ntype: reference\nproject: sg\nstatus: archived\n"
                "created: 2026-01-01\nupdated: 2026-01-01\ntags: [wombat]\n---\n\n"
                "# Wombat burrow mechanics\n\nWombat burrow mechanics: burrows are cubic.\n")


def main():
    root = tempfile.mkdtemp(prefix="vault-archived-probe-")
    build_fixture(root)
    os.environ["VAULT_ROOT"] = root
    sys.path.insert(0, os.path.join(HERE, "..", "retrieval"))
    import vault_search as V

    con = V.connect()
    V.reindex(con, embed_enabled=False)   # keyword-only: no Ollama dependency in tests

    res, _ = V.search(con, "quokka husbandry", k=8)
    paths = [r["path"] for r in res]
    findable = next((i + 1 for i, p in enumerate(paths)
                     if p.endswith("archived-unique.md")), None)

    res2, _ = V.search(con, "wombat burrow mechanics", k=8)
    order = [r["path"] for r in res2]
    li = next((i for i, p in enumerate(order) if p.endswith("live-topic.md")), None)
    ai = next((i for i, p in enumerate(order) if p.endswith("archived-topic.md")), None)
    demoted = li is not None and (ai is None or li < ai)

    print(f"findable={findable} demoted={'yes' if demoted else 'no'} "
          f"penalty={V.ARCHIVED_PENALTY}")

    ok = True
    if findable is None:
        print("FAIL: an archived node that uniquely answers a query is not in the default k=8")
        ok = False
    if not demoted:
        print("FAIL: an archived node is not ranked below the live node on the same topic")
        ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
