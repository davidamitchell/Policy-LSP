#!/usr/bin/env bash
# sync-copilot-instructions.sh
#
# Copies the full contents of AGENTS.md into .github/copilot-instructions.md
# so GitHub Copilot's coding agent receives the complete project instructions
# rather than a short stub that references the file.
#
# Usage: bash scripts/sync-copilot-instructions.sh [repo-root]
#   repo-root defaults to the directory containing this script's parent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-"$(cd "$SCRIPT_DIR/.." && pwd)"}"

AGENTS_MD="$REPO_ROOT/AGENTS.md"
COPILOT_INSTRUCTIONS="$REPO_ROOT/.github/copilot-instructions.md"

if [[ ! -f "$AGENTS_MD" ]]; then
  echo "ERROR: $AGENTS_MD not found" >&2
  exit 1
fi

cp "$AGENTS_MD" "$COPILOT_INSTRUCTIONS"
echo "Copied $AGENTS_MD -> $COPILOT_INSTRUCTIONS"
