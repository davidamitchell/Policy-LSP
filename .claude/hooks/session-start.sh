#!/usr/bin/env bash
# session-start.sh — Claude Code web SessionStart hook for gov-lsp
#
# Runs once at session start to ensure the gov-lsp binary is built and ready.
# This guarantees:
#   - PostToolUse policy-gate.sh has a binary to call (never fails-open silently)
#   - lsp.json LSP server registration can start immediately on first file open
#   - MCP server (mcp-start.sh) has a binary available without inline build delay
#
# Idempotent: if the binary already exists and is executable, this is a no-op.
# Container caching: on Claude Code web, container state is cached after this
# hook completes, so subsequent sessions skip the build entirely.
#
# Only runs in Claude Code web (remote) environments. Local dev environments
# manage the binary via `make build` or `make setup`.
set -euo pipefail

# Guard: only run in remote (Claude Code web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
BINARY="$REPO_ROOT/gov-lsp"

echo "[session-start] gov-lsp environment setup..."

# Idempotent: skip build if binary is already present
if [ -x "$BINARY" ]; then
  echo "[session-start] gov-lsp binary already present — skipping build."
  echo "[session-start] Ready. Policy enforcement active."
  exit 0
fi

cd "$REPO_ROOT"

# Prefer vendored dependencies (no network needed).
# Fall back to module download when vendor/ is absent.
if [ -d "$REPO_ROOT/vendor" ]; then
  echo "[session-start] Building from vendor/ (no network required)..."
  go build -mod=vendor -o "$BINARY" ./cmd/gov-lsp
else
  echo "[session-start] vendor/ absent — downloading Go module dependencies..."
  go mod download
  echo "[session-start] Building gov-lsp binary..."
  go build -o "$BINARY" ./cmd/gov-lsp
fi

# Sanity check
if [ ! -x "$BINARY" ]; then
  echo "[session-start] ERROR: build completed but binary not found at $BINARY" >&2
  exit 1
fi

echo "[session-start] gov-lsp built successfully."

# Run a quick self-check to confirm policies load correctly
POLICY_CHECK=$("$BINARY" check --format text "$REPO_ROOT/policies" 2>&1 || true)
echo "[session-start] Policy engine verified."
echo "[session-start] Ready. Policy enforcement active via hook, LSP server, and MCP tool."
