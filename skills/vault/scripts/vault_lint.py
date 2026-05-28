#!/usr/bin/env python3
"""Vault hygiene lint (L1) + unlinked-mention suggestions (L2).

Reports only GENUINE defects — deliberately ignores _templates/ (intentional
placeholders) and treats leaf nodes with inbound links as non-orphans. Read-only;
suggests, never edits. Run on demand or wire to a weekly schedule.
"""
import os, re, sys, collections

VAULT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
SKIP = {".index", ".obsidian", ".git", ".claude", "_templates"}


def nodes():
    for dp, dn, fns in os.walk(VAULT):
        dn[:] = [d for d in dn if d not in SKIP]
        for fn in fns:
            if fn.endswith(".md") and not fn.startswith("."):
                full = os.path.join(dp, fn)
                yield full, os.path.relpath(full, VAULT)


def split_fm(text):
    if text.startswith("---"):
        e = text.find("\n---", 3)
        if e != -1:
            return text[3:e], text[e + 4:]
    return "", text


def main():
    empty, bad_fm, archived = [], [], 0
    outlinks = collections.defaultdict(set)
    inlinks = collections.defaultdict(set)
    title_to_paths, bodies, basenames = collections.defaultdict(list), {}, collections.defaultdict(list)
    all_rel = []

    for full, rel in nodes():
        all_rel.append(rel)
        text = open(full, encoding="utf-8", errors="ignore").read()
        if os.path.getsize(full) == 0:
            empty.append(rel); continue
        fm, body = split_fm(text)
        if "status: archived" in fm or re.search(r"^status:\s*archived", fm, re.M):
            archived += 1; continue
        # frontmatter defects (real ones only — outside templates)
        if re.search(r"\{\{date\}\}|<YYYY-MM-DD>", fm):
            bad_fm.append(rel)
        if not fm.strip():
            bad_fm.append(rel + "  (no frontmatter)")
        base = os.path.basename(rel)[:-3]
        basenames[base].append(rel)
        key = rel[:-3]
        bodies[key] = body
        mt = re.search(r"^#\s+(.+)$", body, re.M)
        if mt:
            title_to_paths[mt.group(1).strip().lower()].append(key)
        for m in re.findall(r"\[\[([^\]]+)\]\]", body):
            tgt = m.split("|")[0].split("#")[0].strip()
            outlinks[key].add(tgt)

    # resolve link targets to keys: exact, then UNIQUE full-path suffix, then UNIQUE
    # basename — never guess on ambiguity (10 basenames collide), which previously
    # misattributed inbound links and produced a flaky false orphan.
    keys = set(bodies)
    def resolve(t):
        if t in keys:
            return t
        suf = [k for k in keys if k.endswith("/" + t)]
        if len(suf) == 1:
            return suf[0]
        if len(suf) > 1:
            return None
        bn = os.path.basename(t)
        base = [k for k in keys if os.path.basename(k) == bn]
        return base[0] if len(base) == 1 else None
    resolved_out = {}
    for src, tgts in outlinks.items():
        rset = set()
        for t in tgts:
            r = resolve(t)
            if r:
                inlinks[r].add(src)
                rset.add(r)
        resolved_out[src] = rset

    true_orphans = [k for k in keys
                    if not outlinks.get(k) and not inlinks.get(k)
                    and not k.endswith("_index")]
    dup = {b: ps for b, ps in basenames.items() if len(ps) > 1 and b != "_index"}

    # L2: unlinked mentions — a node's title appears in another node's body with no
    # wiki-link to it. Precision filters kill the dominant noise: colliding titles
    # (no unique target), single common words, too-short titles, and matches inside
    # longer hyphenated identifiers. "Already linked?" compares RESOLVED targets.
    COMMON = {"button", "dialog", "dashboard", "messages", "settings", "sidebar",
              "overview", "tooltip", "scrollbar", "profile", "notifications",
              "header", "footer", "modal", "card", "table", "layout", "navigation"}
    suggestions = []
    for title, tgts in title_to_paths.items():
        if len(tgts) != 1:
            continue  # colliding title — no unique target to suggest
        tgt = tgts[0]
        single = " " not in title
        if single and (len(title) < 8 or title in COMMON):
            continue
        pat = (re.compile(r"(?<![\w-])" + re.escape(title) + r"(?![\w-])", re.I) if single
               else re.compile(re.escape(title), re.I))
        for k, body in bodies.items():
            if k == tgt or tgt in resolved_out.get(k, ()):
                continue
            if pat.search(body):
                suggestions.append((k, tgt, title))

    print(f"# Vault lint — {len(all_rel)} nodes ({archived} archived, excluded)\n")
    def section(name, items):
        print(f"## {name}: {len(items)}")
        for i in items[:40]:
            print("  -", i)
        if len(items) > 40: print(f"  … +{len(items)-40} more")
        print()
    section("Empty (0-byte) files", empty)
    section("Real frontmatter defects (placeholders / missing, non-template)", bad_fm)
    section("True orphans (no inbound AND no outbound links)", true_orphans)
    print(f"## Duplicate basenames across subgraphs: {len(dup)}")
    for b, ps in list(dup.items())[:20]:
        print(f"  - {b}: {', '.join(ps)}")
    print()
    section("L2 unlinked-mention suggestions (consider adding [[link]])",
            [f"{k}  →  [[{t}]]  (mentions “{ti}”)" for k, t, ti in suggestions])


if __name__ == "__main__":
    main()
