#!/usr/bin/env bash
# bootstrap.sh — one-time setup of the vault DATA root (~/Vaults) on a new machine.
# Idempotent: never overwrites an existing registry, index, or node.
#
#   bash scripts/bootstrap.sh           # uses ~/Vaults
#   VAULT_ROOT=/path bash scripts/bootstrap.sh
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_ROOT="${VAULT_ROOT:-$HOME/Vaults}"
TPL="$PLUGIN_ROOT/skills/vault/templates"

mkdir -p "$VAULT_ROOT/.index" "$VAULT_ROOT/_templates"

# Node + subgraph templates (used by the skill's enroll/actualize modes).
cp -n "$TPL"/*.md "$VAULT_ROOT/_templates/" 2>/dev/null || true

# Empty registry — enroll repos later with /vault-enroll. See _registry.example.yaml.
if [[ ! -f "$VAULT_ROOT/_registry.yaml" ]]; then
  printf 'subgraphs: []\n' > "$VAULT_ROOT/_registry.yaml"
fi

# Root index node.
if [[ ! -f "$VAULT_ROOT/_index.md" ]]; then
  today="$(date +%F)"
  cat > "$VAULT_ROOT/_index.md" <<EOF
---
type: subgraph-index
created: $today
updated: $today
---

# Vault Root

Single global knowledge graph for Claude Code. Subgraphs are registered in
\`_registry.yaml\`; run \`/vault-enroll\` inside a repo to add it.
EOF
fi

echo "✓ Vault data root ready at: $VAULT_ROOT"
echo "  Registry:  $VAULT_ROOT/_registry.yaml   (edit, or use /vault-enroll)"
echo "  Templates: $VAULT_ROOT/_templates/"
echo
echo "Optional — build the hybrid search index now (needs python3 + pyyaml; numpy + Ollama for embeddings):"
echo "  python3 \"$PLUGIN_ROOT/skills/vault/retrieval/vault_search.py\" --reindex"
