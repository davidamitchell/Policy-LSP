#!/usr/bin/env bash
# governance_loop.sh — Production-quality agent governance loop.
#
# Orchestrates a headless Copilot CLI agent in a policy-governed workspace.
# Each iteration:
#
#   1. Evaluate the workspace with gov-lsp check --format json
#      → structured violation objects, no Content-Length frame parsing needed
#   2. If zero violations → convergence reached, exit 0
#   3. Inject structured violation JSON into the agent prompt context
#   4. Run the agent with that context
#   5. Watch for filesystem changes (inotifywait / fswatch / poll fallback)
#   6. Repeat from step 1
#
# Improvements over the minimal scaffold:
#
#   1. Structured JSON diagnostics — gov-lsp check --format json produces a
#      clean JSON array of violation objects.  No LSP server background process
#      is needed; no Content-Length frames need parsing; no log-grepping required.
#
#   2. Filesystem watcher — inotifywait (Linux) or fswatch (macOS) blocks until
#      the workspace actually changes.  Polling with find -newer is the fallback
#      for environments where neither tool is available.
#
#   3. Violation JSON injected verbatim — the structured violation array is
#      included in the agent prompt alongside a human-readable summary.  The
#      model receives machine-readable fix hints (fix.type, fix.value) rather
#      than raw log strings.
#
#   4. Convergence-based termination — the loop exits when violations reach
#      zero (semantic convergence).  MAX_ITER is a safety backstop only; it is
#      not the expected exit condition.
#
# Prerequisites:
#   gov-lsp   Build: go build -o gov-lsp ./cmd/gov-lsp
#   copilot   Install: npm install -g @github/copilot
#             Auth:    GH_TOKEN env var (GitHub PAT with Copilot access)
#
# Usage:
#   GH_TOKEN=<token> bash scripts/governance_loop.sh [path-to-gov-lsp]
#
# Environment variables:
#   GH_TOKEN          GitHub token for copilot CLI (required)
#   GITHUB_TOKEN      Fallback auth token
#   GOV_LSP_POLICIES  Directory containing .rego files (default: ./policies)
#   WORKSPACE         Workspace directory to govern (default: /tmp/gov_workspace_<pid>)
#   AGENT_TASK        Agent task prompt (default: contents of prompt.txt or built-in)
#   MAX_ITER          Maximum iterations as safety backstop (default: 10)
#
# Exit codes:
#   0  convergence reached (workspace is violation-free)
#   1  max iterations exceeded without convergence, or agent error
#   2  prerequisite missing (binary, policies, auth)
#
# Security note:
#   The copilot invocation below uses --allow-all, which grants the agent
#   unrestricted access to files, commands, and URLs inside the workspace.
#   Only run this script in an isolated workspace (e.g. a temp directory or
#   container).  Do not point WORKSPACE at a directory containing secrets.

set -uo pipefail

# ---- configuration -----------------------------------------------------------

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="$(realpath "${GOV_LSP_POLICIES:-./policies}")"
WORKSPACE="${WORKSPACE:-}"
AGENT_TASK="${AGENT_TASK:-}"
MAX_ITER="${MAX_ITER:-10}"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---- preflight: gov-lsp ------------------------------------------------------

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 2
fi

if [[ ! -d "$POLICIES_DIR" ]]; then
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 2
fi

# ---- preflight: Copilot CLI authentication -----------------------------------

if ! command -v copilot >/dev/null 2>&1; then
  echo "ERROR: copilot CLI not installed." >&2
  echo "       Install with: npm install -g @github/copilot" >&2
  exit 2
fi

AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$AUTH_TOKEN" ]]; then
  echo "ERROR: copilot CLI is not authenticated." >&2
  echo "       Set GH_TOKEN (a GitHub PAT with Copilot access)." >&2
  exit 2
fi

# ---- workspace ---------------------------------------------------------------

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(mktemp -d "/tmp/gov_workspace_$$.XXXXXX")
  trap 'rm -rf "$WORKSPACE"' EXIT
fi
mkdir -p "$WORKSPACE"

# ---- agent task --------------------------------------------------------------

if [[ -z "$AGENT_TASK" ]]; then
  if [[ -f "prompt.txt" ]]; then
    AGENT_TASK=$(cat "prompt.txt")
  else
    AGENT_TASK="Create and organize project documentation files in the workspace."
  fi
fi

echo "Binary:     $BINARY"
echo "Policies:   $POLICIES_DIR"
echo "Workspace:  $WORKSPACE"
echo "Max iter:   $MAX_ITER"
echo ""

# ---- helpers -----------------------------------------------------------------

# LAST_VIOLATIONS holds the JSON array from the most recent check_workspace call.
LAST_VIOLATIONS="[]"

# check_workspace runs gov-lsp check --format json on the workspace and prints
# the number of violations found.  Sets LAST_VIOLATIONS to the raw JSON array.
check_workspace() {
  local ws="$1"
  local raw=""
  raw=$("$BINARY" check --format json --policies "$POLICIES_DIR" "$ws" 2>/dev/null) || true
  # Treat empty output and explicit null as an empty array.
  LAST_VIOLATIONS="${raw:-[]}"
  if [[ "$LAST_VIOLATIONS" == "null" ]]; then
    LAST_VIOLATIONS="[]"
  fi

  local count=0
  if command -v jq &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | jq 'length' 2>/dev/null || echo "0")
  elif command -v python3 &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(0 if not data else len(data))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  else
    # Grep fallback: count 'id' fields as a proxy for violation objects.
    count=$(printf '%s' "$LAST_VIOLATIONS" | grep -c '"id":' 2>/dev/null || echo "0")
  fi

  echo "${count:-0}"
}

# format_context converts the violation JSON array into a human-readable
# summary suitable for inclusion in an agent prompt.
format_context() {
  local violations="$1"

  if command -v jq &>/dev/null; then
    printf '%s' "$violations" | jq -r '
      if length == 0 then
        "No violations found."
      else
        "Policy violations (\(length) found):\n" +
        (to_entries | map(
          "  [\(.key + 1)] \(.value.file): [\(.value.id)] \(.value.message)" +
          (if .value.fix then "\n     Fix (\(.value.fix.type)): \(.value.fix.value)" else "" end)
        ) | join("\n"))
      end
    ' 2>/dev/null || printf '%s' "$violations"
  elif command -v python3 &>/dev/null; then
    printf '%s' "$violations" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print('No violations found.')
    else:
        print(f'Policy violations ({len(data)} found):')
        for i, v in enumerate(data, 1):
            line = f'  [{i}] {v.get(\"file\",\"\")}: [{v.get(\"id\",\"\")}] {v.get(\"message\",\"\")}'
            print(line)
            fix = v.get('fix')
            if fix:
                print(f'     Fix ({fix.get(\"type\",\"\")}): {fix.get(\"value\",\"\")}')
except Exception as e:
    print(f'Error formatting violations: {e}')
" 2>/dev/null
  else
    printf '%s' "$violations"
  fi
}

# wait_for_changes blocks until any file in the workspace changes or the
# timeout elapses.  Prefers inotifywait (Linux) then fswatch (macOS), with a
# polling fallback that checks for files newer than a sentinel timestamp.
wait_for_changes() {
  local ws="$1"
  local timeout_sec="${2:-30}"

  if command -v inotifywait &>/dev/null; then
    inotifywait -r -q \
      --event create,modify,delete,moved_to,moved_from \
      --timeout "$timeout_sec" \
      "$ws" >/dev/null 2>&1 || true
  elif command -v fswatch &>/dev/null; then
    # fswatch exits after seeing one event; timeout kills it if nothing happens.
    timeout "$timeout_sec" fswatch -r -1 "$ws" >/dev/null 2>&1 || true
  else
    # Polling fallback: detect changes via modification times.
    local sentinel
    sentinel=$(mktemp)
    local elapsed=0
    local interval=3
    while [[ $elapsed -lt $timeout_sec ]]; do
      sleep "$interval"
      elapsed=$((elapsed + interval))
      if find "$ws" -newer "$sentinel" -type f -print -quit 2>/dev/null | grep -q .; then
        rm -f "$sentinel"
        return 0
      fi
    done
    rm -f "$sentinel"
  fi
}

# ---- phase 1: initial agent run (task execution) -----------------------------
#
# The agent is given the original task and runs unconditionally.  This is the
# "do the work" phase.  Violations produced here are caught and corrected in
# the convergence loop below.

echo "=== Initial agent run ==="
AGENT_LOG=$(mktemp /tmp/governance_agent_initial.XXXXXX)
INITIAL_EXIT=0
(
  cd "$WORKSPACE"
  copilot \
    -p "$AGENT_TASK" \
    --autopilot \
    --allow-all
) >"$AGENT_LOG" 2>&1 || INITIAL_EXIT=$?

if [[ $INITIAL_EXIT -ne 0 ]]; then
  echo "WARNING: initial agent run exited $INITIAL_EXIT — see $AGENT_LOG for details"
fi

echo "Waiting for workspace to settle..."
wait_for_changes "$WORKSPACE"
echo ""

# ---- phase 2: convergence loop (violation correction) -----------------------
#
# Now evaluate the workspace.  If the initial run left violations, inject the
# structured diagnostic context into subsequent agent prompts and retry until
# the workspace is clean or MAX_ITER correction rounds are exhausted.

iteration=0

while [[ $iteration -lt $MAX_ITER ]]; do
  echo "=== Correction iteration $iteration ==="

  # Step 1: structured workspace evaluation (JSON, not log-grepping).
  VIOLATION_COUNT=$(check_workspace "$WORKSPACE")
  echo "Violations: $VIOLATION_COUNT"

  # Step 2: convergence check — exit when the workspace is clean.
  if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
    pass "convergence reached after $iteration correction iteration(s) — workspace is violation-free"
    break
  fi

  # Step 3: format human-readable diagnostic context from violation JSON.
  DIAGNOSTIC_CONTEXT=$(format_context "$LAST_VIOLATIONS")
  echo ""
  echo "Diagnostic context:"
  echo "$DIAGNOSTIC_CONTEXT"
  echo ""

  # Step 4: build correction prompt with structured violation data injected verbatim.
  PROMPT="${AGENT_TASK}

The workspace at ${WORKSPACE} has policy violations that must be corrected.

${DIAGNOSTIC_CONTEXT}

Structured violation data (JSON — each object has file, id, message, and fix fields):
${LAST_VIOLATIONS}

Apply all fixes before creating or renaming files. Where fix.type is 'rename',
rename the file to fix.value. Resolve every violation before finishing."

  # Step 5: run correction agent with diagnostic context.
  echo "Running correction agent (iteration $iteration)..."
  AGENT_LOG=$(mktemp /tmp/governance_agent_iter.XXXXXX)
  AGENT_EXIT=0
  (
    cd "$WORKSPACE"
    copilot \
      -p "$PROMPT" \
      --autopilot \
      --allow-all
  ) >"$AGENT_LOG" 2>&1 || AGENT_EXIT=$?

  if [[ $AGENT_EXIT -ne 0 ]]; then
    echo "WARNING: correction agent exited $AGENT_EXIT — see $AGENT_LOG for details"
  fi

  # Step 6: wait for workspace changes before re-evaluating.
  echo "Waiting for workspace changes..."
  wait_for_changes "$WORKSPACE"
  echo ""

  iteration=$((iteration + 1))
done

if [[ $PASS -eq 0 && $iteration -ge $MAX_ITER ]]; then
  fail "max correction iterations ($MAX_ITER) exceeded without convergence"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "Governance loop converged: workspace is violation-free."
else
  echo "Governance loop did not converge within $MAX_ITER iteration(s)."
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
