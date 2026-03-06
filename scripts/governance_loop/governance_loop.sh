#!/usr/bin/env bash
# governance_loop/governance_loop.sh — Production-quality agent governance loop.
#
# Orchestrates a headless Copilot CLI agent in a policy-governed workspace.
# Each iteration uses real-time LSP event simulation (when Python 3 is available)
# or falls back to gov-lsp batch check to collect violations.  Auto-applies
# simple rename fixes directly before re-prompting the agent, reducing LLM
# round-trips for fixable violations.
#
# Phase 1 — Initial agent run (task execution):
#   The agent is run with the original task unconditionally.
#
# Phase 2 — Convergence correction loop:
#   1. Collect violations (LSP simulation → batch check fallback)
#   2. If zero → convergence, exit 0
#   3. Auto-apply all rename-type fixes directly (mv, no LLM round-trip)
#   4. Re-check workspace after auto-fix; if zero → convergence, exit 0
#   5. Inject remaining violations (human-readable + raw JSON) into prompt
#   6. Re-run the agent with that context
#   7. Watch for filesystem changes (inotifywait / fswatch / poll fallback)
#   8. Repeat from step 1
#
# LSP Simulation (when python3 is available):
#   scripts/governance_loop/lsp_check.py starts gov-lsp as a background server,
#   sends textDocument/didOpen for every workspace file over JSON-RPC, collects
#   publishDiagnostics notifications, and returns the same JSON violation schema
#   as gov-lsp check --format json.  This exercises the full LSP protocol path.
#
# Auto-apply rename fixes:
#   Violations with fix.type == "rename" are applied directly with mv, bypassing
#   the LLM.  Only violations that cannot be auto-applied are re-injected into
#   the agent prompt.
#
# Portability note:
#   This directory (governance_loop/) is self-contained except for the shared
#   logging library at scripts/lib/logging.sh.  To extract it into a standalone
#   tool, copy governance_loop/ and lib/ together.
#
# Prerequisites:
#   gov-lsp   Build: go build -o gov-lsp ./cmd/gov-lsp
#   copilot   Install: npm install -g @github/copilot
#             Auth:    GH_TOKEN env var (GitHub PAT with Copilot access)
#   python3   Optional but recommended for LSP simulation mode
#
# Usage:
#   GH_TOKEN=<token> bash scripts/governance_loop/governance_loop.sh [path-to-gov-lsp]
#
# Environment variables:
#   GH_TOKEN          GitHub token for copilot CLI (required)
#   GITHUB_TOKEN      Fallback auth token
#   GOV_LSP_POLICIES  Directory containing .rego files (default: ./policies)
#   WORKSPACE         Workspace directory to govern (default: /tmp/gov_workspace_<pid>)
#   AGENT_TASK        Agent task prompt (default: contents of prompt.txt or built-in)
#   MAX_ITER          Maximum correction iterations as safety backstop (default: 10)
#   LOG_LEVEL         Logging verbosity: debug, info, warn, error (default: debug)
#   USE_LSP_SIM       Set to 0 to skip LSP simulation and always use batch check
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
# Sourced from scripts/lib/logging.sh (one level up from this directory).
# Set LOG_NAME before sourcing so log lines are prefixed with "governance_loop".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_NAME="governance_loop"
# shellcheck source=../lib/logging.sh
source "$SCRIPT_DIR/../lib/logging.sh"

# ---- configuration -----------------------------------------------------------

BINARY="${1:-./gov-lsp}"
POLICIES_DIR="$(realpath "${GOV_LSP_POLICIES:-./policies}")"
WORKSPACE="${WORKSPACE:-}"
AGENT_TASK="${AGENT_TASK:-}"
MAX_ITER="${MAX_ITER:-10}"
USE_LSP_SIM="${USE_LSP_SIM:-1}"

LSP_CHECK_PY="$SCRIPT_DIR/lsp_check.py"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); log_info "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); log_warn "FAIL: $1"; }

log_info "governance loop starting pid=$$ use_lsp_sim=$USE_LSP_SIM"
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

# ---- preflight: LSP simulation dependencies ----------------------------------

if [[ "$USE_LSP_SIM" == "1" ]]; then
  if ! command -v python3 &>/dev/null; then
    log_warn "preflight: python3 not found — LSP simulation disabled, will use batch check"
    USE_LSP_SIM=0
  elif [[ ! -f "$LSP_CHECK_PY" ]]; then
    log_warn "preflight: lsp_check.py not found at $LSP_CHECK_PY — LSP simulation disabled"
    USE_LSP_SIM=0
  else
    PYTHON_VERSION=$(python3 --version 2>&1 || true)
    log_info "LSP simulation enabled python=\"$PYTHON_VERSION\" lsp_check=$LSP_CHECK_PY"
  fi
fi

# ---- workspace ---------------------------------------------------------------
#
# The workspace must be an isolated temporary directory, not the repository
# root or the current working directory.  Using the repo root causes
# gov-lsp check to walk the entire repository on every correction iteration,
# multiplying evaluation cost by the number of repo files × MAX_ITER.

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(mktemp -d "/tmp/gov_workspace_$$.XXXXXX")
  trap 'rm -rf "$WORKSPACE"' EXIT
  log_debug "workspace created (ephemeral) path=$WORKSPACE"
else
  log_debug "workspace provided path=$WORKSPACE"
fi
mkdir -p "$WORKSPACE"

# Guard: warn loudly if the workspace looks like a repository root (contains
# a .git directory).  This is the most common cause of whole-repo scanning.
if [[ -d "$WORKSPACE/.git" ]]; then
  log_warn "workspace isolation WARNING: workspace=$WORKSPACE contains a .git directory — gov-lsp check will scan the entire repository on every iteration, which is slow and produces irrelevant violations"
  echo "WARNING: workspace '$WORKSPACE' contains .git — consider passing a clean temp directory" >&2
fi
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
echo "LSP sim:    $USE_LSP_SIM"
echo ""

# ---- helpers -----------------------------------------------------------------

# LAST_VIOLATIONS holds the JSON array from the most recent diagnostic collection.
LAST_VIOLATIONS="[]"

# LAST_VIOLATION_COUNT holds the count from the most recent collect_violations call.
# This allows callers to invoke collect_violations without a subshell so that
# LAST_VIOLATIONS is updated in the current shell context.
LAST_VIOLATION_COUNT=0

# LAST_REMAINING_COUNT holds the count from the most recent auto_apply_rename_fixes call.
LAST_REMAINING_COUNT=0

# collect_lsp_diagnostics uses lsp_check.py to run a gov-lsp server in the
# background and simulate textDocument/didOpen events for all workspace files.
# Captures publishDiagnostics notifications and converts them to the same JSON
# schema as gov-lsp check --format json.  Sets LAST_VIOLATIONS.
# Returns 0 if LSP simulation succeeded, 1 otherwise (caller should fall back).
collect_lsp_diagnostics() {
  local ws="$1"
  log_info "collect_lsp_diagnostics: starting LSP simulation workspace=$ws"

  local lsp_output=""
  lsp_output=$(python3 "$LSP_CHECK_PY" "$BINARY" "$POLICIES_DIR" "$ws" 2>/dev/null) || true

  if [[ -z "$lsp_output" ]]; then
    log_warn "collect_lsp_diagnostics: no output from lsp_check.py — falling back to batch check"
    return 1
  fi

  LAST_VIOLATIONS="${lsp_output:-[]}"
  if [[ "$LAST_VIOLATIONS" == "null" ]]; then
    LAST_VIOLATIONS="[]"
  fi
  log_debug "collect_lsp_diagnostics: LSP output bytes=${#LAST_VIOLATIONS}"
  return 0
}

# check_workspace_batch runs gov-lsp check --format json on the workspace.
# Sets LAST_VIOLATIONS to the raw JSON array.  Returns violation count.
check_workspace_batch() {
  local ws="$1"
  log_debug "check_workspace_batch: running gov-lsp check workspace=$ws"
  local raw=""
  local check_stderr
  check_stderr=$(mktemp)
  raw=$("$BINARY" check --format json --policies "$POLICIES_DIR" "$ws" 2>"$check_stderr") || true
  if [[ -s "$check_stderr" ]]; then
    log_debug "check_workspace_batch: gov-lsp stderr output:"
    while IFS= read -r line; do log_debug "  $line"; done < "$check_stderr"
  fi
  rm -f "$check_stderr"
  LAST_VIOLATIONS="${raw:-[]}"
  if [[ "$LAST_VIOLATIONS" == "null" ]]; then
    LAST_VIOLATIONS="[]"
  fi
  log_debug "check_workspace_batch: raw output bytes=${#LAST_VIOLATIONS}"
}

# collect_violations populates LAST_VIOLATIONS using LSP simulation (preferred)
# or batch check (fallback), and prints the violation count.
collect_violations() {
  local ws="$1"

  if [[ "$USE_LSP_SIM" == "1" ]]; then
    if ! collect_lsp_diagnostics "$ws"; then
      log_warn "collect_violations: LSP simulation failed, falling back to batch check"
      check_workspace_batch "$ws"
    else
      log_debug "collect_violations: LSP simulation succeeded"
    fi
  else
    check_workspace_batch "$ws"
  fi

  # Count violations from LAST_VIOLATIONS.
  local count=0
  if command -v jq &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | jq 'length' 2>/dev/null || echo "0")
    log_debug "collect_violations: counted via jq count=$count"
  elif command -v python3 &>/dev/null; then
    count=$(printf '%s' "$LAST_VIOLATIONS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(0 if not data else len(data))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
    log_debug "collect_violations: counted via python3 count=$count"
  else
    count=$(printf '%s' "$LAST_VIOLATIONS" | grep -c '"id":' 2>/dev/null || echo "0")
    log_warn "collect_violations: jq and python3 not available — grep fallback count=$count"
  fi

  log_info "collect_violations: complete violations=$count workspace=$ws"
  LAST_VIOLATION_COUNT="${count:-0}"
  echo "${count:-0}"
}

# auto_apply_rename_fixes directly applies fix.type=="rename" violations by
# renaming files with mv, without re-prompting the LLM.  Prints the count of
# violations that could NOT be auto-applied (i.e., still need agent attention).
# Sets LAST_VIOLATIONS to the subset of violations that were not auto-applied.
auto_apply_rename_fixes() {
  local violations="$1"
  local applied=0
  local remaining_violations="[]"

  log_debug "auto_apply_rename_fixes: processing violations"

  if command -v jq &>/dev/null; then
    local remaining_list=()
    while IFS= read -r obj; do
      local file fix_type fix_val
      file=$(printf '%s' "$obj" | jq -r '.file // ""')
      fix_type=$(printf '%s' "$obj" | jq -r '.fix.type // ""')
      fix_val=$(printf '%s' "$obj" | jq -r '.fix.value // ""')

      if [[ "$fix_type" == "rename" && -n "$fix_val" && -f "$file" ]]; then
        local new_path
        new_path="$(dirname "$file")/$fix_val"
        if mv "$file" "$new_path" 2>/dev/null; then
          log_info "auto_apply: renamed file=$file to=$new_path"
          applied=$((applied + 1))
        else
          log_warn "auto_apply: rename failed file=$file to=$new_path"
          remaining_list+=("$obj")
        fi
      else
        remaining_list+=("$obj")
      fi
    done < <(printf '%s' "$violations" | jq -c '.[]' 2>/tmp/jq_auto_err || true)
    if [[ -s /tmp/jq_auto_err ]]; then
      log_warn "auto_apply_rename_fixes: jq parse error — $(cat /tmp/jq_auto_err)"
    fi
    rm -f /tmp/jq_auto_err

    # Rebuild LAST_VIOLATIONS with only remaining (non-auto-fixed) violations.
    if [[ ${#remaining_list[@]} -eq 0 ]]; then
      LAST_VIOLATIONS="[]"
    else
      LAST_VIOLATIONS=$(printf '%s\n' "${remaining_list[@]}" | jq -s '.' 2>/dev/null || echo "[]")
    fi

  elif command -v python3 &>/dev/null; then
    local py_stderr
    py_stderr=$(mktemp)
    result=$(printf '%s' "$violations" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
remaining = []
applied = 0
for v in data:
    f = v.get('file', '')
    fix = v.get('fix') or {}
    if fix.get('type') == 'rename' and fix.get('value') and os.path.isfile(f):
        new_path = os.path.join(os.path.dirname(f), fix['value'])
        try:
            os.rename(f, new_path)
            print(f'RENAMED:{f}:{new_path}', file=sys.stderr)
            applied += 1
        except OSError as e:
            print(f'RENAME_FAILED:{f}:{e}', file=sys.stderr)
            remaining.append(v)
    else:
        remaining.append(v)
print(f'APPLIED:{applied}', file=sys.stderr)
print(json.dumps(remaining))
" 2>"$py_stderr" || echo "[]")
    if [[ -s "$py_stderr" ]]; then
      while IFS= read -r line; do log_debug "auto_apply[py]: $line"; done < "$py_stderr"
    fi
    rm -f "$py_stderr"
    LAST_VIOLATIONS="$result"
    applied=$(printf '%s' "$violations" | python3 -c "
import sys, json; data = json.load(sys.stdin)
r = sum(1 for v in data if (v.get('fix') or {}).get('type') == 'rename')
print(r)
" 2>/dev/null || echo "0")
  fi

  local remaining_count
  if command -v jq &>/dev/null; then
    remaining_count=$(printf '%s' "$LAST_VIOLATIONS" | jq 'length' 2>/dev/null || echo "0")
  else
    remaining_count=$(printf '%s' "$LAST_VIOLATIONS" | grep -c '"id":' 2>/dev/null || echo "0")
  fi

  log_info "auto_apply: applied=$applied remaining=$remaining_count"
  LAST_REMAINING_COUNT="$remaining_count"
  echo "$remaining_count"
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
    timeout "$timeout_sec" fswatch -r -1 "$ws" >/dev/null 2>&1 || true
  else
    log_warn "wait_for_changes: inotifywait and fswatch not found — polling fallback interval=3s timeout=${timeout_sec}s"
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
# Evaluate the workspace.  If the initial run left violations:
#   1. Try auto-applying rename fixes directly (no LLM round-trip).
#   2. If auto-fix resolved everything → convergence.
#   3. Otherwise inject remaining violations into the agent prompt and re-run.
# Repeat until the workspace is clean or MAX_ITER correction rounds are exhausted.

log_info "phase2: starting convergence loop max_iter=$MAX_ITER"

iteration=0

while [[ $iteration -lt $MAX_ITER ]]; do
  echo "=== Correction iteration $iteration ==="
  log_info "phase2: correction iteration=$iteration"

  # Step 1: collect violations (LSP simulation preferred, batch check fallback).
  # Call directly (not via $(...)) so LAST_VIOLATIONS is updated in this shell.
  log_debug "phase2: collecting violations path=$WORKSPACE"
  collect_violations "$WORKSPACE" >/dev/null
  VIOLATION_COUNT="$LAST_VIOLATION_COUNT"
  echo "Violations: $VIOLATION_COUNT"
  log_info "phase2: violations=$VIOLATION_COUNT iteration=$iteration"

  # Step 2: convergence check — exit when the workspace is clean.
  if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
    log_info "phase2: convergence reached after $iteration correction iteration(s)"
    pass "convergence reached after $iteration correction iteration(s) — workspace is violation-free"
    break
  fi

  # Step 3: attempt auto-apply of rename-type fixes before involving the LLM.
  # Call directly (not via $(...)) so LAST_VIOLATIONS is updated in this shell
  # to the subset of violations that could not be auto-fixed.
  log_info "phase2: attempting auto-apply of rename fixes violations=$VIOLATION_COUNT iteration=$iteration"
  auto_apply_rename_fixes "$LAST_VIOLATIONS" >/dev/null
  REMAINING="$LAST_REMAINING_COUNT"
  log_info "phase2: after auto-apply remaining=$REMAINING iteration=$iteration"

  # Step 4: re-check after auto-fix to see if we achieved convergence.
  if [[ "$REMAINING" -eq 0 ]]; then
    log_debug "phase2: verifying convergence after auto-apply"
    collect_violations "$WORKSPACE" >/dev/null
    RECHECK="$LAST_VIOLATION_COUNT"
    if [[ "$RECHECK" -eq 0 ]]; then
      log_info "phase2: auto-apply achieved convergence iteration=$iteration"
      pass "convergence via auto-apply after $iteration iteration(s) — workspace is violation-free"
      break
    fi
    log_debug "phase2: new violations introduced after auto-apply count=$RECHECK"
    VIOLATION_COUNT="$RECHECK"
  else
    VIOLATION_COUNT="$REMAINING"
  fi

  # Step 5: format human-readable diagnostic context from remaining violations.
  log_debug "phase2: formatting diagnostic context for agent prompt"
  DIAGNOSTIC_CONTEXT=$(format_context "$LAST_VIOLATIONS")
  echo ""
  echo "Diagnostic context:"
  echo "$DIAGNOSTIC_CONTEXT"
  echo ""
  log_debug "phase2: diagnostic context formatted context_length=${#DIAGNOSTIC_CONTEXT}"

  # Step 6: build correction prompt with structured violation data injected verbatim.
  PROMPT="${AGENT_TASK}

The workspace at ${WORKSPACE} has policy violations that must be corrected.

${DIAGNOSTIC_CONTEXT}

Structured violation data (JSON — each object has file, id, message, and fix fields):
${LAST_VIOLATIONS}

Apply all fixes using your tools. Where fix.type is 'rename', rename the file
to fix.value using a file-rename or move tool. Resolve every violation before
finishing."

  log_debug "phase2: correction prompt built prompt_length=${#PROMPT} violations=$VIOLATION_COUNT"

  # Step 7: run correction agent with diagnostic context.
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

  # Step 8: wait for workspace changes before re-evaluating.
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
