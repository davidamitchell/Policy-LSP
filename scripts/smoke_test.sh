#!/usr/bin/env bash
# smoke_test.sh - Sends a mock LSP didOpen request for 'lower_case.md' and
# verifies the server returns a Diagnostic error with a SCREAMING_SNAKE_CASE fix.
#
# Usage:
#   ./scripts/smoke_test.sh [path-to-gov-lsp-binary]
#
# The binary defaults to ./gov-lsp (built from cmd/gov-lsp).

set -euo pipefail

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="${GOV_LSP_POLICIES:-./policies}"
TIMEOUT=5

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: binary not found or not executable: $BINARY" >&2
  echo "  Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

if [[ ! -d "$POLICIES_DIR" ]]; then
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 1
fi

# Helper: write one LSP message with Content-Length header.
lsp_msg() {
  local body="$1"
  printf "Content-Length: %d\r\n\r\n%s" "${#body}" "$body"
}

# Build the sequence of LSP messages to send.
INITIALIZE=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file:///workspace","capabilities":{}}}
EOF
)

INITIALIZED='{"jsonrpc":"2.0","method":"initialized","params":{}}'

DID_OPEN=$(cat <<'EOF'
{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///workspace/lower_case.md","languageId":"markdown","version":1,"text":"# hello\n"}}}
EOF
)

SHUTDOWN='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
EXIT='{"jsonrpc":"2.0","method":"exit","params":null}'

INPUT=$(printf '%s%s%s%s%s' \
  "$(lsp_msg "$INITIALIZE")" \
  "$(lsp_msg "$INITIALIZED")" \
  "$(lsp_msg "$DID_OPEN")" \
  "$(lsp_msg "$SHUTDOWN")" \
  "$(lsp_msg "$EXIT")")

# Run the server and capture output.
OUTPUT=$(echo "$INPUT" | timeout "$TIMEOUT" "$BINARY" --policies "$POLICIES_DIR" 2>/dev/null || true)

echo "=== Server output ==="
echo "$OUTPUT"
echo "====================="

# Strip Content-Length headers and parse the JSON bodies.
BODIES=$(echo "$OUTPUT" | grep -v '^Content-Length' | grep -v '^$' || true)

# Look for a publishDiagnostics notification.
if ! echo "$BODIES" | grep -q '"textDocument/publishDiagnostics"'; then
  echo "FAIL: no textDocument/publishDiagnostics notification received" >&2
  exit 1
fi

# Check that the diagnostic contains the expected violation.
if ! echo "$BODIES" | grep -q '"markdown-naming-violation"'; then
  echo "FAIL: diagnostic does not contain 'markdown-naming-violation'" >&2
  exit 1
fi

# Check the suggested fix value.
if ! echo "$BODIES" | grep -q '"LOWER_CASE.md"'; then
  echo "FAIL: fix value 'LOWER_CASE.md' not found in diagnostics" >&2
  exit 1
fi

# Check severity is 1 (Error).
if ! echo "$BODIES" | grep -q '"severity":1'; then
  echo "FAIL: expected severity 1 (error) in diagnostics" >&2
  exit 1
fi

echo "PASS: smoke test succeeded - LSP returned expected Diagnostic with SCREAMING_SNAKE_CASE fix"
