#!/usr/bin/env bash
# governance_loop.sh — Compatibility shim.
#
# The governance loop implementation has moved to the isolated directory:
#   scripts/governance_loop/governance_loop.sh
#
# This shim exists so any scripts that still reference the old path continue
# to work without modification.  All arguments and environment variables are
# forwarded unchanged.
#
# To use the canonical path directly:
#   bash scripts/governance_loop/governance_loop.sh [gov-lsp-binary]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/governance_loop/governance_loop.sh" "$@"
