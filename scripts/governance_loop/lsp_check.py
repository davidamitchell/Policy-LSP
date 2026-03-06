#!/usr/bin/env python3
"""lsp_check.py — Collect policy violations via the LSP protocol.

Starts gov-lsp as a background server, sends textDocument/didOpen for every
file in the workspace, collects all publishDiagnostics notifications, then
shuts the server down cleanly.

This exercises the full LSP protocol path (Content-Length framing, JSON-RPC
requests and notifications, publishDiagnostics) rather than the batch-check
subcommand, demonstrating that the server works correctly in headless use.

Usage:
    python3 lsp_check.py <gov-lsp-binary> <policies-dir> <workspace-dir>

Output:
    JSON array of violation objects — same schema as gov-lsp check --format
    json — written to stdout.  All diagnostic traces go to stderr.

Verbosity:
    Set LOG_LEVEL=debug (the default) to enable full trace logging: each
    outgoing LSP message (JSON-RPC), the raw server response bytes, and
    every parsed incoming message.  Set LOG_LEVEL=info or higher to reduce
    output to summary lines only.

Exit codes:
    0  clean workspace (no violations)
    1  violations found
    2  usage error or server startup failure
"""
import json
import os
import subprocess
import sys

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# Honour the same LOG_LEVEL env var used by the shell scripts and Go binary.
# "debug" (the default) enables full protocol tracing.  Any higher level
# (info, warn, error) suppresses debug output.
_LOG_LEVEL = os.environ.get("LOG_LEVEL", "debug").lower()
_VERBOSE = _LOG_LEVEL == "debug"


def _dbg(msg: str) -> None:
    """Emit a debug-level trace to stderr (only when LOG_LEVEL=debug)."""
    if _VERBOSE:
        print(f"[lsp_check][DEBUG] {msg}", file=sys.stderr)


def _info(msg: str) -> None:
    """Emit an info-level line to stderr (always visible)."""
    print(f"[lsp_check] {msg}", file=sys.stderr)


def _log_rpc_msg(direction: str, msg: dict) -> None:
    """Log a single JSON-RPC message at debug level with full payload."""
    if not _VERBOSE:
        return
    method = msg.get("method", "<response>")
    msg_id = msg.get("id", "<no-id>")
    payload = json.dumps(msg, indent=2, ensure_ascii=False)
    _dbg(
        f"rpc {direction}: method={method} id={msg_id} payload_bytes={len(payload)}"
        f"\n---begin rpc {direction}---\n{payload}\n---end rpc {direction}---"
    )


def _encode(body: dict) -> bytes:
    """Encode a JSON-RPC message with a Content-Length header."""
    payload = json.dumps(body).encode("utf-8")
    header = f"Content-Length: {len(payload)}\r\n\r\n".encode("utf-8")
    return header + payload


def _parse_messages(raw: bytes) -> list:
    """Parse all Content-Length-framed JSON-RPC messages from a byte buffer."""
    messages = []
    pos = 0
    while pos < len(raw):
        header_end = raw.find(b"\r\n\r\n", pos)
        if header_end < 0:
            break
        length = -1
        for line in raw[pos:header_end].decode("utf-8", errors="replace").splitlines():
            if line.lower().startswith("content-length:"):
                try:
                    length = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
        if length < 0:
            break
        body_start = header_end + 4
        body_end = body_start + length
        if body_end > len(raw):
            break
        try:
            messages.append(json.loads(raw[body_start:body_end]))
        except json.JSONDecodeError:
            pass
        pos = body_end
    return messages


def _diagnostic_to_violation(uri: str, diag: dict) -> dict:
    """Convert an LSP Diagnostic to a gov-lsp check --format json object."""
    fpath = uri.replace("file://", "", 1)
    sev = diag.get("severity", 2)
    level = "error" if sev == 1 else ("info" if sev == 3 else "warning")
    v: dict = {
        "file": fpath,
        "id": diag.get("code", ""),
        "level": level,
        "message": diag.get("message", ""),
    }
    if diag.get("data"):
        v["fix"] = diag["data"]
    return v


def main() -> int:
    if len(sys.argv) < 4:
        print(
            f"Usage: {sys.argv[0]} <gov-lsp-binary> <policies-dir> <workspace-dir>",
            file=sys.stderr,
        )
        return 2

    binary, policies_dir, workspace = sys.argv[1], sys.argv[2], sys.argv[3]
    _info(
        f"starting binary={binary} policies={policies_dir}"
        f" workspace={workspace} log_level={_LOG_LEVEL}"
    )

    server_cmd = [binary, "--policies", policies_dir, "--log-level", "debug"]
    _dbg(f"server command (dereferenced): {' '.join(server_cmd)}")

    try:
        proc = subprocess.Popen(
            server_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
        )
    except FileNotFoundError:
        _info(f"ERROR: gov-lsp binary not found: {binary}")
        return 2

    _info(f"gov-lsp server started pid={proc.pid}")

    outgoing: list = []

    # 1. initialize request
    init_msg = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "rootUri": f"file://{workspace}",
            "capabilities": {},
        },
    }
    outgoing.append(_encode(init_msg))
    _log_rpc_msg("→ send", init_msg)

    # 2. initialized notification (no id — must not be responded to)
    initialized_msg = {
        "jsonrpc": "2.0",
        "method": "initialized",
        "params": {},
    }
    outgoing.append(_encode(initialized_msg))
    _log_rpc_msg("→ send", initialized_msg)

    # 3. textDocument/didOpen for every non-hidden workspace file
    file_count = 0
    for root, dirs, files in os.walk(workspace):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for fname in sorted(files):
            fpath = os.path.join(root, fname)
            uri = f"file://{fpath}"
            try:
                with open(fpath, "r", errors="replace") as fh:
                    text = fh.read()
            except OSError as exc:
                _info(f"skipping unreadable file={fpath} err={exc}")
                continue
            lang = os.path.splitext(fname)[1].lstrip(".") or "text"
            did_open_msg = {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "uri": uri,
                        "languageId": lang,
                        "version": 1,
                        "text": text,
                    }
                },
            }
            outgoing.append(_encode(did_open_msg))
            _log_rpc_msg("→ send", did_open_msg)
            file_count += 1

    _info(f"sending didOpen for {file_count} file(s)")

    # 4. shutdown request + exit notification to terminate the server cleanly
    shutdown_msg = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "shutdown",
        "params": {},
    }
    exit_msg = {
        "jsonrpc": "2.0",
        "method": "exit",
        "params": {},
    }
    outgoing.append(_encode(shutdown_msg))
    _log_rpc_msg("→ send", shutdown_msg)
    outgoing.append(_encode(exit_msg))
    _log_rpc_msg("→ send", exit_msg)

    # Write all messages then close stdin to signal EOF.
    # The server exits when it receives the exit notification; closing stdin
    # also ensures it terminates if it reads until EOF.
    for msg in outgoing:
        proc.stdin.write(msg)  # type: ignore[union-attr]
    proc.stdin.flush()  # type: ignore[union-attr]
    proc.stdin.close()  # type: ignore[union-attr]

    # Read all server output and wait for the process to exit.
    # Do not use proc.communicate() here — it tries to flush the already-closed
    # stdin and raises ValueError.
    try:
        stdout_bytes = proc.stdout.read()  # type: ignore[union-attr]
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout_bytes = proc.stdout.read()  # type: ignore[union-attr]
        proc.wait()
        _info("WARNING: gov-lsp server timed out after 30s")

    _info(f"server exited return_code={proc.returncode} stdout_bytes={len(stdout_bytes)}")

    # When LOG_LEVEL=debug, emit the full unparsed raw bytes from the server so
    # the caller can see exactly what the server sent before any parsing.
    if _VERBOSE and stdout_bytes:
        try:
            raw_text = stdout_bytes.decode("utf-8", errors="replace")
        except Exception:
            raw_text = repr(stdout_bytes)
        _dbg(
            f"raw server stdout (unparsed, {len(stdout_bytes)} bytes):"
            f"\n---begin raw server response---\n{raw_text}\n---end raw server response---"
        )

    all_msgs = _parse_messages(stdout_bytes)
    _info(f"received {len(all_msgs)} LSP messages from server")

    # Log every parsed incoming message at debug level (not just publishDiagnostics).
    for msg in all_msgs:
        _log_rpc_msg("← recv", msg)

    # Collect publishDiagnostics notifications and convert to violation objects.
    violations: list = []
    for msg in all_msgs:
        if msg.get("method") != "textDocument/publishDiagnostics":
            continue
        params = msg.get("params", {})
        uri = params.get("uri", "")
        diags = params.get("diagnostics", [])
        _info(f"publishDiagnostics uri={uri} count={len(diags)}")
        for diag in diags:
            violations.append(_diagnostic_to_violation(uri, diag))

    _info(f"total violations={len(violations)}")
    print(json.dumps(violations, indent=2))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
