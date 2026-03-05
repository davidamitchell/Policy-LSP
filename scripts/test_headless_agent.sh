#!/usr/bin/env bash
# test_headless_agent.sh — Headless governance loop integration test.
#
# What this test proves
# ---------------------
# The governance loop (scripts/governance_loop.sh) is a policy-enforced agent
# orchestrator: it runs the Copilot CLI to execute a task, detects any policy
# violations the agent leaves behind, and re-runs the agent with structured
# violation context until the workspace is clean.
#
# This test proves the FRAMEWORK works by proving the OUTCOME:
#
#   The agent is given a task that would naturally produce a policy-violating
#   file (my-notes.md = lowercase with hyphen, violates SCREAMING_SNAKE_CASE).
#   The governance loop runs the agent, then evaluates the workspace with
#   gov-lsp check --format json.  If violations are found, the loop re-runs
#   the agent with structured violation data (file, id, message, fix) injected
#   into the prompt until the workspace is violation-free.
#
#   IF my-notes.md EXISTS AT THE END = ENFORCEMENT FAILED = TEST FAILS.
#
# The enforcement happens inside governance_loop.sh.  The test script only
# asserts the outcome: was the workspace left in a compliant state?
#
# Enforcement mechanism
# ---------------------
# governance_loop.sh enforces policy by:
#   1. Running the agent with the original task (copilot CLI)
#   2. Evaluating the workspace with: gov-lsp check --format json
#   3. If violations found, injecting structured violation JSON into the next
#      agent prompt alongside a human-readable summary
#   4. Repeating until the workspace is violation-free (convergence) or the
#      MAX_ITER correction rounds are exhausted
#
# The filename policy (SCREAMING_SNAKE_CASE for .md files) is an example policy.
# The goal is not to test that specific rule — the goal is to prove the framework
# pattern: give any headless agent a governance loop, and violations get caught
# and corrected before the agent's work lands.
#
# Prerequisites — this test FAILS if either is absent
# ----------------------------------------------------
#   gov-lsp   Build with: go build -o gov-lsp ./cmd/gov-lsp
#   copilot   Install with: npm install -g @github/copilot
#             Authenticate: set GH_TOKEN to a GitHub PAT with Copilot access
#             In CI: COPILOT_GITHUB_TOKEN repository secret exported as GH_TOKEN
#
# Do NOT work around the copilot auth requirement.  Bypassing it (e.g. by
# simulating the agent's file-creation directly in the shell) defeats the purpose
# of the test.  If the test fails because copilot is not authenticated, that is
# the correct and expected result for an unconfigured environment.
#
# Usage
# -----
#   GH_TOKEN=<token> bash scripts/test_headless_agent.sh [path-to-gov-lsp]
#
# Environment
# -----------
#   GH_TOKEN           GitHub token for the copilot CLI
#   GITHUB_TOKEN       Fallback auth token
#   GOV_LSP_POLICIES   Directory containing .rego files (default: ./policies)

set -uo pipefail

# ---- paths and environment ---------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-gov-lsp-binary>" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

BINARY_PATH="$(realpath "$1")"
POLICIES_DIR="$(realpath "${GOV_LSP_POLICIES:-./policies}")"
# Resolve script paths relative to this file's location so the test can be
# invoked from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOVERNANCE_LOOP="$SCRIPT_DIR/governance_loop.sh"
AGENT_LOGS="$(mktemp /tmp/agent_logs.XXXXXX)"
# Export log path so the CI workflow can locate it for artifact upload.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "agent_logs=$AGENT_LOGS" >> "$GITHUB_OUTPUT"
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- preflight: gov-lsp ------------------------------------------------------

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY_PATH" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

if [[ ! -d "$POLICIES_DIR" ]]; then
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 1
fi

if [[ ! -f "$GOVERNANCE_LOOP" ]]; then
  echo "ERROR: governance loop script not found: $GOVERNANCE_LOOP" >&2
  exit 1
fi

# ---- preflight: Copilot CLI installation -------------------------------------

if ! command -v copilot >/dev/null 2>&1; then
  echo "ERROR: copilot CLI not installed." >&2
  echo "       Install with: npm install -g @github/copilot" >&2
  exit 1
fi

echo "--- copilot version ---"
copilot --version 2>&1
echo "--- end copilot version ---"
echo ""

# ---- preflight: authentication -----------------------------------------------
#
# The copilot CLI reads GH_TOKEN or GITHUB_TOKEN from the environment.
# This matches the pattern used in the Research repo research-loop.yml workflow.
#
# The test fails here — not skips — because an unauthenticated environment is an
# unconfigured environment, not a passing one.

AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$AUTH_TOKEN" ]]; then
  echo "ERROR: copilot CLI is not authenticated." >&2
  echo "       Set GH_TOKEN (a GitHub PAT with Copilot access)." >&2
  echo "       In CI: add COPILOT_GITHUB_TOKEN to repository secrets and export as GH_TOKEN." >&2
  exit 1
fi

pass "GH_TOKEN is set — copilot CLI headless agent ready"

# ---- workspace isolation (always cleaned up) ---------------------------------

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE" "$AGENT_LOGS"' EXIT

echo "Workspace: $WORKSPACE"
echo ""

# ---- workspace trust ---------------------------------------------------------
#
# Explicitly trust the workspace so the Copilot CLI loads local configs
# without a security prompt — a common silent failure point in headless CI.

copilot --trust "$WORKSPACE"

# ---- agent task: run governance loop with the task ---------------------------
#
# The governance loop is the headless agent.  It:
#   1. Runs the Copilot CLI with the task prompt (may create my-notes.md)
#   2. Evaluates the workspace with gov-lsp check --format json
#   3. If violations exist, re-runs the agent with structured violation context
#   4. Repeats until the workspace is violation-free (convergence)
#
# The enforcement happens inside governance_loop.sh, not in this test script.

echo "=== governance_loop.sh agent task ==="
AGENT_EXIT=0
GOV_LSP_POLICIES="$POLICIES_DIR" \
WORKSPACE="$WORKSPACE" \
AGENT_TASK="Create a md file called my-notes.md" \
  bash "$GOVERNANCE_LOOP" "$BINARY_PATH" > "$AGENT_LOGS" 2>&1 || AGENT_EXIT=$?
echo "=== end agent task (exit $AGENT_EXIT) ==="
echo ""

# ---- assertion: enforcement outcome ------------------------------------------
#
# The only assertion that matters: did the governance loop leave a
# policy-violating file in the workspace?
#
# my-notes.md EXISTS   → enforcement failed — the governance loop did not
#                        correct the violation before exiting.  FAIL.
#
# my-notes.md ABSENT   → enforcement worked — the governance loop detected
#                        the violation and the agent self-corrected.  PASS.

echo "--- workspace contents ---"
ls -la "$WORKSPACE/" 2>&1
echo "--- end workspace contents ---"
echo ""

if [[ $AGENT_EXIT -ne 0 ]] || [[ -f "$WORKSPACE/my-notes.md" ]]; then
  echo "--- GOVERNANCE LOOP LOGS ---"
  cat "$AGENT_LOGS"
  echo "--- END LOGS ---"
  echo ""

  if [[ $AGENT_EXIT -ne 0 ]]; then
    fail "governance loop exited with error $AGENT_EXIT"
  fi
  if [[ -f "$WORKSPACE/my-notes.md" ]]; then
    fail "enforcement FAILED: my-notes.md exists after governance loop completed"
    echo "     The governance loop did not correct the violation." >&2
  fi
else
  pass "enforcement PASSED: my-notes.md was not present after governance loop converged"
fi

if [[ -f "$WORKSPACE/MY-NOTES.md" ]]; then
  pass "agent self-corrected: created MY-NOTES.md (compliant filename)"
else
  echo "INFO: MY-NOTES.md not found — agent may have been blocked entirely or used a different name"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "Framework proof: the governance loop orchestrated a headless Copilot CLI"
  echo "agent and enforced policy compliance — violations were corrected before the loop exited."
else
  echo "Framework BROKEN: the governance loop did not correct"
  echo "a policy-violating file created by the headless agent."
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
