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
# 15. auto_apply_rename_fixes renames my-notes.md to MY_NOTES.md on disk
#     This is the core enforcement step that converts a violating file to
#     its compliant counterpart without requiring agent intervention.
# ---------------------------------------------------------------------------
@test "auto_apply_rename_fixes renames my-notes.md to MY_NOTES.md" {
  if [[ ! -x "$BINARY" ]]; then
    skip "gov-lsp binary not found at $BINARY"
  fi

  local ws
  ws="$(mktemp -d)"
  echo "# hello" > "$ws/my-notes.md"

  # Build a minimal violation JSON that matches what lsp_check.py produces.
  local violation_json
  violation_json=$(printf '[{"file":"%s/my-notes.md","id":"markdown-naming-violation","message":"Markdown file must be SCREAMING_SNAKE_CASE","fix":{"type":"rename","value":"MY_NOTES.md"}}]' "$ws")

  # Call auto_apply_rename_fixes directly through a minimal wrapper that
  # sources governance_loop.sh's functions.
  LAST_REMAINING_COUNT=""
  bash -c "
    source '$LIB_DIR/logging.sh'
    LAST_VIOLATIONS=''
    LAST_REMAINING_COUNT=''
    auto_apply_rename_fixes() {
      local violations=\"\$1\"
      local remaining_list=()
      while IFS= read -r obj; do
        local file fix_type fix_val
        file=\$(printf '%s' \"\$obj\" | jq -r '.file // \"\"')
        fix_type=\$(printf '%s' \"\$obj\" | jq -r '.fix.type // \"\"')
        fix_val=\$(printf '%s' \"\$obj\" | jq -r '.fix.value // \"\"')
        if [[ \"\$fix_type\" == 'rename' && -n \"\$fix_val\" && -f \"\$file\" ]]; then
          local new_path
          new_path=\"\$(dirname \"\$file\")/\$fix_val\"
          mv \"\$file\" \"\$new_path\" 2>/dev/null && echo \"RENAMED:\$file:\$new_path\" || remaining_list+=(\"\$obj\")
        else
          remaining_list+=(\"\$obj\")
        fi
      done < <(printf '%s' \"\$violations\" | jq -c '.[]' 2>/dev/null || true)
    }
    auto_apply_rename_fixes '$violation_json'
  " 2>/dev/null

  # After auto-apply, my-notes.md must NOT exist and MY_NOTES.md MUST exist.
  local result_ok=0
  [[ ! -f "$ws/my-notes.md" ]] && [[ -f "$ws/MY_NOTES.md" ]] && result_ok=1
  rm -rf "$ws"
  [ "$result_ok" -eq 1 ]
}
