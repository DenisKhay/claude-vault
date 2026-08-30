#!/usr/bin/env python3
"""One-time migration: move hand-written "## Entry nodes" bullets INTO the nodes
they point at, as an `entry:` frontmatter key, so `index-regen.py` can derive the
block from now on (locked decision D2).

Losslessness is the whole job. A bullet whose target cannot be resolved with
confidence is REPORTED and LEFT ALONE — never dropped, never guessed at. Run with
--check first; it writes nothing and tells you exactly what would happen.

Verification after migrating: run `index-regen.py --check`. If migration was
lossless, every subgraph regenerates to the same set of bullets it already had.

Usage: index-migrate.py [--check] [subgraph-id ...]
"""
import os
import re
import sys

VAULT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
HEADING = "## Entry nodes"
BULLET = re.compile(r"^-\s+\[\[([^\]]+)\]\]\s*[—-]\s*(.+?)\s*$")

try:
    import yaml
except Exception:
    print("index-migrate: pyyaml missing")
    sys.exit(1)


def resolve(sub_dir, target):
    """Resolve a wiki-link target to a file under the subgraph, or None.

    Deliberately conservative: an ambiguous basename returns None so the caller
    reports it instead of writing the pointer onto the wrong node.
    """
    cands = [target]
    if "|" in target:                      # [[label|path]] and [[path|label]]
        cands = [p.strip() for p in target.split("|", 1)] + cands
    for c in cands:
        c = c.strip().lstrip("./")
        direct = os.path.join(sub_dir, c + ".md")
        if os.path.isfile(direct):
            return direct
    hits = []
    for c in cands:
        base = os.path.basename(c.strip()) + ".md"
        for dirpath, dirnames, filenames in os.walk(sub_dir):
            dirnames[:] = [d for d in dirnames if not d.startswith((".", "_"))]
            for fn in filenames:
                if fn == base:
                    hits.append(os.path.join(dirpath, fn))
        if hits:
            break
    return hits[0] if len(hits) == 1 else None


def set_entry(path, text, check, link=None):
    """Insert/replace `entry:` in a node's frontmatter. Returns a status string."""
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if not src.startswith("---"):
        return "no-frontmatter"
    end = src.find("\n---", 3)
    if end == -1:
        return "no-frontmatter"
    head, body = src[3:end], src[end:]
    try:
        meta = yaml.safe_load(head) or {}
    except Exception:
        return "unparsable-frontmatter"
    if str(meta.get("entry") or "").strip() == text:
        return "already"
    lines = [ln for ln in head.splitlines()
             if not ln.startswith("entry:") and not ln.startswith("entry_link:")]
    # Quote it: pointer text is full of colons and dashes that would break YAML.
    lines.append("entry: " + yaml.safe_dump(text, default_flow_style=True,
                                            allow_unicode=True).strip().rstrip("\n..."))
    if link:
        # The vault does not use ONE wiki-link convention: lifedl/portals writes
        # [[portals/orders/orders]] (subgraph-prefixed) while claude-config writes
        # [[architecture/vault-system]] (bare relpath). Regenerating with a single
        # invented form would rewrite ~219 links and, worse, leave the originals
        # unmatched so both copies survived. Record the exact original instead.
        lines.append("entry_link: " + yaml.safe_dump(link, default_flow_style=True,
                     allow_unicode=True).strip().rstrip("\n..."))
    if not check:
        with open(path, "w", encoding="utf-8") as f:
            f.write("---" + "\n".join(lines) + body)
    return "written"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    data = yaml.safe_load(open(os.path.join(VAULT, "_registry.yaml"))) or {}

    tot = {"written": 0, "already": 0, "unresolved": 0, "skipped": 0}
    unresolved = []
    for sg in data.get("subgraphs") or []:
        if not isinstance(sg, dict):
            continue
        sid = sg.get("id")
        if args and sid not in args:
            continue
        sub_dir = os.path.join(VAULT, str(sg.get("path") or ""))
        entry_file = os.path.join(VAULT, str(sg.get("entry") or ""))
        if not os.path.isdir(sub_dir) or not os.path.isfile(entry_file):
            continue

        inblock = False
        for line in open(entry_file, encoding="utf-8"):
            line = line.rstrip("\n")
            if line.startswith(HEADING):
                inblock = True
                continue
            if inblock and line.startswith("## "):
                break
            if not inblock:
                continue
            m = BULLET.match(line)
            if not m:
                continue
            target, text = m.group(1), m.group(2).strip()
            node = resolve(sub_dir, target)
            if not node:
                tot["unresolved"] += 1
                unresolved.append(f"  {sid}: [[{target}]] — target not resolvable, bullet LEFT IN PLACE")
                continue
            rel = os.path.relpath(node, sub_dir)[: -len(".md")]
            st = set_entry(node, text, check, link=(target if target != rel else None))
            if st in ("written", "already"):
                tot[st] += 1
            else:
                tot["skipped"] += 1
                unresolved.append(f"  {sid}: {os.path.relpath(node, VAULT)} — {st}, LEFT IN PLACE")

    for u in unresolved:
        print(u)
    verb = "would write" if check else "wrote"
    print(f"index-migrate: {verb} {tot['written']}, already-set {tot['already']}, "
          f"unresolved {tot['unresolved']}, skipped {tot['skipped']}")
    return 1 if (tot["unresolved"] or tot["skipped"]) else 0


if __name__ == "__main__":
    sys.exit(main())
