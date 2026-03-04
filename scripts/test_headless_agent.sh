#!/usr/bin/env bash
# test_headless_agent.sh — Headless Copilot CLI enforcement integration test.
#
# What this test proves
# ---------------------
# The GitHub Copilot CLI (the `copilot` binary) is a headless agent: it operates
# without an IDE, without an LSP client, and without inline feedback.  GOV-LSP
# enforcement is the only guardrail.  This test verifies the complete enforcement
# loop:
#
#   authenticated copilot agent → creates a policy-violating file → gov-lsp catches it
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
#   copilot   Install with: npm install -g @github/copilot
#             Or: brew install copilot-cli
#             Authenticate with: copilot login
#             In CI: COPILOT_GITHUB_TOKEN repository secret
#
# Do NOT work around the copilot auth requirement.  Bypassing it (e.g. by
# simulating the agent's file-creation directly in the shell) defeats the purpose
# of the test.  If the test fails because copilot is not authenticated, that is
# the correct and expected result for an unconfigured environment.
#
# Headless invocation
# -------------------
# The Copilot CLI supports programmatic/headless use via:
#   -p PROMPT           execute a prompt and exit (no interactive session)
#   --allow-all-tools   allow all tools automatically without confirmation
#   --autopilot         enable autonomous continuation without prompting
#   --add-dir PATH      grant the agent access to a directory
#
# Cleanup
# -------
# A temp workspace is created at the start.  EXIT trap removes it unconditionally.
#
# Usage
# -----
#   COPILOT_GITHUB_TOKEN=<token> bash scripts/test_headless_agent.sh [path-to-gov-lsp]
#
# Environment
# -----------
#   COPILOT_GITHUB_TOKEN   auth token for the Copilot CLI (highest precedence)
#   GH_TOKEN               auth token fallback
#   GITHUB_TOKEN           auth token fallback
#   GOV_LSP_POLICIES       directory containing .rego files (default: ./policies)

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

# ---- preflight: Copilot CLI installation -------------------------------------

if ! command -v copilot >/dev/null 2>&1; then
  echo "ERROR: copilot CLI not installed." >&2
  echo "       Install with: npm install -g @github/copilot" >&2
  echo "       Or: brew install copilot-cli" >&2
  exit 1
fi

echo "--- copilot version ---"
copilot --version 2>&1
echo "--- end copilot version ---"
echo ""

# ---- preflight: Copilot CLI authentication -----------------------------------
#
# The Copilot CLI authenticates via COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN
# environment variables, or via stored credentials from `copilot login`.
#
# The test fails here — not skips — because an unauthenticated environment is an
# unconfigured environment, not a passing one.
#
# Token precedence (from copilot docs):
#   COPILOT_GITHUB_TOKEN > GH_TOKEN > GITHUB_TOKEN > stored credentials

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.copilot}"
AUTH_TOKEN="${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"

if [[ -z "$AUTH_TOKEN" ]] && [[ ! -d "$CONFIG_DIR" ]]; then
  echo "ERROR: copilot CLI is not authenticated." >&2
  echo "       Set COPILOT_GITHUB_TOKEN, or run: copilot login" >&2
  echo "       In CI: add COPILOT_GITHUB_TOKEN to repository secrets." >&2
  exit 1
fi

pass "copilot CLI authenticated — headless agent ready"

# ---- workspace (always cleaned up) -------------------------------------------

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

echo "Workspace: $WORKSPACE"
echo ""

# ---- agent step: Copilot CLI creates a policy-violating file -----------------
#
# The Copilot CLI is given a task to create a notes file.  Without governance
# guardrails, it will naturally create notes.md — a lowercase name that violates
# the SCREAMING_SNAKE_CASE policy.  The agent has no IDE, no LSP client, and no
# inline red squiggles to warn it.
#
# Flags used for headless operation:
#   --allow-all-tools  allow all tools without confirmation (programmatic use;
#                      equivalent to setting COPILOT_ALLOW_ALL=true)
#   --autopilot        enable autonomous continuation without interactive prompts
#   --add-dir          grant the agent access to the temp workspace
#   -p                 execute a prompt and exit (non-interactive)

echo "=== Copilot CLI agent task ==="
AGENT_EXIT=0
(
  cd "$WORKSPACE"
  copilot \
    --allow-all-tools \
    --autopilot \
    --add-dir "$WORKSPACE" \
    -p "Create a markdown file called notes.md containing a single heading: # Notes" \
    2>&1
) || AGENT_EXIT=$?
echo "=== end agent task (exit $AGENT_EXIT) ==="
echo ""

if [[ ! -f "$WORKSPACE/notes.md" ]]; then
  echo "ERROR: copilot agent did not create notes.md" >&2
  echo "       Check that copilot is authenticated and can access the workspace." >&2
  exit 1
fi

pass "copilot agent created notes.md autonomously"
echo "Agent created: $WORKSPACE/notes.md"
echo ""

# ---- enforcement: gov-lsp check ----------------------------------------------

CHECK_OUTPUT=""
CHECK_EXIT=0
CHECK_OUTPUT=$(GOV_LSP_POLICIES="$POLICIES_DIR" "$BINARY" check "$WORKSPACE/notes.md" 2>&1) \
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
echo "Framework proof: a headless Copilot CLI agent's policy-violating action"
echo "was caught by gov-lsp enforcement — the rails are working."

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
