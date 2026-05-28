#!/usr/bin/env bash
# inject-context.sh — SessionStart hook target.
# Reads hook JSON on stdin, matches the cwd against the registry, and prints
# either a HIT context block (one or more matched subgraphs) or a MISS
# enrollment-needed block to stdout. Silent on paused sessions. Always exits 0.

set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$self_dir/common.sh"

read_hook_input

if is_paused "$HOOK_SESSION_ID"; then
  exit 0
fi

vroot=$(vault_root)
mapfile -t match_ids < <("$self_dir/match.sh" "$HOOK_CWD" 2>/dev/null)
first="${match_ids[0]:-MISS}"

if [[ "$first" == "MISS" || -z "$first" ]]; then
  cat <<EOF
## Vault context

NO SUBGRAPH MATCHED.
  cwd: $HOOK_CWD
  session: $HOOK_SESSION_ID

If knowledge work happens this session, you MUST invoke the vault skill in 'enroll' mode before capturing anything. Ask the user where this repo's knowledge should live (new top-level subgraph, under an existing namespace, attached to an existing subgraph, or skip).

Cross-cutting facts may still exist: you can search the whole vault with the \`vault_search\` MCP tool (semantic + keyword) even with no subgraph matched.
EOF
  exit 0
fi

# HIT: for each matched subgraph, look up its entry _index.md and extract the
# "Entry nodes" bullet list (the next-best curated jump-off points).
emit_entry_nodes() {
  local sid="$1"
  local entry_path
  entry_path=$(REGISTRY="$vroot/_registry.yaml" SUBGRAPH_ID="$sid" python3 - <<'PY'
import os, sys, yaml
try:
    with open(os.environ["REGISTRY"]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
sid = os.environ["SUBGRAPH_ID"]
for sg in data.get("subgraphs") or []:
    if sg.get("id") == sid:
        print(sg.get("entry") or ""); break
PY
)
  printf '### %s\n' "$sid"
  if [[ -n "$entry_path" ]]; then
    printf 'Entry: %s\n' "$entry_path"
  fi
  if [[ -n "$entry_path" && -f "$vroot/$entry_path" ]]; then
    awk '
      /^## Entry nodes/ { in_block=1; next }
      /^## / && in_block { in_block=0 }
      in_block && /^- / { print }
    ' "$vroot/$entry_path"
  else
    printf '(no _index.md / Entry nodes list — consider curating one)\n'
  fi
  printf '\n'
}

{
  printf '## Vault context\n\n'
  if (( ${#match_ids[@]} > 1 )); then
    printf 'Matched subgraphs: %s\n\n' "${match_ids[*]}"
  else
    printf 'Matched subgraph: %s\n\n' "${match_ids[0]}"
  fi
  for sid in "${match_ids[@]}"; do
    emit_entry_nodes "$sid"
  done
  cat <<EOF
Retrieval: read individual entry nodes lazily as the task touches them, OR use the \`vault_search\` MCP tool for semantic + keyword search across all matched subgraphs (ranked, decay-aware). Prefer vault_search when you don't already know which node holds the answer.

Vault skill is loaded. Actualize fires on Stop and PreCompact (and advises mid-session). Capture only durable, non-obvious knowledge — skip anything re-derivable from a single source file.
EOF
}
