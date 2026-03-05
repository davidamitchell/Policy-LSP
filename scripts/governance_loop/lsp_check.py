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

Exit codes:
    0  clean workspace (no violations)
    1  violations found
    2  usage error or server startup failure
"""
import json
import os
import subprocess
import sys


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
    print(
        f"[lsp_check] starting binary={binary} policies={policies_dir} workspace={workspace}",
        file=sys.stderr,
    )

    try:
        proc = subprocess.Popen(
            [binary, "--policies", policies_dir, "--log-level", "debug"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
        )
    except FileNotFoundError:
        print(f"[lsp_check] ERROR: gov-lsp binary not found: {binary}", file=sys.stderr)
        return 2

    outgoing: list = []

    # 1. initialize request
    outgoing.append(_encode({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "rootUri": f"file://{workspace}",
            "capabilities": {},
        },
    }))

    # 2. initialized notification (no id — must not be responded to)
    outgoing.append(_encode({
        "jsonrpc": "2.0",
        "method": "initialized",
        "params": {},
    }))

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
                print(f"[lsp_check] skipping unreadable file={fpath} err={exc}", file=sys.stderr)
                continue
            lang = os.path.splitext(fname)[1].lstrip(".") or "text"
            outgoing.append(_encode({
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
            }))
            file_count += 1

    print(f"[lsp_check] sending didOpen for {file_count} file(s)", file=sys.stderr)

    # 4. shutdown request + exit notification to terminate the server cleanly
    outgoing.append(_encode({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "shutdown",
        "params": {},
    }))
    outgoing.append(_encode({
        "jsonrpc": "2.0",
        "method": "exit",
        "params": {},
    }))

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
        print("[lsp_check] WARNING: gov-lsp server timed out after 30s", file=sys.stderr)

    all_msgs = _parse_messages(stdout_bytes)
    print(f"[lsp_check] received {len(all_msgs)} LSP messages from server", file=sys.stderr)

    # Collect publishDiagnostics notifications and convert to violation objects.
    violations: list = []
    for msg in all_msgs:
        if msg.get("method") != "textDocument/publishDiagnostics":
            continue
        params = msg.get("params", {})
        uri = params.get("uri", "")
        diags = params.get("diagnostics", [])
        print(
            f"[lsp_check] publishDiagnostics uri={uri} count={len(diags)}",
            file=sys.stderr,
        )
        for diag in diags:
            violations.append(_diagnostic_to_violation(uri, diag))

    print(f"[lsp_check] total violations={len(violations)}", file=sys.stderr)
    print(json.dumps(violations, indent=2))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
