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

status: done
created: 2026-02-28
updated: 2026-03-02

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

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

The engine layer uses `testing/fstest.MapFS` in all unit tests instead of real filesystem paths. `engine.New()` is refactored to accept an `fs.FS` parameter (with a convenience `engine.NewFromDir(path string)` wrapper that calls `os.DirFS`). All existing tests pass with the new signature.

### Context

The current `policyDir(t)` helper in `rego_test.go` resolves `../../policies` at runtime, coupling tests to the physical directory layout. Using `fstest.MapFS` makes tests hermetic and eliminates the path dependency.

---

## W-0006

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

Structured logging using `log/slog` replaces `log.Printf` throughout the server. Log output goes to stderr only. The log level is configurable via `--log-level` flag (`debug`, `info`, `warn`, `error`; default `warn`). In tests, logging is silenced by default to avoid polluting test output.

### Context

`log.Printf` has no level concept and produces output on every request in the current implementation, which corrupts the stdio LSP stream if a client reads stderr. `slog` with a stderr handler at `warn` level by default means normal operation is silent.

---

## W-0007

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

A `governance.content` policy package exists in `policies/content.rego`. It defines at least one rule: any file with extension `.go` that does not begin with a Go copyright or package comment produces a `"missing-package-comment"` violation. Unit tests in `internal/engine/rego_test.go` cover the compliant and violating cases. The smoke test is updated to verify no false positive on a compliant Go file.

### Context

The current policies directory contains only filename rules. A content-aware policy demonstrates that the engine's `file_contents` injection is exercised end-to-end, and validates the multi-policy evaluation path.

---

## W-0008

status: done
created: 2026-02-28
updated: 2026-03-02

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

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`.devcontainer/devcontainer.json` exists with a Go 1.24 base image. `postCreateCommand` builds the `gov-lsp` binary immediately so the hook and MCP server are available without a manual build step. Node.js is included for MCP server startup. `GOV_LSP_POLICIES` is set in `remoteEnv`.

### Context

Lowering the local setup barrier means contributors (human or AI) can open the repo and begin working on policies or server code without a local Go installation.

---

## W-0012

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`gov-lsp mcp` subcommand implemented in `cmd/gov-lsp/mcp.go`. Implements MCP protocol version 2024-11-05 over newline-delimited JSON-RPC 2.0 stdio. Exposes `gov_check_file` and `gov_check_workspace` tools. Registered in `.mcp.json` via `scripts/mcp-start.sh` (auto-builds binary if absent). ADR 0006 documents the decision to use a subcommand rather than a separate binary.

### Context

GOV-LSP is an LSP server and MCP is a different protocol. Agents like Claude Code and GitHub Copilot Agent use MCP, not LSP, as their tool protocol. The `mcp` subcommand calls `engine.Evaluate()` directly — the wrapper is thin and adds no new dependencies.

---

## W-0013

status: backlog
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `check_policy` LSAP cognitive capability exists: any LSAP-aware agent can send a `{"mode":"check_policy","file_path":"<path>","file_contents":"<text>"}` request and receive a structured Markdown report listing all policy violations, their messages, and fix suggestions. The LSAP endpoint uses the same `engine.Evaluate()` call as the MCP tool (W-0012).

### Context

LSAP (Language Server Agent Protocol — `github.com/lsp-client/LSAP`, v1.0.0-alpha, MIT) is an orchestration layer that translates LSP's atomic editor operations into high-level "cognitive" interfaces for AI agents. Its Markdown-first response format is token-efficient and directly consumable by LLMs without JSON parsing.

GOV-LSP is a natural fit: its diagnostics are already semantically rich (natural language messages, typed fix suggestions). Wrapping them in LSAP's `check_policy` interface requires no changes to the engine or policy files.

See `research/lsap/README.md` for protocol analysis, comparison with MCP, and a `check_policy` request/response design.

### Notes

Blocked on LSAP protocol stability (currently v1.0.0-alpha, Python SDK only, no Go SDK). Implement after W-0012 is done and the LSAP spec reaches a stable release or a Go SDK is available. The engine call and policy schema will not need to change — this is purely a new transport adapter.

---

## W-0014

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `gov-lsp-governance` agent skill exists and installs into Claude Code (`~/.claude/skills/`), Gemini (`~/.gemini/skills/`), Codex, and any `agentskills.io`-compatible agent tool. The skill exposes a single command: `check-governance <file_path>`. The agent invokes it on changed files; it calls `gov-lsp check <file>` and returns a Markdown policy report listing violations and fix suggestions. An agent with the skill installed can enforce governance rules without an editor, without an LSP client, and without MCP.

### Context

The `lsp-client/lsp-skill` project (see `research/lsap/README.md`, section "The `lsp-skill` Ecosystem") demonstrates the pattern: a SKILL.md instruction file + a CLI subcommand. The skill installs into the same `~/.claude/skills/` directory already used by the `davidamitchell/Skills` submodule in this repo.

GOV-LSP already produces the right output — violation messages, severity, and self-contained fix suggestions. The skill is a thin adapter: a SKILL.md that documents the command interface, plus the `gov-lsp check` subcommand (already implemented in W-0001) that accepts a file path and prints Markdown.

This is the most direct path to autonomous agent governance enforcement without an editor — simpler than a full LSAP implementation (W-0013) and complementary to MCP (W-0012).

### Notes

The `gov-lsp check <file>` CLI subcommand is already implemented (see ADR 0005). W-0014 now depends only on the SKILL.md authoring work. The skill itself is ~50 lines of Markdown plus the command registration. No Go SDK or protocol stabilisation required. Write an ADR before implementation to decide whether the skill ships in this repo or as a separate `gov-lsp-skill` release artifact.

---

## W-0015

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A minimal VS Code extension (`vscode-gov-lsp`) is published to the VS Code Marketplace. It starts the `gov-lsp` binary as a Language Server using `vscode-languageclient`, configures it to evaluate the current workspace's policy directory, and displays GOV-LSP diagnostics inline in the editor. A `gov-lsp.policies` setting allows workspace-level policy directory override.

### Context

The server binary already implements a complete LSP server. The only missing piece is the client-side glue that VS Code needs to launch and connect to a stdio LSP binary. `vscode-languageclient` makes this ~50 lines of TypeScript. The `.vscode/settings.json` and `.vscode/extensions.json` files already document the target config shape.

### Notes

This is the most common editor for the target audience. Write the extension in TypeScript using the standard `vscode-languageclient` + `vscode-languageserver-protocol` packages. The extension is separate from the Go binary — it wraps it, similar to how `gopls` is wrapped by `golang.go`. The binary path should default to the system PATH (`gov-lsp`) with a workspace override.

---

## W-0016

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`.github/workflows/ci.yml` includes a `policy-check` step that runs `gov-lsp check --format text .` on every push and PR. Currently informational (`|| true`) because this repo intentionally has demo violations in `docs/`. A consumer repo removes `|| true` to make it a hard gate. `.github/workflows/copilot-setup-steps.yml` builds `gov-lsp` and places it on PATH for GitHub Copilot agent sessions.

### Context

The `gov-lsp check` subcommand returns exit code 1 on violations. The CI step closes the loop: governance violations are surfaced on every PR even when no IDE extension is installed.
