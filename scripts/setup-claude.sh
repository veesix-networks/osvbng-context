#!/usr/bin/env bash
# Installs Claude session config into the osvbng superproject checkout.
# Run once after clone, from anywhere inside the tree:
#   context/scripts/setup-claude.sh
# The superproject gitignores .claude/ and CLAUDE.md; the versioned
# copies live here so setup is one command and drift is a re-run.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(git -C "$here" rev-parse --show-superproject-working-tree)"
if [ -z "$root" ]; then
  echo "context is not checked out as a submodule; run from the osvbng tree" >&2
  exit 1
fi
mkdir -p "$root/.claude"
cp "$here/claude/settings.json" "$root/.claude/settings.json"
cp "$here/claude/CLAUDE.superproject.md" "$root/CLAUDE.md"
echo "installed .claude/settings.json and CLAUDE.md into $root"
