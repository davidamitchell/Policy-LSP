#!/usr/bin/env bash
# test_policy_gate.sh — unit tests for .claude/hooks/policy-gate.sh
#
# Tests the four distinct exit-code paths of the hook:
#   1. No file_path in tool_input  → exit 0 (no-op)
#   2. Binary unavailable          → exit 1 with ENFORCEMENT UNAVAILABLE message
#   3. File has policy violations  → exit 1 with violation output
#   4. File has no violations      → exit 0
#
# Usage:
#   bash scripts/test_policy_gate.sh [path-to-gov-lsp-binary]
#
# The binary defaults to ./gov-lsp. Tests that need it are skipped when
# it is absent; the fail-closed test always runs.

set -uo pipefail

BINARY="${1:-./gov-lsp}"
HOOK=".claude/hooks/policy-gate.sh"
POLICIES_DIR="${GOV_LSP_POLICIES:-./policies}"
PASS=0
FAIL=0

# ---- helpers -----------------------------------------------------------------

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- setup -------------------------------------------------------------------

if [[ ! -f "$HOOK" ]]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 1
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---- test 1: no file_path → exit 0 ------------------------------------------

INPUT_NO_PATH='{"tool_name":"Write","tool_input":{}}'
STATUS=0
HOOK_OUT=$(printf '%s' "$INPUT_NO_PATH" | bash "$HOOK" 2>&1) || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "no file_path in input exits 0 (no-op)"
else
  fail "no file_path in input should exit 0, got $STATUS"
fi

# ---- test 2: binary unavailable → exit 1 with ENFORCEMENT UNAVAILABLE -------

# Run the hook from a temp dir that has no ./gov-lsp and no go.mod.
# Use a minimal PATH (/usr/bin:/bin) so python3 is available for file_path
# extraction but go and gov-lsp are not reachable.
ISOLATED_DIR=$(mktemp -d)
trap 'rm -rf "$ISOLATED_DIR" "$TMPDIR_TEST"' EXIT

INPUT_WITH_PATH='{"tool_name":"Write","tool_input":{"file_path":"/tmp/some_file.md"}}'
ORIG_DIR="$(pwd)"

STATUS=0
HOOK_OUT=$(cd "$ISOLATED_DIR" && printf '%s' "$INPUT_WITH_PATH" \
  | PATH="/usr/bin:/bin" bash "$ORIG_DIR/$HOOK" 2>&1) || STATUS=$?
if [ "$STATUS" -eq 1 ]; then
  if echo "$HOOK_OUT" | grep -q "ENFORCEMENT UNAVAILABLE"; then
    pass "binary unavailable exits 1 with ENFORCEMENT UNAVAILABLE message"
  else
    fail "binary unavailable exits 1 but message missing ENFORCEMENT UNAVAILABLE"
  fi
else
  fail "binary unavailable should exit 1 (fail-closed), got $STATUS"
fi

# ---- tests 3 & 4 require the gov-lsp binary ----------------------------------

if [[ ! -x "$BINARY" ]]; then
  echo "SKIP: tests 3 & 4 require $BINARY (run 'go build -o gov-lsp ./cmd/gov-lsp' first)"
  echo ""
  echo "Results: $PASS passed, $FAIL failed, 2 skipped"
  [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
fi

# ---- test 3: violating file → exit 1 with violation output ------------------

VIOLATING_FILE="$TMPDIR_TEST/lower_case.md"
printf '# hello\n' > "$VIOLATING_FILE"

INPUT_VIOLATING=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$VIOLATING_FILE")

STATUS=0
HOOK_OUT=$(printf '%s' "$INPUT_VIOLATING" \
  | GOV_LSP_POLICIES="$POLICIES_DIR" PATH="$(dirname "$BINARY"):$PATH" bash "$HOOK" 2>&1) || STATUS=$?
if [ "$STATUS" -eq 1 ]; then
  if echo "$HOOK_OUT" | grep -q "GOV-LSP POLICY VIOLATIONS"; then
    pass "violating file exits 1 with GOV-LSP POLICY VIOLATIONS header"
  else
    fail "violating file exits 1 but output missing GOV-LSP POLICY VIOLATIONS"
  fi
else
  fail "violating file should exit 1, got $STATUS"
fi

# ---- test 4: compliant file → exit 0 ----------------------------------------

VALID_FILE="$TMPDIR_TEST/VALID_DOC.md"
printf '# valid\n' > "$VALID_FILE"

INPUT_VALID=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$VALID_FILE")

STATUS=0
HOOK_OUT=$(printf '%s' "$INPUT_VALID" \
  | GOV_LSP_POLICIES="$POLICIES_DIR" PATH="$(dirname "$BINARY"):$PATH" bash "$HOOK" 2>&1) || STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "compliant file exits 0"
else
  fail "compliant file should exit 0, got $STATUS (output: $HOOK_OUT)"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
