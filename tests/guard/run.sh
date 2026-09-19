#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for t in test_*.sh; do
  echo "== $t"; bash "$t"
done
echo "all guard tests passed"
