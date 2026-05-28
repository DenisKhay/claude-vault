#!/usr/bin/env bash
# match.sh <cwd>
# Reads ${VAULT_ROOT:-~/Vaults}/_registry.yaml and prints the matched subgraph ids,
# one per line (primary matches first, then namespace-shared subgraphs), or "MISS"
# if nothing matches. Always exits 0. Match priority within a subgraph: git_remote,
# repo_name, path_prefix. Multiple subgraphs may match the same cwd (e.g. a repo that
# holds both a frontend and its backend) — all are returned.

set -uo pipefail

cwd="${1:-$PWD}"
vault_root="${VAULT_ROOT:-$HOME/Vaults}"
registry="$vault_root/_registry.yaml"

if [[ ! -f "$registry" ]]; then
  echo "MISS"
  exit 0
fi

# Probe identity (best-effort; tolerate missing git, missing remote, etc.).
git_remote=""
repo_name=""
if [[ -d "$cwd" ]] && git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  git_remote=$(git -C "$cwd" remote get-url origin 2>/dev/null || echo "")
  toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "")
  repo_name=$(basename "$toplevel")
else
  repo_name=$(basename "$cwd")
fi

if [[ -d "$cwd" ]]; then
  abs_cwd=$(cd "$cwd" 2>/dev/null && pwd)
  abs_cwd_phys=$(cd "$cwd" 2>/dev/null && pwd -P)
else
  abs_cwd="$cwd"
  abs_cwd_phys="$cwd"
fi
abs_cwd="${abs_cwd%/}"
abs_cwd_phys="${abs_cwd_phys%/}"

GIT_REMOTE="$git_remote" REPO_NAME="$repo_name" CWD="$abs_cwd" CWD_PHYS="$abs_cwd_phys" REGISTRY="$registry" \
python3 - <<'PY'
import os, sys, yaml

git_remote = os.environ.get("GIT_REMOTE", "")
repo_name  = os.environ.get("REPO_NAME", "")
cwd        = os.environ.get("CWD", "")
cwd_phys   = os.environ.get("CWD_PHYS", "") or cwd

try:
    with open(os.environ["REGISTRY"]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print("MISS"); sys.exit(0)

# Skip malformed entries (no id) so one bad future entry degrades to MISS, not a crash.
subgraphs = [sg for sg in (data.get("subgraphs") or []) if isinstance(sg, dict) and sg.get("id")]

def as_list(v):
    if v is None: return []
    return v if isinstance(v, list) else [v]

def expand(p):
    return os.path.expanduser(p).rstrip("/")

def subgraph_matches(sg):
    m = sg.get("match") or {}
    if git_remote and git_remote in as_list(m.get("git_remote")):
        return True
    if repo_name and repo_name in as_list(m.get("repo_name")):
        return True
    for pre in as_list(m.get("path_prefix")):
        pre = expand(pre)
        if pre and any(c == pre or c.startswith(pre + "/") for c in (cwd, cwd_phys)):
            return True
    return False

def namespace_of(sg):
    ns = sg.get("namespace")
    if ns: return ns
    path = sg.get("path") or ""
    return path.split("/")[0] if "/" in path else None

# Primary matches (cwd -> subgraph). A cwd may match several subgraphs.
matched = [sg for sg in subgraphs if subgraph_matches(sg)]
matched_ids = [sg["id"] for sg in matched]
matched_namespaces = {namespace_of(sg) for sg in matched if namespace_of(sg)}

# Secondary: always-loaded-in-namespace subgraphs (e.g. <namespace>/shared) whenever a
# subgraph in that namespace matched. Never matched by cwd directly.
for sg in subgraphs:
    nin = sg.get("always_in_namespace")
    if nin and nin in matched_namespaces and sg["id"] not in matched_ids:
        matched_ids.append(sg["id"])

if not matched_ids:
    print("MISS"); sys.exit(0)

seen = set()
for mid in matched_ids:
    if mid not in seen:
        seen.add(mid); print(mid)
PY
