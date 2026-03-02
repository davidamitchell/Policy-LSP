#!/usr/bin/env bash
# lsp-start.sh — start gov-lsp in LSP server mode (stdio, Content-Length framing).
#
# Used as the command in .claude/lsp.json and .github/lsp.json so that
# Claude Code and GitHub Copilot Agent can register gov-lsp as a language
# server and receive textDocument/publishDiagnostics events in real time,
# exactly as an IDE editor client would.
#
# The server accepts any file type and evaluates it against policies/*.rego.
# Violations are published as LSP Diagnostics with severity, message, and
# optional fix metadata in Diagnostic.data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$REPO_ROOT/gov-lsp"

if [ ! -x "$BINARY" ]; then
  echo "[lsp-start] gov-lsp binary not found — building..." >&2
  (cd "$REPO_ROOT" && go build -o gov-lsp ./cmd/gov-lsp)
  echo "[lsp-start] build complete." >&2
fi

# Run in LSP server mode (default — no subcommand).
# Reads JSON-RPC from stdin, writes responses + notifications to stdout.
exec "$BINARY" "$@"
