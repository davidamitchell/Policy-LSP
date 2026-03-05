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
#   LOG_LEVEL          Logging verbosity: debug, info, warn, error (default: debug)

set -uo pipefail

# ---- logging -----------------------------------------------------------------
#
# Structured log helpers: log_debug, log_info, log_warn, log_error.
# Sourced from scripts/lib/logging.sh to keep implementations in sync.
# LOG_LEVEL controls verbosity (debug > info > warn > error, default: debug).

LOG_NAME="test_headless_agent"
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"

# ---- paths and environment ---------------------------------------------------

log_info "test starting pid=$$"

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
GOVERNANCE_LOOP="$SCRIPT_DIR/governance_loop/governance_loop.sh"
AGENT_LOGS="$(mktemp /tmp/agent_logs.XXXXXX)"
# Export log path so the CI workflow can locate it for artifact upload.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "agent_logs=$AGENT_LOGS" >> "$GITHUB_OUTPUT"
fi

log_debug "binary=$BINARY_PATH policies=$POLICIES_DIR"
log_debug "governance_loop=$GOVERNANCE_LOOP"
log_debug "agent_logs=$AGENT_LOGS"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); log_info "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); log_warn "FAIL: $1"; }

# ---- preflight: gov-lsp ------------------------------------------------------

log_debug "preflight: checking gov-lsp binary"
if [[ ! -x "$BINARY_PATH" ]]; then
  log_error "gov-lsp binary not found: $BINARY_PATH"
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY_PATH" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 1
fi

GOV_LSP_VERSION=$("$BINARY_PATH" --version 2>&1 || true)
log_info "gov-lsp binary OK version=\"$GOV_LSP_VERSION\" path=$BINARY_PATH"

log_debug "preflight: checking policies directory"
if [[ ! -d "$POLICIES_DIR" ]]; then
  log_error "policies directory not found: $POLICIES_DIR"
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 1
fi
POLICY_COUNT=$(find "$POLICIES_DIR" -maxdepth 1 -name "*.rego" 2>/dev/null | wc -l | tr -d ' ')
log_info "policies directory OK count=$POLICY_COUNT dir=$POLICIES_DIR"

log_debug "preflight: checking governance_loop.sh"
if [[ ! -f "$GOVERNANCE_LOOP" ]]; then
  log_error "governance loop script not found: $GOVERNANCE_LOOP"
  echo "ERROR: governance loop script not found: $GOVERNANCE_LOOP" >&2
  exit 1
fi
log_info "governance_loop.sh found (canonical path) path=$GOVERNANCE_LOOP"

# ---- preflight: Copilot CLI installation -------------------------------------

log_debug "preflight: checking copilot CLI"
if ! command -v copilot >/dev/null 2>&1; then
  log_error "copilot CLI not installed"
  echo "ERROR: copilot CLI not installed." >&2
  echo "       Install with: npm install -g @github/copilot" >&2
  exit 1
fi

echo "--- copilot version ---"
copilot --version 2>&1
echo "--- end copilot version ---"
echo ""

COPILOT_VERSION=$(copilot --version 2>&1 || true)
log_info "copilot CLI OK version=\"$COPILOT_VERSION\""

# ---- preflight: authentication -----------------------------------------------
#
# The copilot CLI reads GH_TOKEN or GITHUB_TOKEN from the environment.
# This matches the pattern used in the Research repo research-loop.yml workflow.
#
# The test fails here — not skips — because an unauthenticated environment is an
# unconfigured environment, not a passing one.

log_debug "preflight: checking authentication"
AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$AUTH_TOKEN" ]]; then
  log_error "no auth token: set GH_TOKEN or GITHUB_TOKEN"
  echo "ERROR: copilot CLI is not authenticated." >&2
  echo "       Set GH_TOKEN (a GitHub PAT with Copilot access)." >&2
  echo "       In CI: add COPILOT_GITHUB_TOKEN to repository secrets and export as GH_TOKEN." >&2
  exit 1
fi

log_info "auth token present token_length=${#AUTH_TOKEN}"
pass "GH_TOKEN is set — copilot CLI headless agent ready"

# ---- workspace isolation (always cleaned up) ---------------------------------

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE" "$AGENT_LOGS"' EXIT

log_info "workspace created path=$WORKSPACE"
echo "Workspace: $WORKSPACE"
echo ""

# ---- workspace trust ---------------------------------------------------------
#
# Explicitly trust the workspace so the Copilot CLI loads local configs
# without a security prompt — a common silent failure point in headless CI.

log_debug "workspace: running copilot --trust"
copilot --trust "$WORKSPACE"
log_info "workspace trusted path=$WORKSPACE"

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
log_info "agent task: invoking governance_loop.sh task='Create a md file called my-notes.md'"
log_debug "governance loop env: GOV_LSP_POLICIES=$POLICIES_DIR WORKSPACE=$WORKSPACE binary=$BINARY_PATH"

AGENT_EXIT=0
GOV_LSP_POLICIES="$POLICIES_DIR" \
WORKSPACE="$WORKSPACE" \
LOG_LEVEL="$LOG_LEVEL" \
AGENT_TASK="Create a md file called my-notes.md" \
  bash "$GOVERNANCE_LOOP" "$BINARY_PATH" > "$AGENT_LOGS" 2>&1 || AGENT_EXIT=$?
echo "=== end agent task (exit $AGENT_EXIT) ==="
log_info "governance loop completed exit_code=$AGENT_EXIT logs=$AGENT_LOGS"
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

log_debug "assertion: checking workspace for policy violations"
log_debug "assertion: checking for my-notes.md (must NOT exist)"

if [[ $AGENT_EXIT -ne 0 ]] || [[ -f "$WORKSPACE/my-notes.md" ]]; then
  echo "--- GOVERNANCE LOOP LOGS ---"
  cat "$AGENT_LOGS"
  echo "--- END LOGS ---"
  echo ""

  if [[ $AGENT_EXIT -ne 0 ]]; then
    log_warn "assertion: governance loop exited with error exit_code=$AGENT_EXIT"
    fail "governance loop exited with error $AGENT_EXIT"
  fi
  if [[ -f "$WORKSPACE/my-notes.md" ]]; then
    log_error "assertion: FAILED — my-notes.md exists after governance loop completed (enforcement did not converge)"
    fail "enforcement FAILED: my-notes.md exists after governance loop completed"
    echo "     The governance loop did not correct the violation." >&2
  fi
else
  log_info "assertion: PASSED — my-notes.md absent (enforcement converged)"
  pass "enforcement PASSED: my-notes.md was not present after governance loop converged"
fi

if [[ -f "$WORKSPACE/MY-NOTES.md" ]]; then
  log_info "assertion: agent self-corrected — MY-NOTES.md exists (compliant filename)"
  pass "agent self-corrected: created MY-NOTES.md (compliant filename)"
else
  log_debug "assertion: MY-NOTES.md not found — agent may have been blocked or used different name"
  echo "INFO: MY-NOTES.md not found — agent may have been blocked entirely or used a different name"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  log_info "summary: TEST PASSED pass=$PASS fail=$FAIL"
  echo "Framework proof: the governance loop orchestrated a headless Copilot CLI"
  echo "agent and enforced policy compliance — violations were corrected before the loop exited."
else
  log_warn "summary: TEST FAILED pass=$PASS fail=$FAIL"
  echo "Framework BROKEN: the governance loop did not correct"
  echo "a policy-violating file created by the headless agent."
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
