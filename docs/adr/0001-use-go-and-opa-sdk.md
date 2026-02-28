# 0001. Use Go and OPA Go SDK as the Primary Implementation Stack

Date: 2026-02-28
Status: accepted

## Context

The GOV-LSP server needs to:

1. Run as a standalone, portable binary that can be embedded in any developer environment (IDE, MCP tool, Docker sidecar) without requiring a runtime to be installed.
2. Evaluate project policy rules that can be changed without recompiling the binary — new rules should be drop-in `.rego` files.
3. Communicate over the Language Server Protocol, which is JSON-RPC over stdio with a fixed Content-Length framing format.
4. Perform sub-50ms evaluation on every `textDocument/didChange` event to give real-time feedback.

## Decision

- **Go** as the implementation language. Go produces a single static binary (`CGO_ENABLED=0`) with no runtime dependency, which is ideal for embedding as an LSP sidecar. The standard library provides all primitives needed for JSON-RPC framing (`bufio`, `encoding/json`). Native goroutines make it simple to debounce `didChange` events with `time.AfterFunc`.
- **OPA Go SDK** (`github.com/open-policy-agent/opa`) for policy evaluation. The SDK allows loading Rego modules at runtime from the filesystem, compiling them into a `PreparedEvalQuery`, and evaluating against arbitrary `input` maps in under 1ms. The policy format (Rego) is expressive, declarative, and well-understood, and the schema is governed by the OPA project rather than by this codebase.
- **Stdio transport** with future-extensible architecture. The transport (framing, reading, writing) is isolated in `cmd/gov-lsp/main.go`, and the LSP handler (`internal/lsp/`) knows nothing about transport. Adding TCP or WebSocket transport requires only a new `main.go` variant, not touching the engine or handlers.

## Consequences

**Easier:**
- The binary can be copied to any machine and run — no Go installation needed by end users.
- Policies can be added, modified, or removed by editing `.rego` files; no recompile needed.
- The OPA SDK's `PreparedEvalQuery` caches compiled policy bundles, making evaluation cost negligible at runtime.
- The stdio transport is universally supported by LSP clients (VSCode, Neovim, Claude Code, Copilot).

**Harder:**
- The OPA Go SDK is a large dependency (~100 transitive deps). The binary is larger than a minimal Go binary would be.
- Rego's set semantics for `deny` rules means the engine layer must handle type assertions carefully (the result is `[]interface{}` at the boundary, not a typed struct).
- OPA v1.x requires Go 1.25+; we pin to OPA v0.70.0 to stay within the Go 1.24 floor declared in `go.mod`. This will need to be revisited when Go 1.25 is available.

**Neutral:**
- Alternative considered: use an embedded JavaScript engine (goja) with a custom policy DSL. Rejected because Rego is purpose-built for policy evaluation and has a rich ecosystem of pre-existing rules.
- Alternative considered: call out to the `opa` CLI subprocess. Rejected because subprocess overhead adds 50–200ms per evaluation, which is incompatible with real-time LSP feedback.
