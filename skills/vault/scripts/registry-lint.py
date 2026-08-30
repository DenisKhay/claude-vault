#!/usr/bin/env python3
"""Registry lint: validate ~/Vaults/_registry.yaml against the vault tree and
this machine's repos. The registry had NO validator for its whole life, and one
silently-broken block (repo_name pointing at a nonexistent repo) kept a
17-node subgraph out of every session for weeks — this is the guard for that
class.

Checks (E = error → exit 1, W = warning, I = info):
  E dup-id            two subgraphs share an id
  E path-missing      subgraph `path` does not exist under the vault root
  E entry-missing     `entry` file does not exist
  W no-match          entry has no match block at all
  W no-git-remote     match lacks git_remote (breaks portability to other machines)
  W dead-identity     NONE of the match identities resolves on this machine
                      (every path_prefix absent AND no local repo has that
                      remote/name) — the exact rot class that hid claude-config
  W unregistered-dir  a top-level vault dir no registry path covers (injected nowhere)
  E bullet-overflow   entry-file "Entry nodes" bullets over 110 chars (write-time rule).
                      An ERROR, not a warning: SKILL.md makes the capture agent run this
                      as its write-time gate, and a warning is invisible under --quiet.

Usage: registry-lint.py [--quiet]   (VAULT_ROOT env overrides ~/Vaults)
"""
import os, sys, glob

VAULT = os.environ.get("VAULT_ROOT", os.path.expanduser("~/Vaults"))
PROJECTS = os.path.expanduser("~/Projects")
BULLET_MAX = 110

try:
    import yaml
except Exception:
    print("registry-lint: pyyaml missing — cannot lint")
    sys.exit(1)


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def local_remotes():
    """origin URLs of every repo directly under ~/Projects (cheap: read config)."""
    remotes = {}
    for cfg in glob.glob(os.path.join(PROJECTS, "*", ".git", "config")):
        try:
            text = open(cfg, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        repo = os.path.basename(os.path.dirname(os.path.dirname(cfg)))
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("url = "):
                remotes.setdefault(line[6:].strip(), repo)
    return remotes


def main():
    quiet = "--quiet" in sys.argv
    reg_path = os.path.join(VAULT, "_registry.yaml")
    if not os.path.exists(reg_path):
        print(f"E registry-missing {reg_path}")
        return 1
    try:
        data = yaml.safe_load(open(reg_path)) or {}
    except Exception as e:
        print(f"E registry-unparsable {e}")
        return 1

    subgraphs = [sg for sg in (data.get("subgraphs") or []) if isinstance(sg, dict)]
    errors, warns = [], []
    seen_ids = set()
    covered_roots = set()
    remotes = local_remotes()
    local_repo_names = {os.path.basename(p) for p in glob.glob(os.path.join(PROJECTS, "*")) if os.path.isdir(p)}

    for sg in subgraphs:
        sid = sg.get("id") or "<no-id>"
        if sid in seen_ids:
            errors.append(f"E dup-id {sid}")
        seen_ids.add(sid)
        path = str(sg.get("path") or "")
        if not path or not os.path.isdir(os.path.join(VAULT, path)):
            errors.append(f"E path-missing {sid}: {path!r}")
        else:
            covered_roots.add(path.split("/")[0])
        entry = str(sg.get("entry") or "")
        entry_full = os.path.join(VAULT, entry)
        if not entry or not os.path.isfile(entry_full):
            errors.append(f"E entry-missing {sid}: {entry!r}")
        else:
            in_block, over = False, 0
            for line in open(entry_full, encoding="utf-8", errors="ignore"):
                line = line.rstrip("\n")
                if line.startswith("## Entry nodes"):
                    in_block = True
                    continue
                if line.startswith("## ") and in_block:
                    break
                if in_block and line.startswith("- ") and len(line) > BULLET_MAX:
                    over += 1
            if over:
                errors.append(f"E bullet-overflow {sid}: {over} bullet(s) over {BULLET_MAX} chars in {entry}")

        m = sg.get("match")
        if sg.get("always_in_namespace"):
            continue  # shared subgraphs are loaded via namespace, not matched by cwd
        if not m:
            warns.append(f"W no-match {sid}")
            continue
        if not as_list(m.get("git_remote")):
            warns.append(f"W no-git-remote {sid} (unportable: machine-local paths only)")
        alive = False
        for pre in as_list(m.get("path_prefix")):
            if os.path.isdir(os.path.expanduser(str(pre))):
                alive = True
        for r in as_list(m.get("git_remote")):
            if str(r) in remotes:
                alive = True
        for rn in as_list(m.get("repo_name")):
            if str(rn) in local_repo_names:
                alive = True
        if not alive:
            warns.append(f"W dead-identity {sid}: no path_prefix exists and no local repo "
                         f"matches its remote/name on this machine")

    for d in sorted(os.listdir(VAULT)):
        if d.startswith((".", "_")) or not os.path.isdir(os.path.join(VAULT, d)):
            continue
        if d not in covered_roots:
            warns.append(f"W unregistered-dir {d}/ (no registry path covers it — injected nowhere)")

    for e in errors:
        print(e)
    if not quiet:
        for w in warns:
            print(w)
    print(f"registry-lint: {len(subgraphs)} subgraphs, {len(errors)} error(s), {len(warns)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
