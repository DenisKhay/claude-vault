#!/usr/bin/env bash
# Locked decision D2: the "Entry nodes" block must be DERIVED from node frontmatter,
# not hand-merged prose. It is the hottest-write region of the store — every sweep
# that adds a node appends a bullet — and a merge conflict there lands in the exact
# file injected at every SessionStart, where an LLM reads the markers as prose.

ir_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ir_scripts="$(cd "$ir_self_dir/../scripts" && pwd)"

_ir_vault() {   # build a throwaway vault, echo its root
  local root; root="$(mktemp -d)"
  mkdir -p "$root/sg/architecture" "$root/sg/bugs"
  cat > "$root/_registry.yaml" <<YAML
subgraphs:
  - id: sg
    path: sg
    entry: sg/_index.md
    match:
      repo_name: sg
YAML
  printf '# sg\n\n## Entry nodes\n\n- [[architecture/old]] — hand written, to be replaced\n\n## Notes\n\nkeep me\n' > "$root/sg/_index.md"
  cat > "$root/sg/architecture/old.md" <<'MD'
---
type: architecture
project: sg
created: 2026-01-01
updated: 2026-01-01
tags: [a]
entry: the older one
---
# Old
MD
  cat > "$root/sg/bugs/newer.md" <<'MD'
---
type: bug
project: sg
created: 2026-06-01
updated: 2026-06-01
tags: [b]
entry: the newer one
---
# Newer
MD
  cat > "$root/sg/architecture/silent.md" <<'MD'
---
type: architecture
project: sg
created: 2026-03-01
updated: 2026-03-01
tags: [c]
---
# Not an entry node
MD
  echo "$root"
}

root="$(_ir_vault)"
out=$(VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "index-regen: regenerates cleanly ($out)"

body=$(cat "$root/sg/_index.md")
assert_contains "- [[architecture/old]] — the older one" "$body" "index-regen: a declared entry node is rendered"
assert_contains "- [[bugs/newer]] — the newer one" "$body" "index-regen: nested folders render their relative path"
if [[ "$body" == *"silent"* ]]; then got=leaked; else got=absent; fi
assert_eq "absent" "$got" "index-regen: a node without an entry: key is NOT listed"
if [[ "$body" == *"hand written, to be replaced"* ]]; then got=stale; else got=replaced; fi
assert_eq "replaced" "$got" "index-regen: the old hand-written bullet is replaced by the derived one"
assert_contains "keep me" "$body" "index-regen: the rest of the index file is preserved"

# Order is contract: oldest first, because emit-context budgets newest-first by
# reversing. An alphabetical sort would silently deprioritise the newest captures.
older_line=$(grep -n "the older one" "$root/sg/_index.md" | cut -d: -f1)
newer_line=$(grep -n "the newer one" "$root/sg/_index.md" | cut -d: -f1)
[[ "$older_line" -lt "$newer_line" ]] && got=oldest-first || got=wrong-order
assert_eq "oldest-first" "$got" "index-regen: bullets are ordered oldest-first by created date"

# Deriving is only useful if it is deterministic: same inputs, same bytes.
before=$(md5sum "$root/sg/_index.md" | cut -d' ' -f1)
VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" >/dev/null 2>&1
after=$(md5sum "$root/sg/_index.md" | cut -d' ' -f1)
assert_eq "$before" "$after" "index-regen: idempotent — a second run changes nothing"

out=$(VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" --check 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "index-regen: --check exits 0 when the file is already current"
rm -rf "$root"

# --- an over-long pointer is an ERROR, never silently truncated --------------
root="$(_ir_vault)"
long=$(head -c 140 /dev/zero | tr '\0' 'x')
python3 - "$root/sg/bugs/newer.md" "$long" <<'PY'
import sys, pathlib
p, long = pathlib.Path(sys.argv[1]), sys.argv[2]
p.write_text(p.read_text().replace("entry: the newer one", f"entry: {long}"))
PY
out=$(VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" 2>&1) && ec=$? || ec=$?
assert_exit "1" "$ec" "index-regen: an over-long bullet fails instead of being truncated"
assert_contains "bullet-overflow" "$out" "index-regen: the overflow names the offending node"
rm -rf "$root"

# --- migration must be lossless ---------------------------------------------
root="$(mktemp -d)"
mkdir -p "$root/sg/architecture"
cat > "$root/_registry.yaml" <<YAML
subgraphs:
  - id: sg
    path: sg
    entry: sg/_index.md
    match:
      repo_name: sg
YAML
printf '# sg\n\n## Entry nodes\n\n- [[architecture/thing]] — when the thing breaks\n- [[architecture/ghost]] — points at nothing\n' > "$root/sg/_index.md"
cat > "$root/sg/architecture/thing.md" <<'MD'
---
type: architecture
project: sg
created: 2026-02-02
updated: 2026-02-02
tags: [t]
---
# Thing
MD
out=$(VAULT_ROOT="$root" python3 "$ir_scripts/index-migrate.py" 2>&1) && ec=$? || ec=$?
assert_contains "entry: when the thing breaks" "$(cat "$root/sg/architecture/thing.md")" "index-migrate: the bullet text lands in the node's frontmatter"
assert_contains "not resolvable" "$out" "index-migrate: an unresolvable target is reported"
assert_contains "LEFT IN PLACE" "$out" "index-migrate: an unresolvable bullet is never dropped"
assert_contains "points at nothing" "$(cat "$root/sg/_index.md")" "index-migrate: the unresolved bullet is still in the index"
rm -rf "$root"

# --- a bullet the regenerator cannot derive must SURVIVE regeneration ---------
# The real vault has one: pantheon's index points into lifedl/shared/, a node in a
# different subgraph, so no entry: key inside pantheon can produce that bullet. A
# regenerator that rewrites the whole block would delete it — the exact
# supersede-never-delete violation this whole design exists to prevent.
root="$(_ir_vault)"
python3 - "$root/sg/_index.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "## Entry nodes\n",
    "## Entry nodes\n\n- [[../other-subgraph/deps/thing]] — a cross-subgraph pointer\n"))
PY
VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" >/dev/null 2>&1
body=$(cat "$root/sg/_index.md")
assert_contains "a cross-subgraph pointer" "$body" "index-regen: a non-derivable bullet survives regeneration"
assert_contains "the newer one" "$body" "index-regen: derived bullets are still written alongside it"
# and it must stay stable across repeated runs
before=$(md5sum "$root/sg/_index.md" | cut -d' ' -f1)
VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" >/dev/null 2>&1
after=$(md5sum "$root/sg/_index.md" | cut -d' ' -f1)
assert_eq "$before" "$after" "index-regen: preserved bullets do not duplicate on re-run"
rm -rf "$root"

# --- link CONVENTION must survive: the vault does not use just one --------------
# lifedl/portals writes [[portals/orders/orders]] (subgraph-prefixed); claude-config
# writes [[architecture/vault-system]] (bare relpath). A regenerator that imposes one
# form rewrites ~219 real links AND leaves the originals unmatched, so both copies
# survive — 569 bullets became 787 before this was fixed.
root="$(mktemp -d)"
mkdir -p "$root/sg/orders"
cat > "$root/_registry.yaml" <<YAML
subgraphs:
  - id: sg
    path: sg
    entry: sg/_index.md
    match:
      repo_name: sg
YAML
printf '# sg\n\n## Entry nodes\n\n- [[sg/orders/thing]] — prefixed link style\n' > "$root/sg/_index.md"
cat > "$root/sg/orders/thing.md" <<'MD'
---
type: architecture
project: sg
created: 2026-04-04
updated: 2026-04-04
tags: [x]
---
# Thing
MD
VAULT_ROOT="$root" python3 "$ir_scripts/index-migrate.py" >/dev/null 2>&1
assert_contains "entry_link:" "$(cat "$root/sg/orders/thing.md")" "index-migrate: a non-relpath link form is recorded on the node"
VAULT_ROOT="$root" python3 "$ir_scripts/index-regen.py" >/dev/null 2>&1
body=$(cat "$root/sg/_index.md")
assert_contains "- [[sg/orders/thing]] — prefixed link style" "$body" "index-regen: the original link form is reproduced exactly"
n=$(grep -c "prefixed link style" <<<"$body")
assert_eq "1" "$n" "index-regen: the bullet is not duplicated by a differently-formed twin"
rm -rf "$root"
