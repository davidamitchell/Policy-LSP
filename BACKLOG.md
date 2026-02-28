# Backlog

> This file tracks **repo improvement** work — server features, tooling, and policy additions.
> Use the `backlog-manager` skill when adding, refining, or reviewing items.

---

## W-0001

status: done
created: 2026-02-28
updated: 2026-02-28

### Outcome

The repository compiles (`go build ./...`), all unit tests pass (`go test ./...`), and the smoke test (`scripts/smoke_test.sh`) passes end-to-end against a real built binary.

### Context

Foundation: Go module, OPA engine, LSP handlers, stdio loop, policies directory, Dockerfile.

---

## W-0002

status: done
created: 2026-02-28
updated: 2026-02-28

### Outcome

`AGENTS.md`, `BACKLOG.md`, `PROGRESS.md`, `.github/copilot-instructions.md`, `.github/mcp.json`, `.mcp.json`, `.gitmodules`, `.github/workflows/ci.yml`, and `docs/adr/` exist with content covering agent instructions, backlog, CI, skills, MCP config, and an initial ADR.

### Context

Agent-first scaffold — mirrors the structure of `davidamitchell/Research` but with Go/OPA/LSP-specific content.

---

## W-0003

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

`textDocument/codeAction` is handled by the server: when a client sends a `codeAction` request for a URI with a `markdown-naming-violation` diagnostic, the server returns a `WorkspaceEdit` that renames the file to the SCREAMING_SNAKE_CASE value from the diagnostic's `data.value` field. A unit test in `internal/lsp/` verifies the returned edit.

### Context

The fix data is already embedded in `Diagnostic.data` from W-0001. This slice wires up the LSP `codeAction` round-trip so editors can offer a one-click fix.

---

## W-0004

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

The server watches `*.rego` files in the policy directory via `workspace/didChangeWatchedFiles` and reloads the OPA engine (re-parses and re-prepares the query) within 500ms of a policy file change, without restarting the process. A test verifies that a newly written policy file produces a violation on the next `didOpen` evaluation.

### Context

Policy hot-reload removes the need to restart the LSP server when iterating on rules during development.

---

## W-0005

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

The engine layer uses `testing/fstest.MapFS` in all unit tests instead of real filesystem paths. `engine.New()` is refactored to accept an `fs.FS` parameter (with a convenience `engine.NewFromDir(path string)` wrapper that calls `os.DirFS`). All existing tests pass with the new signature.

### Context

The current `policyDir(t)` helper in `rego_test.go` resolves `../../policies` at runtime, coupling tests to the physical directory layout. Using `fstest.MapFS` makes tests hermetic and eliminates the path dependency.

---

## W-0006

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

Structured logging using `log/slog` replaces `log.Printf` throughout the server. Log output goes to stderr only. The log level is configurable via `--log-level` flag (`debug`, `info`, `warn`, `error`; default `warn`). In tests, logging is silenced by default to avoid polluting test output.

### Context

`log.Printf` has no level concept and produces output on every request in the current implementation, which corrupts the stdio LSP stream if a client reads stderr. `slog` with a stderr handler at `warn` level by default means normal operation is silent.

---

## W-0007

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `governance.content` policy package exists in `policies/content.rego`. It defines at least one rule: any file with extension `.go` that does not begin with a Go copyright or package comment produces a `"missing-package-comment"` violation. Unit tests in `internal/engine/rego_test.go` cover the compliant and violating cases. The smoke test is updated to verify no false positive on a compliant Go file.

### Context

The current policies directory contains only filename rules. A content-aware policy demonstrates that the engine's `file_contents` injection is exercised end-to-end, and validates the multi-policy evaluation path.

---

## W-0008

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

Integration tests in `internal/lsp/handlers_test.go` exercise the full LSP round-trip: a test constructs a `Handler`, calls `Handle()` with a real `initialize` request, a `didOpen` request for a violating file, and asserts that the `Publisher` was called exactly once with a `publishDiagnostics` notification containing the expected diagnostic. Tests use `testing/fstest.MapFS` for policies.

### Context

The LSP handler package currently has no tests. The handler is the integration point between the transport and the engine; testing it directly (without the stdio loop) gives fast feedback on protocol correctness.

---

## W-0009

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A TCP transport mode exists: running `gov-lsp --transport tcp --addr :7998` accepts a single LSP client connection over TCP and processes messages identically to the stdio mode. The transport is abstracted behind a `Transport` interface with `Read() ([]byte, error)` and `Write([]byte) error` methods. Stdio and TCP are both implementations.

### Context

The spec calls for "modular expansion to TCP". This slice implements the architecture and the TCP variant, enabling integration with clients that do not support stdio (e.g., some remote agent frameworks).

---

## W-0010

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

The binary is published as a GitHub Release artifact on every semver tag (`v*`). A `.github/workflows/release.yml` workflow builds `linux/amd64`, `linux/arm64`, `darwin/amd64`, and `darwin/arm64` static binaries, attaches them to the release, and pushes the multi-arch Docker image to `ghcr.io/davidamitchell/gov-lsp:<tag>`. The release workflow passes on a tag push with no errors.

### Context

Portability is a core design goal. Without published binaries, every user must `go install` from source, which requires a Go toolchain and network access. Published binaries and a container image make the server drop-in for any IDE or MCP config.

---

## W-0011

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `.devcontainer/devcontainer.json` exists with a Go 1.24 base image, installs OPA CLI for interactive policy development, and exposes port 7998 for TCP transport debugging. `make dev-install` installs the binary to `$GOPATH/bin` within the container. The dev environment starts without manual steps in GitHub Codespaces.

### Context

Lowering the local setup barrier means contributors (human or AI) can open the repo and begin working on policies or server code without a local Go installation.

---

## W-0012

status: needing_refinement
created: 2026-02-28
updated: 2026-02-28

### Outcome

GOV-LSP can be used as a tool in an MCP (Model Context Protocol) server configuration so that Claude or another AI agent can request a compliance check for a given file path and receive back a structured list of violations.

### Context

The spec lists MCP integration as a key use case: "Use this as a tool in your MCP config so Claude can 'ask' the policy engine for compliance checks during a chat session." The exact MCP tool schema and transport mechanism need to be decided.

### Notes

Needs a decision on whether to expose GOV-LSP directly as an MCP tool (via a thin wrapper) or build a separate `gov-lsp-mcp` binary. Requires research into MCP tool call format and how to map it to the existing engine API.
