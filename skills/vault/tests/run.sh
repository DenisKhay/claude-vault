#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$self_dir"

# shellcheck source=test_helper.sh
source ./test_helper.sh

shopt -s nullglob
for f in test_*.sh; do
  [[ "$f" == "test_helper.sh" ]] && continue
  echo "=== $f ==="
  # shellcheck disable=SC1090
  source "./$f"
done

report
