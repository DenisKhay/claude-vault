#!/usr/bin/env python3
"""Regenerate each subgraph's "## Entry nodes" block from node frontmatter.

WHY (locked decision D2 of the multi-machine design): entry-node bullets are the
hottest-write lines in the whole store — every capture sweep that adds a node
appends one. Hand-appended prose in a shared file is the classic merge-conflict
surface, and the conflict lands in `_index.md`, which is exactly the file injected
into every SessionStart. A conflict marker there is read by an LLM as prose.

The fix is to stop merging the file and start deriving it. A node declares its own
pointer in its frontmatter:

    entry: when to open this node

...and this script rewrites the block from those declarations. Two machines adding
different nodes then produce the same file from the same inputs, so a conflict in
the derived block is resolved by regenerating rather than by hand-merging.

ORDER IS PART OF THE CONTRACT. Bullets are emitted oldest-first (by `created`,
then path), because `emit-context.py` budgets the injected list newest-first by
reversing it — an alphabetical sort would silently un-prioritise the newest
captures, which is the delivery bug S7 fixed. Ties break on path so the output is
byte-identical on every machine.

Never truncates: a bullet over the 110-char limit is an ERROR, matching
registry-lint. Silent truncation is how a pointer becomes a lie.

Usage:
  index-regen.py [--check] [subgraph-id ...]
     no ids     every subgraph in the registry
     --check    report what would change, write nothing, exit 1 if anything would
"""
import os
import re
import sys

VAULT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
BULLET_MAX = 110
HEADING = "## Entry nodes"

try:
    import yaml
except Exception:
    print("index-regen: pyyaml missing")
    sys.exit(1)


def frontmatter(path):
    """Return the YAML frontmatter dict, or {} — never raises on a bad node."""
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            if f.readline().strip() != "---":
                return {}
            buf = []
            for line in f:
                if line.strip() == "---":
                    break
                buf.append(line)
        return yaml.safe_load("".join(buf)) or {}
    except Exception:
        return {}


def collect(subgraph_dir, exclude_dirs=()):
    """Every node under a subgraph that declares an `entry:` pointer.

    exclude_dirs holds the roots of subgraphs NESTED inside this one. The registry
    really has such a case — `figma-rig` lives at `claude-config/figma-rig` — and
    without this the parent absorbs the child's nodes, listing them under a longer
    relative path that also blows the 110-char bullet limit. A node belongs to
    exactly one index: the deepest subgraph that contains it.
    """
    out = []
    excl = tuple(os.path.normpath(d) for d in exclude_dirs)
    for dirpath, dirnames, filenames in os.walk(subgraph_dir):
        if any(os.path.normpath(dirpath) == e or os.path.normpath(dirpath).startswith(e + os.sep)
               for e in excl):
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if not d.startswith((".", "_"))]
        for fn in filenames:
            if not fn.endswith(".md") or fn.startswith("_"):
                continue
            full = os.path.join(dirpath, fn)
            meta = frontmatter(full)
            text = str(meta.get("entry") or "").strip()
            if not text:
                continue
            rel = os.path.relpath(full, subgraph_dir)[: -len(".md")]
            link = str(meta.get("entry_link") or "").strip() or rel
            out.append((str(meta.get("created") or ""), rel, text, link))
    # oldest-first: emit-context budgets newest-first by reversing this list
    out.sort(key=lambda r: (r[0], r[1]))
    return out


def render(entries):
    lines, over = [], []
    for _created, rel, text, link in entries:
        bullet = f"- [[{link}]] — {text}"
        if len(bullet) > BULLET_MAX:
            over.append((rel, len(bullet)))
        lines.append(bullet)
    return lines, over


BULLET_RE = re.compile(r"^-\s+\[\[([^\]]+)\]\]")


def preserve_foreign(entry_file, derived_targets):
    """Existing bullets this script cannot derive — kept verbatim, never dropped.

    A regenerator that rewrites a whole block deletes anything it does not
    understand, which is the exact supersede-never-delete violation this design
    exists to prevent. The real vault has such a bullet: pantheon's index points at
    `shared/dependencies/figma-mcp-oauth-expiry`, a node in ANOTHER subgraph, so no
    `entry:` key inside this subgraph can produce it. Cross-subgraph pointers and
    hand-written entries survive regeneration untouched; a bullet only disappears
    when a derived one replaces it for the same target.
    """
    kept, inblock = [], False
    for line in open(entry_file, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith(HEADING):
            inblock = True
            continue
        if inblock and line.startswith("## "):
            break
        if not inblock or not line.strip():
            continue
        m = BULLET_RE.match(line)
        if not m:
            continue
        target = m.group(1).split("|")[0].strip().lstrip("./")
        if target not in derived_targets:
            kept.append(line)
    return kept


def splice(entry_file, bullets):
    """Replace only the Entry-nodes block; everything else in the file is kept."""
    with open(entry_file, encoding="utf-8") as f:
        src = f.read().splitlines()
    out, i, found = [], 0, False
    while i < len(src):
        out.append(src[i])
        if src[i].startswith(HEADING):
            found = True
            i += 1
            while i < len(src) and not src[i].strip():
                i += 1
            out.append("")
            out.extend(bullets)
            while i < len(src) and not src[i].startswith("## "):
                i += 1
            if i < len(src):
                out.append("")
            continue
        i += 1
    return ("\n".join(out) + "\n") if found else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv

    reg_path = os.path.join(VAULT, "_registry.yaml")
    try:
        data = yaml.safe_load(open(reg_path)) or {}
    except Exception as e:
        print(f"index-regen: cannot read registry: {e}")
        return 1

    all_paths = [str(sg.get("path") or "") for sg in (data.get("subgraphs") or [])
                 if isinstance(sg, dict)]

    changed, errors = 0, 0
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

        my_path = str(sg.get("path") or "")
        nested = [os.path.join(VAULT, p) for p in all_paths
                  if p != my_path and p.startswith(my_path + "/")]
        entries = collect(sub_dir, nested)
        if not entries:
            continue          # nothing declares `entry:` yet — leave the file alone
        bullets, over = render(entries)
        for rel, n in over:
            print(f"E bullet-overflow {sid}: {rel} would render {n} chars (max {BULLET_MAX}) "
                  f"— shorten its `entry:` frontmatter")
            errors += 1
        if over:
            continue

        # Foreign/hand-written bullets go last: emit-context budgets newest-first
        # by reversing, so a deliberate manual pointer keeps top priority.
        # Match on BOTH forms: a bullet is "ours" whether it was written as a bare
        # relpath or with this subgraph's prefix convention.
        known = {rel for _c, rel, _t, _l in entries} | {lk for _c, _r, _t, lk in entries}
        foreign = preserve_foreign(entry_file, known)
        if foreign and check:
            print(f"  {sid}: preserving {len(foreign)} non-derivable bullet(s)")
        bullets = bullets + foreign

        new = splice(entry_file, bullets)
        if new is None:
            print(f"E no-entry-heading {sid}: {entry_file} has no '{HEADING}' section")
            errors += 1
            continue
        with open(entry_file, encoding="utf-8") as f:
            cur = f.read()
        if new != cur:
            changed += 1
            if check:
                print(f"would rewrite {sid}: {len(bullets)} bullet(s)")
            else:
                with open(entry_file, "w", encoding="utf-8") as f:
                    f.write(new)
                print(f"regenerated {sid}: {len(bullets)} bullet(s)")

    if errors:
        print(f"index-regen: {errors} error(s)")
        return 1
    if check and changed:
        return 1
    print(f"index-regen: {changed} file(s) {'would change' if check else 'changed'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
