#!/usr/bin/env bash
# lib/logging.sh — Shared structured logging helpers for gov-lsp shell scripts.
#
# Provides log_verbose, log_debug, log_info, log_warn, log_error functions that
# write to stderr with ISO-8601 timestamps and a [LEVEL] prefix.  The caller
# script's name is included so log lines from governance_loop.sh and
# test_headless_agent.sh are distinguishable in combined output.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"
#
# Environment:
#   LOG_LEVEL   Minimum log level to emit (default: debug).
#               Levels in ascending order of severity / descending verbosity:
#                 verbose — full protocol traces, exact prompts, raw RPC JSON
#                 debug   — function entry/exit, variable values
#                 info    — high-level progress milestones
#                 warn    — recoverable problems
#                 error   — unrecoverable failures
#   LOG_NAME    Label to include in each log line (default: basename of $0)

LOG_LEVEL="${LOG_LEVEL:-debug}"
LOG_NAME="${LOG_NAME:-$(basename "$0" .sh)}"

_gov_log_level_num() {
  case "$1" in
    verbose) echo -1 ;;
    debug)   echo 0 ;;
    info)    echo 1 ;;
    warn)    echo 2 ;;
    error)   echo 3 ;;
    *)       echo 0 ;;
  esac
}

_gov_should_log() {
  local configured
  configured=$(_gov_log_level_num "$LOG_LEVEL")
  local msg
  msg=$(_gov_log_level_num "$1")
  [[ "$msg" -ge "$configured" ]]
}

_gov_log() {
  local level="$1"; shift
  if _gov_should_log "$level"; then
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "?")
    local level_upper
    level_upper=$(echo "$level" | tr '[:lower:]' '[:upper:]')
    printf "[%s] [%-7s] %s: %s\n" "$ts" "$level_upper" "$LOG_NAME" "$*" >&2
  fi
}

log_verbose() { _gov_log "verbose" "$*"; }
log_debug()   { _gov_log "debug"   "$*"; }
log_info()    { _gov_log "info"    "$*"; }
log_warn()    { _gov_log "warn"    "$*"; }
log_error()   { _gov_log "error"   "$*"; }
