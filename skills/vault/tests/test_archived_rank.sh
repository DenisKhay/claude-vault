#!/usr/bin/env bash
# The archived-node ranking contract. `status: archived` is a soft delete: the node
# must stay REACHABLE while ranking below live material. Shipped at ×0.5 it was a
# hide, not a demotion — measured on the real vault, 0 of 49 archived nodes ranked
# #1 for their own title and only 4 of 49 landed inside the default k=8. Since
# consolidation archives the nodes it supersedes, that silently unfound exactly the
# content the supersede-never-delete contract exists to preserve.

arch_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$arch_self_dir/archived_rank_probe.py"

out=$(python3 "$PROBE" 2>&1) && ec=$? || ec=$?
assert_exit "0" "$ec" "archived: findable within default k AND demoted below live ($out)"
