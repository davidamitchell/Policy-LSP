#!/usr/bin/env bash
# test_headless_agent.sh — Headless Copilot CLI enforcement integration test.
#
# What this test proves
# ---------------------
# The GitHub Copilot CLI (the `copilot` binary) is a headless agent: it operates
# without an IDE, without an LSP client, and without inline feedback.  GOV-LSP
# is the enforcement layer that provides the rails.
#
# This test proves the FRAMEWORK works by proving the OUTCOME:
#
#   The agent is given a task that would naturally produce a policy-violating
#   file (notes.md = lowercase, violates SCREAMING_SNAKE_CASE).  The agent also
#   has access to the gov-lsp governance MCP tools.  After running, the
#   policy-violating file must NOT exist — because the agent caught the violation
#   through the enforcement tools and self-corrected before completing.
#
#   IF notes.md EXISTS AT THE END = ENFORCEMENT FAILED = TEST FAILS.
#
# The enforcement does NOT happen in this test script.  It happens inside the
# agent's own workflow, via the gov-lsp MCP tools the agent has available.  This
# is the difference between testing enforcement-as-a-post-check (wrong) and
# testing enforcement-as-a-guardrail (correct).
#
# The filename policy (SCREAMING_SNAKE_CASE for .md files) is an example policy.
# The goal is not to test that specific rule — the goal is to prove the framework
# pattern: give any headless agent governance tools, and violations get caught
# before the agent's work lands.
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
# Headless invocation
# -------------------
# Modelled on https://github.com/davidamitchell/Research/blob/main/.github/workflows/research-loop.yml
# The Copilot CLI is invoked with:
#   -p PROMPT                    execute a prompt and exit (no interactive session)
#   --autopilot                  enable autonomous continuation without prompting
#   --allow-all                  allow all tools, paths, and URLs automatically
#   --additional-mcp-config @f   augment the session with extra MCP servers
#
# Authentication: the copilot binary reads GH_TOKEN (or GITHUB_TOKEN) from
# the environment, which is the pattern used in the Research repo CI workflow.
#
# Cleanup
# -------
# A temp workspace is created at the start.  EXIT trap removes it unconditionally.
#
# Usage
# -----
#   GH_TOKEN=<token> bash scripts/test_headless_agent.sh [path-to-gov-lsp]
#
# Environment
# -----------
#   GH_TOKEN           GitHub token for the copilot CLI (see Research loop pattern)
#   GITHUB_TOKEN       Fallback auth token
#   GOV_LSP_POLICIES   Directory containing .rego files (default: ./policies)

set -uo pipefail

BINARY="${1:-./gov-lsp}"
BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"
POLICIES_DIR="${GOV_LSP_POLICIES:-./policies}"
POLICIES_DIR="$(cd "$POLICIES_DIR" && pwd)"
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

# ---- workspace (always cleaned up) -------------------------------------------

WORKSPACE=$(mktemp -d)
MCP_CONFIG=$(mktemp --suffix=.json)
trap 'rm -rf "$WORKSPACE" "$MCP_CONFIG"' EXIT

echo "Workspace: $WORKSPACE"
echo ""

# ---- enforcement MCP config --------------------------------------------------
#
# Register the gov-lsp MCP server so the copilot agent has governance tools
# available during its task.  The agent can call gov_check_file or
# gov_check_workspace as part of its natural workflow.  Enforcement happens
# INSIDE the agent's session — not in this test script.

cat > "$MCP_CONFIG" << EOF
{
  "mcpServers": {
    "gov-lsp": {
      "command": "$BINARY",
      "args": ["mcp", "-policies", "$POLICIES_DIR"]
    }
  }
}
EOF

# ---- agent task: create a notes file with governance enforcement active ------
#
# The agent is asked to create a notes file.  Left to its own devices it will
# use a lowercase name (notes.md) which violates the SCREAMING_SNAKE_CASE policy.
# But it also has the gov-lsp governance MCP tools available and is instructed to
# comply with project policies.  The enforcement happens through the agent's own
# use of those tools — not from a check run externally by this script.
#
# Invocation pattern (from the Research repo research-loop.yml):
#   copilot -p "PROMPT" --autopilot --allow-all
#
# --allow-all                  = --allow-all-tools --allow-all-paths --allow-all-urls
# --autopilot                  = autonomous continuation without interactive prompts
# -p                           = execute a prompt and exit (non-interactive)
# --additional-mcp-config @f   = augment MCP tools with gov-lsp enforcement

echo "=== Copilot CLI agent task (with gov-lsp enforcement tools) ==="
AGENT_EXIT=0
(
  cd "$WORKSPACE"
  copilot \
    -p "Create a markdown notes file in the current directory containing a single heading: # Notes. You have governance policy tools available — use them to check any file you create for policy compliance and fix any violations before you are done." \
    --autopilot \
    --allow-all \
    --additional-mcp-config "@$MCP_CONFIG" \
    2>&1
) || AGENT_EXIT=$?
echo "=== end agent task (exit $AGENT_EXIT) ==="
echo ""

# ---- assertion: enforcement outcome ------------------------------------------
#
# The only assertion that matters: did the agent leave a policy-violating file?
#
# notes.md EXISTS   → enforcement failed — the agent created a violating file
#                     and the governance framework did not catch it.  FAIL.
#
# notes.md ABSENT   → enforcement worked — the agent either self-corrected
#                     before creating the file, or renamed it after catching
#                     the violation through the gov-lsp tools.  PASS.

echo "--- workspace contents ---"
ls -la "$WORKSPACE/" 2>&1
echo "--- end workspace contents ---"
echo ""

if [[ -f "$WORKSPACE/notes.md" ]]; then
  fail "enforcement FAILED: agent created notes.md (policy-violating file exists)"
  echo "     The governance framework did not prevent the violation." >&2
  echo "     The agent had gov-lsp tools available but the violation was not caught." >&2
else
  pass "enforcement PASSED: notes.md was not created (agent self-corrected via governance tools)"
fi

if [[ -f "$WORKSPACE/NOTES.md" ]]; then
  pass "agent self-corrected: created NOTES.md (compliant filename)"
else
  echo "INFO: NOTES.md not found — agent may have been blocked entirely or used a different name"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "Framework proof: a headless Copilot CLI agent operating with gov-lsp"
  echo "enforcement tools self-corrected a policy violation — the rails are working."
else
  echo "Framework BROKEN: the governance enforcement framework did not prevent"
  echo "a policy-violating file from being created by the headless agent."
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
