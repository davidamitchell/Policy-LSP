#!/usr/bin/env bash
# test_headless_agent.sh — Policy enforcement test for the headless-agent scenario.
#
# Scenario
# --------
# A headless agent (such as GitHub Copilot via the gh CLI) is working in a
# repository without IDE tooling.  The agent is asked to "create a notes file"
# and—without the guardrails an IDE LSP client provides—produces a lowercase
# filename (notes.md) that violates the SCREAMING_SNAKE_CASE policy.
#
# In a real session the agent step would look like this:
#
#   gh copilot suggest -t shell "create a notes file in the current directory"
#   # Copilot suggests: echo "# Notes" > notes.md
#   # Agent executes the suggestion: echo "# Notes" > notes.md
#
# gh copilot suggest requires authentication and interactive approval, so the
# agent's file-creation action is simulated directly here.  The mechanism under
# test is gov-lsp check, not gh copilot itself.
#
# Expected outcome
# ----------------
# The policy check "fails" — gov-lsp reports a violation for the lowercase
# filename.  That is the correct enforcement outcome and therefore PASSES this
# test.  The test script exits non-zero only when enforcement is broken (i.e.
# gov-lsp unexpectedly reports no violations).
#
# Cleanup guarantee
# -----------------
# A temporary workspace is created at the start.  The EXIT trap removes it
# unconditionally, regardless of pass or failure.
#
# Usage
# -----
#   bash scripts/test_headless_agent.sh [path-to-gov-lsp-binary]
#
# Environment
# -----------
#   GOV_LSP_POLICIES   directory containing .rego files (default: ./policies)

set -uo pipefail

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="${GOV_LSP_POLICIES:-./policies}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- preflight ---------------------------------------------------------------

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY" >&2
  echo "  Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

if [[ ! -d "$POLICIES_DIR" ]]; then
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 1
fi

# ---- workspace (always cleaned up on exit) -----------------------------------

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

echo "Test workspace: $WORKSPACE"
echo ""

# ---- agent step: create a markdown file with a lowercase name ----------------
#
# This represents the action a headless gh copilot agent would take when told
# to create a notes file.  Without IDE LSP feedback the agent has no guardrails
# and chooses the natural but non-compliant name notes.md.

AGENT_FILE="$WORKSPACE/notes.md"
echo "# Notes" > "$AGENT_FILE"
echo "Agent created: $AGENT_FILE"
echo ""

# ---- enforcement: run gov-lsp check ------------------------------------------
#
# gov-lsp check is the enforcement layer available to headless agents.  It exits
# non-zero when violations are found, making it suitable as a CI gate or a
# post-action hook (analogous to .claude/hooks/policy-gate.sh for Claude Code).

CHECK_OUTPUT=""
CHECK_EXIT=0
CHECK_OUTPUT=$(GOV_LSP_POLICIES="$POLICIES_DIR" "$BINARY" check "$AGENT_FILE" 2>&1) \
  || CHECK_EXIT=$?

echo "=== gov-lsp check output ==="
echo "$CHECK_OUTPUT"
echo "============================"
echo ""

# ---- assertions --------------------------------------------------------------

# Test 1: gov-lsp must report a violation (exit non-zero) for the lowercase file.
if [[ "$CHECK_EXIT" -ne 0 ]]; then
  pass "gov-lsp check exits non-zero — the policy check failed as expected (enforcement working)"
else
  fail "gov-lsp check should exit non-zero for lowercase .md but reported no violations"
fi

# Test 2: the violation must carry the expected policy ID.
if echo "$CHECK_OUTPUT" | grep -q "markdown-naming-violation"; then
  pass "violation id 'markdown-naming-violation' present in output"
else
  fail "'markdown-naming-violation' not found in output"
fi

# Test 3: the suggested fix must rename to SCREAMING_SNAKE_CASE.
if echo "$CHECK_OUTPUT" | grep -q "NOTES.md"; then
  pass "fix suggestion 'NOTES.md' present in output"
else
  fail "fix suggestion 'NOTES.md' not found in output"
fi

# Test 4: gov-lsp is advisory — it must not mutate the file.
if [[ -f "$AGENT_FILE" ]]; then
  pass "agent file still present (gov-lsp reports violations but does not rename or delete)"
else
  fail "agent file was unexpectedly removed by gov-lsp check"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
cat <<'NOTE'
Scenario summary
────────────────
  The headless agent created notes.md (lowercase, violates SCREAMING_SNAKE_CASE).
  gov-lsp check detected the violation and suggested NOTES.md as the fix.
  The agent's file was not automatically corrected; enforcement is advisory at
  the check layer.  A CI gate (|| exit 1) or a post-action hook enforces the
  policy by failing the pipeline when violations are present.
NOTE

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
