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
#   LOG_LEVEL         Logging verbosity: debug, info, warn, error (default: debug)
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

# ---- logging -----------------------------------------------------------------
#
# Structured log helpers: log_debug, log_info, log_warn, log_error.
# Sourced from scripts/lib/logging.sh to keep implementations in sync.
# LOG_LEVEL controls verbosity (debug > info > warn > error, default: debug).

LOG_NAME="governance_loop"
# shellcheck source=lib/logging.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"

# ---- configuration -----------------------------------------------------------

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="$(realpath "${GOV_LSP_POLICIES:-./policies}")"
WORKSPACE="${WORKSPACE:-}"
AGENT_TASK="${AGENT_TASK:-}"
MAX_ITER="${MAX_ITER:-10}"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); log_info "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); log_warn "FAIL: $1"; }

log_info "governance loop starting pid=$$"
log_debug "binary=$BINARY policies=$POLICIES_DIR max_iter=$MAX_ITER log_level=$LOG_LEVEL"

# ---- preflight: gov-lsp ------------------------------------------------------

log_debug "preflight: checking gov-lsp binary path=$BINARY"
if [[ ! -x "$BINARY" ]]; then
  log_error "gov-lsp binary not found or not executable: $BINARY"
  echo "ERROR: gov-lsp binary not found or not executable: $BINARY" >&2
  echo "       Build with: go build -o gov-lsp ./cmd/gov-lsp" >&2
  exit 2
fi

BINARY_VERSION=$("$BINARY" --version 2>&1 || true)
log_info "gov-lsp binary ready version=\"$BINARY_VERSION\" path=$BINARY"

log_debug "preflight: checking policies directory path=$POLICIES_DIR"
if [[ ! -d "$POLICIES_DIR" ]]; then
  log_error "policies directory not found: $POLICIES_DIR"
  echo "ERROR: policies directory not found: $POLICIES_DIR" >&2
  exit 2
fi

POLICY_COUNT=$(find "$POLICIES_DIR" -maxdepth 1 -name "*.rego" 2>/dev/null | wc -l | tr -d ' ')
log_info "policies ready count=$POLICY_COUNT dir=$POLICIES_DIR"

# ---- preflight: Copilot CLI authentication -----------------------------------

log_debug "preflight: checking copilot CLI"
if ! command -v copilot >/dev/null 2>&1; then
  log_error "copilot CLI not installed"
  echo "ERROR: copilot CLI not installed." >&2
  echo "       Install with: npm install -g @github/copilot" >&2
  exit 2
fi

COPILOT_VERSION=$(copilot --version 2>&1 || true)
log_info "copilot CLI found version=\"$COPILOT_VERSION\""

AUTH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$AUTH_TOKEN" ]]; then
  log_error "no auth token found: set GH_TOKEN or GITHUB_TOKEN"
  echo "ERROR: copilot CLI is not authenticated." >&2
  echo "       Set GH_TOKEN (a GitHub PAT with Copilot access)." >&2
  exit 2
fi
log_debug "auth token present token_length=${#AUTH_TOKEN}"

# ---- workspace ---------------------------------------------------------------

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(mktemp -d "/tmp/gov_workspace_$$.XXXXXX")
  trap 'rm -rf "$WORKSPACE"' EXIT
  log_debug "workspace created (ephemeral) path=$WORKSPACE"
else
  log_debug "workspace provided path=$WORKSPACE"
fi
mkdir -p "$WORKSPACE"
log_info "workspace ready path=$WORKSPACE"

# ---- agent task --------------------------------------------------------------

if [[ -z "$AGENT_TASK" ]]; then
  if [[ -f "prompt.txt" ]]; then
    AGENT_TASK=$(cat "prompt.txt")
    log_debug "agent task loaded from prompt.txt"
  else
    AGENT_TASK="Create and organize project documentation files in the workspace."
    log_debug "agent task using built-in default"
  fi
fi
log_info "agent task set task_length=${#AGENT_TASK}"

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
  log_debug "check_workspace: running gov-lsp check workspace=$ws"
  local raw=""
  raw=$("$BINARY" check --format json --policies "$POLICIES_DIR" "$ws" 2>/dev/null) || true
  # Treat empty output and explicit null as an empty array.
  LAST_VIOLATIONS="${raw:-[]}"
  if [[ "$LAST_VIOLATIONS" == "null" ]]; then
    LAST_VIOLATIONS="[]"
  fi
  log_debug "check_workspace: raw output bytes=${#LAST_VIOLATIONS}"

  local count=0
  if command -v jq &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | jq 'length' 2>/dev/null || echo "0")
    log_debug "check_workspace: counted violations via jq count=$count"
  elif command -v python3 &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(0 if not data else len(data))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
    log_debug "check_workspace: counted violations via python3 count=$count"
  else
    # Grep fallback: count 'id' fields as a proxy for violation objects.
    count=$(printf '%s' "$LAST_VIOLATIONS" | grep -c '"id":' 2>/dev/null || echo "0")
    log_warn "check_workspace: jq and python3 not available — using grep fallback count=$count"
  fi

  log_info "check_workspace: complete violations=$count workspace=$ws"
  echo "${count:-0}"
}

# format_context converts the violation JSON array into a human-readable
# summary suitable for inclusion in an agent prompt.
format_context() {
  local violations="$1"
  log_debug "format_context: formatting violation JSON for agent prompt"

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
    log_debug "wait_for_changes: using inotifywait timeout=${timeout_sec}s workspace=$ws"
    inotifywait -r -q \
      --event create,modify,delete,moved_to,moved_from \
      --timeout "$timeout_sec" \
      "$ws" >/dev/null 2>&1 || true
  elif command -v fswatch &>/dev/null; then
    log_debug "wait_for_changes: using fswatch timeout=${timeout_sec}s workspace=$ws"
    # fswatch exits after seeing one event; timeout kills it if nothing happens.
    timeout "$timeout_sec" fswatch -r -1 "$ws" >/dev/null 2>&1 || true
  else
    log_warn "wait_for_changes: inotifywait and fswatch not found — using polling fallback interval=3s timeout=${timeout_sec}s"
    # Polling fallback: detect changes via modification times.
    local sentinel
    sentinel=$(mktemp)
    local elapsed=0
    local interval=3
    while [[ $elapsed -lt $timeout_sec ]]; do
      sleep "$interval"
      elapsed=$((elapsed + interval))
      if find "$ws" -newer "$sentinel" -type f -print -quit 2>/dev/null | grep -q .; then
        log_debug "wait_for_changes: polling detected change elapsed=${elapsed}s"
        rm -f "$sentinel"
        return 0
      fi
    done
    log_debug "wait_for_changes: polling timeout elapsed=${elapsed}s no changes detected"
    rm -f "$sentinel"
  fi
  log_debug "wait_for_changes: done"
}

# ---- phase 1: initial agent run (task execution) -----------------------------
#
# The agent is given the original task and runs unconditionally.  This is the
# "do the work" phase.  Violations produced here are caught and corrected in
# the convergence loop below.

echo "=== Initial agent run ==="
log_info "phase1: starting initial agent run"
log_debug "phase1: task=\"$AGENT_TASK\""

AGENT_LOG=$(mktemp /tmp/governance_agent_initial.XXXXXX)
log_debug "phase1: agent log file=$AGENT_LOG"

INITIAL_EXIT=0
(
  cd "$WORKSPACE"
  log_debug "phase1: invoking copilot with --autopilot --allow-all"
  copilot \
    -p "$AGENT_TASK" \
    --autopilot \
    --allow-all
) >"$AGENT_LOG" 2>&1 || INITIAL_EXIT=$?

if [[ $INITIAL_EXIT -ne 0 ]]; then
  log_warn "phase1: initial agent run exited with error exit_code=$INITIAL_EXIT log=$AGENT_LOG"
  echo "WARNING: initial agent run exited $INITIAL_EXIT — see $AGENT_LOG for details"
else
  log_info "phase1: initial agent run complete exit_code=0"
fi

echo "Waiting for workspace to settle..."
log_debug "phase1: waiting for workspace to settle after initial run"
wait_for_changes "$WORKSPACE"
log_debug "phase1: workspace settled"
echo ""

# ---- phase 2: convergence loop (violation correction) -----------------------
#
# Now evaluate the workspace.  If the initial run left violations, inject the
# structured diagnostic context into subsequent agent prompts and retry until
# the workspace is clean or MAX_ITER correction rounds are exhausted.

log_info "phase2: starting convergence loop max_iter=$MAX_ITER"

iteration=0

while [[ $iteration -lt $MAX_ITER ]]; do
  echo "=== Correction iteration $iteration ==="
  log_info "phase2: correction iteration=$iteration"

  # Step 1: structured workspace evaluation (JSON, not log-grepping).
  log_debug "phase2: evaluating workspace path=$WORKSPACE"
  VIOLATION_COUNT=$(check_workspace "$WORKSPACE")
  echo "Violations: $VIOLATION_COUNT"
  log_info "phase2: workspace evaluation result violations=$VIOLATION_COUNT iteration=$iteration"

  # Step 2: convergence check — exit when the workspace is clean.
  if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
    log_info "phase2: convergence reached after $iteration correction iteration(s)"
    pass "convergence reached after $iteration correction iteration(s) — workspace is violation-free"
    break
  fi

  # Step 3: format human-readable diagnostic context from violation JSON.
  log_debug "phase2: formatting diagnostic context for agent prompt"
  DIAGNOSTIC_CONTEXT=$(format_context "$LAST_VIOLATIONS")
  echo ""
  echo "Diagnostic context:"
  echo "$DIAGNOSTIC_CONTEXT"
  echo ""
  log_debug "phase2: diagnostic context formatted context_length=${#DIAGNOSTIC_CONTEXT}"

  # Step 4: build correction prompt with structured violation data injected verbatim.
  PROMPT="${AGENT_TASK}

The workspace at ${WORKSPACE} has policy violations that must be corrected.

${DIAGNOSTIC_CONTEXT}

Structured violation data (JSON — each object has file, id, message, and fix fields):
${LAST_VIOLATIONS}

Apply all fixes before creating or renaming files. Where fix.type is 'rename',
rename the file to fix.value. Resolve every violation before finishing."

  log_debug "phase2: correction prompt built prompt_length=${#PROMPT} violations=$VIOLATION_COUNT"

  # Step 5: run correction agent with diagnostic context.
  echo "Running correction agent (iteration $iteration)..."
  log_info "phase2: running correction agent iteration=$iteration violations=$VIOLATION_COUNT"

  AGENT_LOG=$(mktemp /tmp/governance_agent_iter.XXXXXX)
  log_debug "phase2: correction agent log file=$AGENT_LOG"

  AGENT_EXIT=0
  (
    cd "$WORKSPACE"
    log_debug "phase2: invoking copilot for correction iteration=$iteration"
    copilot \
      -p "$PROMPT" \
      --autopilot \
      --allow-all
  ) >"$AGENT_LOG" 2>&1 || AGENT_EXIT=$?

  if [[ $AGENT_EXIT -ne 0 ]]; then
    log_warn "phase2: correction agent exited with error exit_code=$AGENT_EXIT log=$AGENT_LOG iteration=$iteration"
    echo "WARNING: correction agent exited $AGENT_EXIT — see $AGENT_LOG for details"
  else
    log_info "phase2: correction agent complete exit_code=0 iteration=$iteration"
  fi

  # Step 6: wait for workspace changes before re-evaluating.
  echo "Waiting for workspace changes..."
  log_debug "phase2: waiting for workspace changes after correction iteration=$iteration"
  wait_for_changes "$WORKSPACE"
  log_debug "phase2: workspace changes detected or timeout elapsed iteration=$iteration"
  echo ""

  iteration=$((iteration + 1))
done

if [[ $PASS -eq 0 && $iteration -ge $MAX_ITER ]]; then
  log_warn "phase2: max correction iterations exceeded without convergence max_iter=$MAX_ITER"
  fail "max correction iterations ($MAX_ITER) exceeded without convergence"
fi

# ---- summary -----------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "Governance loop converged: workspace is violation-free."
  log_info "summary: governance loop converged pass=$PASS fail=$FAIL iterations=$iteration"
else
  echo "Governance loop did not converge within $MAX_ITER iteration(s)."
  log_warn "summary: governance loop did not converge pass=$PASS fail=$FAIL iterations=$iteration max_iter=$MAX_ITER"
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
