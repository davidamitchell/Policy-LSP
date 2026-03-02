#!/usr/bin/env bash
# policy-gate.sh — PostToolUse hook for Claude Code
#
# Triggered after every Write, Edit, or MultiEdit tool call.
# Reads tool context from stdin (JSON), extracts the modified file path,
# runs gov-lsp check on that file, and exits 1 with violation output if
# any policy violations are found.
#
# Exit codes:
#   0  no violations
#   1  policy violations found, OR binary unavailable (fail closed)
set -uo pipefail

# ---- read tool context -------------------------------------------------------
INPUT=$(cat)

# Extract file_path from tool_input using jq if available, fall back to python3.
FILE_PATH=""
if command -v jq &>/dev/null; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
elif command -v python3 &>/dev/null; then
  FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null)
fi

[ -z "$FILE_PATH" ] && exit 0

# ---- locate the gov-lsp binary -----------------------------------------------
BINARY=""
if [ -x "./gov-lsp" ]; then
  BINARY="./gov-lsp"
elif command -v gov-lsp &>/dev/null; then
  BINARY="gov-lsp"
else
  # Attempt an inline build. Use -mod=vendor when vendor/ is present so this
  # works in network-restricted environments (e.g. Claude Code web sandboxes).
  if command -v go &>/dev/null && [ -f "go.mod" ]; then
    if [ -d "./vendor" ]; then
      go build -mod=vendor -o ./gov-lsp ./cmd/gov-lsp 2>/dev/null && BINARY="./gov-lsp" || true
    else
      go build -o ./gov-lsp ./cmd/gov-lsp 2>/dev/null && BINARY="./gov-lsp" || true
    fi
  fi
fi

# Binary not available — fail closed to prevent silent policy bypass.
if [ -z "$BINARY" ]; then
  printf '\n=== GOV-LSP POLICY GATE: ENFORCEMENT UNAVAILABLE ===\n'
  printf 'The gov-lsp binary could not be found or built.\n'
  printf 'Policy enforcement is NOT active — violations may go undetected.\n\n'
  printf 'To fix: run `make build` (requires Go and network, or vendor/ dir).\n'
  printf 'See: https://github.com/davidamitchell/Policy-LSP#getting-started\n'
  exit 1
fi

# ---- run policy check --------------------------------------------------------
OUTPUT=$("$BINARY" check --format text "$FILE_PATH" 2>/dev/null)
STATUS=$?

if [ "$STATUS" -ne 0 ] && [ -n "$OUTPUT" ]; then
  printf '\n=== GOV-LSP POLICY VIOLATIONS ===\n'
  printf 'File: %s\n\n' "$FILE_PATH"
  printf '%s\n\n' "$OUTPUT"
  printf 'Fix these violations before completing this task.\n'
  exit 1
fi

exit 0
