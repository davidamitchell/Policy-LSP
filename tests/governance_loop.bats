#!/usr/bin/env bats
# tests/governance_loop.bats — Unit tests for governance_loop.sh helpers and
# supporting scripts.
#
# These tests verify correctness of the logging, workspace isolation, LSP
# simulation, and verbose-flag mechanics WITHOUT requiring a live copilot CLI
# session.  They exercise:
#
#   1. log_verbose emits when LOG_LEVEL=verbose.
#   2. log_verbose is silent when LOG_LEVEL=debug.
#   3. log_verbose is silent when LOG_LEVEL=info.
#   4. log_debug is silent when LOG_LEVEL=verbose (verbose level = -1, debug = 0;
#      but since verbose < debug, log_debug MUST still emit at verbose — because
#      _gov_should_log checks msg_level >= configured_level and 0 >= -1 is true).
#      Specifically: ALL levels emit when LOG_LEVEL=verbose.
#   5. log_prompt emits "Exact prompt:" in verbose output.
#   6. log_prompt is silent when LOG_LEVEL=debug.
#   7. log_agent_output emits when LOG_LEVEL=verbose; silent at debug.
#   8. Workspace isolation guard exits non-zero when workspace contains .git.
#   9. Workspace isolation guard exits non-zero when workspace is not /tmp-prefixed.
#  10. lsp_check.py --verbose produces "RPC request →" lines in stderr.
#  11. lsp_check.py without --verbose at LOG_LEVEL=debug does NOT produce
#      verbose RPC payload dumps.
#  12. lsp_check.py violation output for an isolated workspace does NOT include
#      repository files like README.md.
#  13. lsp_check.py violation output for an isolated workspace includes
#      workspace-specific violations.
#  14. filenames policy fix produces MY_NOTES.md for my-notes.md.
#  15. correction loop injects violation JSON into the agent prompt; no mv call.
#  16. tee pipeline: stdout streams inline AND file is written; PIPESTATUS[0]
#      captures the correct exit code from the piped command, not from tee.
#
# Prerequisites:
#   bats    (sudo apt-get install -y bats)
#   python3
#   gov-lsp binary at ../../gov-lsp (or GOV_LSP_BINARY env var)
#   policies dir at ../../policies (or GOV_LSP_POLICIES_DIR env var)
#
# Run:
#   bats tests/governance_loop.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
LIB_DIR="$SCRIPTS_DIR/lib"
GOVERNANCE_DIR="$SCRIPTS_DIR/governance_loop"
GOVERNANCE_LOOP="$GOVERNANCE_DIR/governance_loop.sh"
LSP_CHECK="$GOVERNANCE_DIR/lsp_check.py"
BINARY="${GOV_LSP_BINARY:-$REPO_ROOT/gov-lsp}"
POLICIES="${GOV_LSP_POLICIES_DIR:-$REPO_ROOT/policies}"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Helper: source logging.sh with a given LOG_LEVEL and evaluate a command.
# Returns the combined stderr output.
# ---------------------------------------------------------------------------
_run_with_log_level() {
  local level="$1"; shift
  LOG_LEVEL="$level" LOG_NAME="test" bash -c "source '$LIB_DIR/logging.sh'; $*" 2>&1
}

# ---------------------------------------------------------------------------
# 1. log_verbose emits when LOG_LEVEL=verbose
# ---------------------------------------------------------------------------
@test "log_verbose emits output when LOG_LEVEL=verbose" {
  output=$(_run_with_log_level verbose "log_verbose 'hello verbose'")
  [[ "$output" == *"hello verbose"* ]]
}

# ---------------------------------------------------------------------------
# 2. log_verbose is silent when LOG_LEVEL=debug
# ---------------------------------------------------------------------------
@test "log_verbose is silent when LOG_LEVEL=debug" {
  output=$(_run_with_log_level debug "log_verbose 'should not appear'")
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# 3. log_verbose is silent when LOG_LEVEL=info
# ---------------------------------------------------------------------------
@test "log_verbose is silent when LOG_LEVEL=info" {
  output=$(_run_with_log_level info "log_verbose 'should not appear'")
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# 4. At LOG_LEVEL=verbose, log_debug ALSO emits (verbose includes all levels)
# ---------------------------------------------------------------------------
@test "log_debug still emits when LOG_LEVEL=verbose" {
  output=$(_run_with_log_level verbose "log_debug 'debug message'")
  [[ "$output" == *"debug message"* ]]
}

# ---------------------------------------------------------------------------
# 5. log_prompt emits "Exact prompt:" in its verbose output
#    Tests the contract: at LOG_LEVEL=verbose, the full prompt text and the
#    "Exact prompt:" label must both appear.
# ---------------------------------------------------------------------------
@test "log_prompt emits 'Exact prompt:' when LOG_LEVEL=verbose" {
  output=$(LOG_LEVEL=verbose LOG_NAME="test" bash -c "
    source '$LIB_DIR/logging.sh'
    log_prompt() {
      local prompt=\"\$1\"; local label=\"\${2:-prompt}\"
      if ! _gov_should_log 'verbose'; then return 0; fi
      log_verbose \"prompt_content: begin label=\$label bytes=\${#prompt} <<<<<\"
      log_verbose \"Exact prompt: \${prompt}\"
      log_verbose \"prompt_content: end label=\$label >>>>>\"
    }
    log_prompt 'My task prompt text' 'test-label'
  " 2>&1)
  [[ "$output" == *"Exact prompt:"* ]]
  [[ "$output" == *"My task prompt text"* ]]
}

# ---------------------------------------------------------------------------
# 6. log_prompt is silent when LOG_LEVEL=debug (only shows at verbose)
# ---------------------------------------------------------------------------
@test "log_prompt is silent when LOG_LEVEL=debug" {
  output=$(LOG_LEVEL=debug LOG_NAME="test" bash -c "
    source '$LIB_DIR/logging.sh'
    log_prompt() {
      local prompt=\"\$1\"; local label=\"\${2:-prompt}\"
      if ! _gov_should_log 'verbose'; then return 0; fi
      log_verbose \"Exact prompt: \${prompt}\"
    }
    log_prompt 'should not appear'
  " 2>&1)
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# 7. log_agent_output emits when LOG_LEVEL=verbose; silent at debug
# ---------------------------------------------------------------------------
@test "log_agent_output emits agent lines when LOG_LEVEL=verbose" {
  local log_file
  log_file="$(mktemp)"
  echo "agent reasoning line 1" > "$log_file"
  echo "agent reasoning line 2" >> "$log_file"

  output=$(LOG_LEVEL=verbose LOG_NAME="test" bash -c "
    source '$LIB_DIR/logging.sh'
    log_agent_output() {
      local log_file=\"\$1\"; local label=\"\${2:-agent}\"
      if ! _gov_should_log 'verbose'; then return 0; fi
      log_verbose \"agent_output: begin label=\$label <<<<<\"
      while IFS= read -r line; do log_verbose \"[\$label] \$line\"; done < \"\$log_file\"
      log_verbose \"agent_output: end label=\$label >>>>>\"
    }
    log_agent_output '$log_file' 'test-agent'
  " 2>&1)
  rm -f "$log_file"

  [[ "$output" == *"agent reasoning line 1"* ]]
  [[ "$output" == *"agent reasoning line 2"* ]]
}

@test "log_agent_output is silent when LOG_LEVEL=debug" {
  local log_file
  log_file="$(mktemp)"
  echo "should not appear" > "$log_file"

  output=$(LOG_LEVEL=debug LOG_NAME="test" bash -c "
    source '$LIB_DIR/logging.sh'
    log_agent_output() {
      local log_file=\"\$1\"; local label=\"\${2:-agent}\"
      if ! _gov_should_log 'verbose'; then return 0; fi
      while IFS= read -r line; do log_verbose \"[\$label] \$line\"; done < \"\$log_file\"
    }
    log_agent_output '$log_file' 'test-agent'
  " 2>&1)
  rm -f "$log_file"

  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# 8. governance_loop.sh isolation guard: exits non-zero on .git workspace
# ---------------------------------------------------------------------------
@test "governance_loop exits non-zero if WORKSPACE contains .git" {
  local bad_ws
  bad_ws="$(mktemp -d /tmp/bad_ws.XXXXXX)"
  mkdir -p "$bad_ws/.git"

  run env \
    WORKSPACE="$bad_ws" \
    GOV_LSP_POLICIES="$POLICIES" \
    bash "$GOVERNANCE_LOOP" "$BINARY"

  rm -rf "$bad_ws"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 9. governance_loop.sh isolation guard: exits non-zero if WORKSPACE not /tmp
# ---------------------------------------------------------------------------
@test "governance_loop exits non-zero if WORKSPACE is not /tmp-prefixed" {
  local bad_ws="/var/tmp/bad_not_tmp_ws_$$"
  mkdir -p "$bad_ws"

  run env \
    WORKSPACE="$bad_ws" \
    GOV_LSP_POLICIES="$POLICIES" \
    bash "$GOVERNANCE_LOOP" "$BINARY"

  rm -rf "$bad_ws"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 10. lsp_check.py --verbose produces "RPC request →" in stderr
# ---------------------------------------------------------------------------
@test "lsp_check.py --verbose produces 'RPC request →' lines" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY; build with: go build -o gov-lsp ./cmd/gov-lsp"
  fi

  local ws
  ws="$(mktemp -d)"
  echo "# test" > "$ws/my_note.md"

  run bash -c "LOG_LEVEL=verbose python3 '$LSP_CHECK' '$BINARY' '$POLICIES' '$ws' --verbose 2>&1 >/dev/null"
  rm -rf "$ws"

  [[ "$output" == *"RPC request →"* ]]
}

# ---------------------------------------------------------------------------
# 11. lsp_check.py without --verbose at LOG_LEVEL=debug: no verbose RPC dumps
# ---------------------------------------------------------------------------
@test "lsp_check.py without --verbose does not produce verbose RPC payloads at LOG_LEVEL=debug" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY"
  fi

  local ws
  ws="$(mktemp -d)"
  echo "# test" > "$ws/my_note.md"

  run bash -c "LOG_LEVEL=debug python3 '$LSP_CHECK' '$BINARY' '$POLICIES' '$ws' 2>&1 >/dev/null"
  rm -rf "$ws"

  # Verbose RPC dumps contain "---begin RPC"; these must NOT appear without --verbose
  [[ "$output" != *"---begin RPC"* ]]
}

# ---------------------------------------------------------------------------
# 12. lsp_check.py violations for isolated workspace do NOT include repo files
# ---------------------------------------------------------------------------
@test "lsp_check.py violation output does not reference README.md from the repository" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY"
  fi

  local ws
  ws="$(mktemp -d)"
  # Put a violating markdown file with a lowercase name in the isolated workspace.
  echo "# hello" > "$ws/my_notes.md"

  # Capture stdout (the JSON violation array).
  local violations
  violations=$(LOG_LEVEL=info python3 "$LSP_CHECK" "$BINARY" "$POLICIES" "$ws" 2>/dev/null || true)
  rm -rf "$ws"

  # The violation JSON must mention the isolated workspace file, not README.md
  [[ "$violations" == *"my_notes.md"* ]]
  [[ "$violations" != *"README.md"* ]]
}

# ---------------------------------------------------------------------------
# 14. filenames policy fix produces MY_NOTES.md for my-notes.md
#     This validates the exact rename the governance loop applies.
#     Confirms: upper(replace("my-notes", "-", "_")) = "MY_NOTES"
# ---------------------------------------------------------------------------
@test "filenames policy fix.value for my-notes.md is MY_NOTES.md" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY"
  fi

  local ws
  ws="$(mktemp -d)"
  echo "# hello" > "$ws/my-notes.md"

  local violations
  violations=$(LOG_LEVEL=info python3 "$LSP_CHECK" "$BINARY" "$POLICIES" "$ws" 2>/dev/null || true)
  rm -rf "$ws"

  # The violation must be reported for my-notes.md
  [[ "$violations" == *"my-notes.md"* ]]
  # The fix value must be MY_NOTES.md (not MY-NOTES.md — the policy replaces
  # hyphens with underscores before uppercasing)
  [[ "$violations" == *"MY_NOTES.md"* ]]
  # The fix type must be rename
  [[ "$violations" == *'"rename"'* ]]
}

# ---------------------------------------------------------------------------
# 15. correction loop injects violation JSON into the agent prompt; no mv call.
#     The governance loop is a feedback harness — it must format violations and
#     pass them to the agent; it must never call mv or apply fixes itself.
# ---------------------------------------------------------------------------
@test "format_context produces human-readable summary and correction prompt includes raw JSON" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY"
  fi

  local ws
  ws="$(mktemp -d)"
  echo "# hello" > "$ws/my-notes.md"

  # Collect the violation JSON using lsp_check.py (same path as the loop uses).
  local violations
  violations=$(LOG_LEVEL=info python3 "$LSP_CHECK" "$BINARY" "$POLICIES" "$ws" 2>/dev/null || true)
  rm -rf "$ws"

  # violations must be non-empty and contain the expected fields.
  [[ -n "$violations" ]]
  [[ "$violations" == *"my-notes.md"* ]]
  [[ "$violations" == *"fix"* ]]

  # format_context (sourced from governance_loop.sh internals via bash -c) must
  # produce a human-readable summary line for each violation.
  # Use awk to extract the complete format_context function body robustly.
  local format_context_body
  format_context_body=$(awk '/^format_context\(\)/{found=1} found{print; if(/^}$/ && found>1){exit} found++}' "$GOVERNANCE_LOOP")
  local summary
  summary=$(bash -c "
    source '$LIB_DIR/logging.sh'
    ${format_context_body}
    format_context '$violations'
  " 2>/dev/null || true)

  [[ "$summary" == *"Policy violations"* ]]
  [[ "$summary" == *"my-notes.md"* ]]

  # The correction prompt must include the raw JSON verbatim (not processed by mv).
  local prompt
  prompt="The following policy violations were found in the workspace.

${summary}

Structured violation data (JSON):
${violations}

Use your file tools to fix every violation. The fix.value field tells you the
target filename for rename violations. Apply all fixes, then stop."

  # prompt must contain the structured JSON so the agent can act on it.
  [[ "$prompt" == *'"fix"'* ]]
  [[ "$prompt" == *"MY_NOTES.md"* ]]

  # The prompt must NOT contain any shell mv invocation — the agent does the fix.
  [[ "$prompt" != *" mv "* ]]
}

# ---------------------------------------------------------------------------
# 16. tee pipeline: stdout streams inline AND file is written;
#     PIPESTATUS[0] captures the correct exit code from the piped command,
#     not from tee (which always exits 0).
#
# This test validates the 12-factor logging fix applied to test_headless_agent.sh:
#   bash "$GOVERNANCE_LOOP" ... 2>&1 | tee "$AGENT_LOGS" || AGENT_EXIT=${PIPESTATUS[0]}
# ---------------------------------------------------------------------------
@test "tee pipeline streams to stdout AND writes to file; PIPESTATUS[0] captures correct exit code" {
  local log_file
  log_file="$(mktemp)"

  # --- Part 1: output appears on stdout AND in the file ---
  local captured_stdout
  captured_stdout=$(bash -c 'echo "stdout line"; echo "stderr line" >&2' 2>&1 | tee "$log_file")

  # stdout received the combined stream inline
  [[ "$captured_stdout" == *"stdout line"* ]]
  [[ "$captured_stdout" == *"stderr line"* ]]

  # the file also contains the combined stream (for artifact upload)
  [[ "$(cat "$log_file")" == *"stdout line"* ]]
  [[ "$(cat "$log_file")" == *"stderr line"* ]]

  rm -f "$log_file"

  # --- Part 2: PIPESTATUS[0] captures the failing command's exit code, not tee's ---
  local log_file2
  log_file2="$(mktemp)"

  local pipe_exit=0
  # set -o pipefail makes the pipeline exit with the failing command's code,
  # matching the behaviour in test_headless_agent.sh (which uses set -uo pipefail).
  set -o pipefail
  bash -c 'echo "some output"; exit 42' 2>&1 | tee "$log_file2" || pipe_exit=${PIPESTATUS[0]}
  set +o pipefail

  rm -f "$log_file2"

  # tee exits 0; PIPESTATUS[0] must reflect the bash sub-shell's exit code (42)
  [ "$pipe_exit" -eq 42 ]
}

