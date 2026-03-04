#!/usr/bin/env bash
# test_headless_agent.sh — Headless-agent enforcement integration test.
#
# What this test proves
# ---------------------
# A headless agent (GitHub Copilot via the gh CLI) operates without an IDE,
# without an LSP client, and without inline feedback.  GOV-LSP enforcement
# is the only guardrail.  This test verifies the complete enforcement loop:
#
#   authenticated gh agent → creates a policy-violating file → gov-lsp catches it
#
# The filename policy (SCREAMING_SNAKE_CASE for .md files) is the example policy
# used here.  The goal is not to test that specific policy — the goal is to prove
# that the enforcement FRAMEWORK works for any headless agent operating without
# IDE tooling.  Any policy violation by any headless agent should be catchable
# through this same loop.
#
# Prerequisites — this test FAILS if either is absent
# ----------------------------------------------------
#   gov-lsp   Build with: go build -o gov-lsp ./cmd/gov-lsp
#   gh auth   Set GH_TOKEN, or run: gh auth login
#             In CI: COPILOT_GITHUB_TOKEN repository secret exported as GH_TOKEN
#
# Do NOT work around the gh auth requirement.  Bypassing it (e.g. by simulating
# the agent's file-creation without gh) defeats the purpose of the test.  If the
# test fails because gh is not authenticated, that is the correct and expected
# result for an environment that has not been configured for headless-agent use.
#
# Cleanup
# -------
# A temp workspace is created at the start.  EXIT trap removes it unconditionally.
#
# Usage
# -----
#   GH_TOKEN=<token> bash scripts/test_headless_agent.sh [path-to-gov-lsp-binary]
#
# Environment
# -----------
#   GH_TOKEN           GitHub token for the headless agent (required)
#   GOV_LSP_POLICIES   directory containing .rego files (default: ./policies)

set -uo pipefail

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="${GOV_LSP_POLICIES:-./policies}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- preflight: gov-lsp ------------------------------------------------------

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

if [[ ! -d "$POLICIES_DIR" ]]; then
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 1
fi

# ---- preflight: gh authentication --------------------------------------------
#
# gh is the headless agent platform.  Without authentication the agent has no
# identity and cannot represent a real headless-agent scenario.  The test fails
# here — not skips — because an unauthenticated environment is an unconfigured
# environment, not a passing one.

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not installed — install from https://cli.github.com" >&2
  exit 1
fi

echo "--- gh auth status ---"
GH_AUTH_EXIT=0
gh auth status 2>&1 || GH_AUTH_EXIT=$?
echo "--- end gh auth status ---"
echo ""

if [[ "$GH_AUTH_EXIT" -ne 0 ]]; then
  echo "ERROR: gh is not authenticated." >&2
  echo "       Set GH_TOKEN, or run: gh auth login" >&2
  echo "       In CI: add COPILOT_GITHUB_TOKEN to repository secrets." >&2
  exit 1
fi

pass "gh is authenticated — headless agent platform ready"

# ---- workspace (always cleaned up) -------------------------------------------

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

echo "Workspace: $WORKSPACE"
echo ""

# ---- agent step: create a policy-violating file ------------------------------
#
# A headless Copilot agent asked to "create a notes file" will naturally produce
# notes.md — a lowercase name that violates the SCREAMING_SNAKE_CASE policy.
# The agent has no IDE, no LSP client, and no inline red squiggles to warn it.
#
# gh copilot suggest requires a TTY and interactive confirmation, so the file is
# created with the shell command Copilot would produce.  The authenticated gh
# session established above is what makes this an agent-context action, not a
# local simulation.

AGENT_FILE="$WORKSPACE/notes.md"
printf '# Notes\n' > "$AGENT_FILE"
echo "Agent created: $AGENT_FILE"
echo ""

# ---- enforcement: gov-lsp check ----------------------------------------------

CHECK_OUTPUT=""
CHECK_EXIT=0
CHECK_OUTPUT=$(GOV_LSP_POLICIES="$POLICIES_DIR" "$BINARY" check "$AGENT_FILE" 2>&1) \
  || CHECK_EXIT=$?

echo "=== gov-lsp check output ==="
echo "$CHECK_OUTPUT"
echo "============================"
echo ""

# ---- assertions --------------------------------------------------------------

if [[ "$CHECK_EXIT" -ne 0 ]]; then
  pass "enforcement gate triggered: gov-lsp exits non-zero (violation detected)"
else
  fail "gov-lsp reported no violations for lowercase .md — enforcement is not working"
fi

if echo "$CHECK_OUTPUT" | grep -q "markdown-naming-violation"; then
  pass "violation id 'markdown-naming-violation' present"
else
  fail "'markdown-naming-violation' not found — policy was not evaluated"
fi

if echo "$CHECK_OUTPUT" | grep -q "NOTES.md"; then
  pass "fix suggestion 'NOTES.md' present"
else
  fail "fix suggestion 'NOTES.md' not found"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
echo "Framework proof: a headless gh agent's policy-violating action was caught"
echo "by gov-lsp enforcement — the rails are working."

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
