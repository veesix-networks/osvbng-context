#!/usr/bin/env bash
# Fails when decisions/ and the README index disagree.
set -euo pipefail
cd "$(dirname "$0")/.."
missing=0
for f in decisions/[0-9]*.md; do
  n=$(basename "$f" | cut -d- -f1)
  [ "$n" = "0000" ] && continue
  grep -q "decisions/$(basename "$f")" README.md || {
    echo "not in README index: $f" >&2
    missing=1
  }
done
exit $missing
