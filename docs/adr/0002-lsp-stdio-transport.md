# 0002. Use Stdio as the Primary LSP Transport

Date: 2026-02-28
Status: accepted

## Context

A Language Server must expose a communication channel for LSP clients. The LSP specification supports two primary transport mechanisms:

1. **Stdio** — the client launches the server as a child process; client↔server communication is over stdin/stdout.
2. **TCP / socket** — client and server communicate over a named pipe or TCP socket; the server can be a persistent daemon.

A secondary question is framing: how individual JSON-RPC messages are delimited within a stream. The LSP specification defines a fixed format: an HTTP-like `Content-Length: <n>\r\n\r\n` header followed by a JSON body.

## Decision

- **Stdio-first transport.** The initial implementation communicates exclusively over stdin/stdout.
- **`Content-Length` framing** as specified in the LSP protocol. No custom framing.
- The transport layer is isolated in `cmd/gov-lsp/main.go` (`readMessage`, `writeMessage`). The handler (`internal/lsp/handlers.go`) has no transport knowledge. This separation means adding TCP or WebSocket transport requires only a new entry-point variant, not touching the engine or handlers.

## Consequences

**Easier:**
- Every LSP-aware editor (VSCode, Neovim, Zed, Helix, Emacs) supports stdio natively. No port configuration, no firewall rules, no process discovery.
- The server process is owned by the editor — the editor starts it, and it exits when the editor closes. This eliminates stale server processes and port conflicts.
- MCP tool configuration in Claude Code and GitHub Copilot Agent uses stdio (the `command` + `args` pattern). GOV-LSP maps directly to this pattern without a wrapper.
- Testing is straightforward: pipe bytes to stdin, assert bytes on stdout. `scripts/smoke_test.sh` uses this pattern.
- Static analysis and fuzzing work directly on `readMessage` / `writeMessage` without mocking a network stack.

**Harder:**
- Stdio is per-editor-instance: if three editor windows open the same repository, three separate server processes start, each loading policies independently. There is no shared state.
- Remote agent frameworks that cannot spawn a subprocess and capture stdio cannot connect directly. TCP transport (backlog W-0009) addresses this.
- Debugging requires redirecting stderr carefully, since stdout is reserved for LSP messages.

**Neutral:**
- Alternative considered: TCP-first. Rejected because the complexity of port management and process discovery adds friction for the common case (single editor + single project).
- Alternative considered: Unix domain sockets. Offers similar properties to TCP with simpler addressing, but no broader support in existing MCP configs. Not pursued until there is a concrete need.
