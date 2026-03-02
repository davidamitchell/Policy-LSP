#!/usr/bin/env bash
# mcp-start.sh — start the gov-lsp MCP server.
#
# Builds the binary first if it is missing, then exec's into the MCP mode.
# Used as the command in .mcp.json so that Claude Code and other MCP clients
# get a self-bootstrapping server without requiring a separate build step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$REPO_ROOT/gov-lsp"

if [ ! -x "$BINARY" ]; then
  echo "[mcp-start] gov-lsp binary not found — building..." >&2
  (cd "$REPO_ROOT" && go build -o gov-lsp ./cmd/gov-lsp)
  echo "[mcp-start] build complete." >&2
fi

exec "$BINARY" mcp "$@"
