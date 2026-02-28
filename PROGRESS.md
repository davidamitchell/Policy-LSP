# Progress

Last updated: 2026-02-28

---

## Current Status

**Phase:** Epic 0 — Foundation (complete)
**Active slice:** None — see BACKLOG.md W-0003 for next work
**Branch:** `copilot/implement-go-lsp-server`

---

| Epic | Title | Status | Complete |
|---|---|---|---|
| 0 | Foundation | Done | 2 / 2 slices |
| 1 | LSP Feature Completeness | Not started | 0 / 5 slices |
| 2 | Operational Readiness | Not started | 0 / 4 slices |
| 3 | MCP Integration | Not started | 0 / 1 slice |

---

## Work Log

### 2026-02-28 — Session 2

**Completed:**

- `README.md` — rewritten for humans: what it does, quick start, editor integration (VSCode, Neovim, Zed, Claude Code, Copilot Agent, Docker), policy example, docs index
- `docs/getting-started.md` — prerequisites, build, smoke test, unit tests, Docker build, first policy tutorial
- `docs/policies.md` — complete policy authoring guide: input schema, deny rule schema, minimal example, content-aware example, fix suggestion example, testing patterns (table-driven + hermetic MapFS), OPA CLI iteration workflow
- `docs/integrations.md` — per-agent/editor setup: VSCode extension pattern, Neovim nvim-lspconfig, Zed, Claude Code MCP, GitHub Copilot Agent, Docker sidecar, connection verification
- `docs/development.md` — build, test, vet, CI, project layout, adding LSP methods, adding policies, ADR process, backlog process, release steps
- `docs/mcp-and-skills.md` — MCP server table, GOV-LSP as MCP tool, skills reference (backlog-manager, remove-ai-slop, speculation-control, strategy-author, decisions), backlog-manager command reference, decisions skill workflow
- `docs/adr/0002-lsp-stdio-transport.md` — stdio-first vs TCP decision with consequences
- `docs/adr/0003-rego-deny-schema.md` — deny rule schema (id, message, level, location, fix) with mapping rationale
- `docs/adr/0004-policies-as-runtime-directory.md` — runtime dir vs embedded vs remote bundle decision
- `docs/adr/README.md` — updated index with 0002, 0003, 0004

**Notes:**
- `docs/` now covers the full developer journey: get started → write policies → integrate with editor/agent → contribute
- All three ADRs document decisions that existed implicitly in the code but had no recorded rationale

---

### 2026-02-28 — Session 1

**Completed:**

- `go.mod`, `go.sum` — Go 1.24 module, OPA SDK v0.70.0 dependency
- `cmd/gov-lsp/main.go` — stdio JSON-RPC loop with LSP Content-Length framing; `--policies` flag and `GOV_LSP_POLICIES` env var override
- `internal/engine/rego.go` — OPA SDK wrapper: load `.rego` files from a directory or `fs.FS`, compile into `PreparedEvalQuery`, evaluate `{filename, extension, path, file_contents}` input, return typed `Violation` structs
- `internal/engine/rego_test.go` — 5 unit tests: lowercase md (violation), SCREAMING_SNAKE_CASE md (no violation), non-md file (no violation), dash-named file → underscore fix, missing policy dir → error
- `internal/lsp/handlers.go` — LSP handlers: `initialize`, `textDocument/didOpen` (immediate), `textDocument/didChange` (200ms debounce), `shutdown`, `exit`; maps `Violation` → `Diagnostic` with 1-based to 0-based position conversion
- `policies/filenames.rego` — SCREAMING_SNAKE_CASE enforcement for `.md` files
- `scripts/smoke_test.sh` — end-to-end smoke test
- `Dockerfile` — multi-stage static build (`CGO_ENABLED=0`) → `scratch` runtime
- `AGENTS.md` — comprehensive agent instructions for Go/OPA/LSP development
- `BACKLOG.md` — 12 work items
- `PROGRESS.md` — this file
- `.github/copilot-instructions.md`, `.github/mcp.json`, `.mcp.json`, `.gitmodules`
- `.github/workflows/ci.yml`, `.github/workflows/sync-skills.yml`
- `docs/adr/README.md`, `docs/adr/0001-use-go-and-opa-sdk.md`

---

## Next Steps

1. W-0003 — `textDocument/codeAction` handler for rename fix
2. W-0005 — Refactor engine to accept `fs.FS` (hermetic tests)
3. W-0008 — Integration tests for LSP handler
4. W-0004 — Policy hot-reload via `workspace/didChangeWatchedFiles`
