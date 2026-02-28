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

### 2026-02-28 — Session 1

**Completed:**

- `go.mod`, `go.sum` — Go 1.24 module, OPA SDK v0.70.0 dependency
- `cmd/gov-lsp/main.go` — stdio JSON-RPC loop with LSP Content-Length framing; `--policies` flag and `GOV_LSP_POLICIES` env var override
- `internal/engine/rego.go` — OPA SDK wrapper: load `.rego` files from a directory or `fs.FS`, compile into `PreparedEvalQuery`, evaluate `{filename, extension, path, file_contents}` input, return typed `Violation` structs
- `internal/engine/rego_test.go` — 5 unit tests: lowercase md (violation), SCREAMING_SNAKE_CASE md (no violation), non-md file (no violation), dash-named file → underscore fix, missing policy dir → error
- `internal/lsp/handlers.go` — LSP handlers: `initialize` (capabilities), `textDocument/didOpen` (immediate evaluation), `textDocument/didChange` (200ms debounce), `shutdown`, `exit`; maps `Violation` → `Diagnostic` with 1-based to 0-based position conversion; fix data embedded in `Diagnostic.data`
- `policies/filenames.rego` — SCREAMING_SNAKE_CASE enforcement for `.md` files; deny returns `{id, level, message, location, fix}` object
- `scripts/smoke_test.sh` — end-to-end smoke test: sends `initialize` + `didOpen` for `lower_case.md`, asserts severity-1 diagnostic with `LOWER_CASE.md` fix
- `Dockerfile` — multi-stage static build (`CGO_ENABLED=0`) targeting `scratch` runtime image
- `AGENTS.md` — comprehensive agent instructions for Go/OPA/LSP development; includes CoT methodology, coding standards, LSP protocol rules, Rego conventions, error handling, testing, and mini-retro pattern
- `BACKLOG.md` — 12 work items covering next LSP features, operational readiness, and MCP integration
- `PROGRESS.md` — this file
- `.github/copilot-instructions.md` — stub pointing to `AGENTS.md`
- `.github/mcp.json` — MCP server config for GitHub Copilot Agent
- `.mcp.json` — MCP server config for Claude Code
- `.github/workflows/ci.yml` — Go CI: build, vet, test, smoke test
- `.github/workflows/sync-skills.yml` — weekly skills submodule sync
- `.gitmodules` — `davidamitchell/Skills` submodule at `.github/skills/` and `.claude/skills/`
- `docs/adr/README.md` — ADR index
- `docs/adr/0001-use-go-and-opa-sdk.md` — first ADR documenting the Go + OPA SDK decision

**Key decisions:**
- OPA v0.70.0 (not v1.x) to stay within Go 1.24 floor; tracked in ADR-0001
- Policy directory is runtime-configurable; no embedded policies to keep the binary independent of policy content
- Transport (framing) is isolated in `main.go`; handlers have no transport knowledge — enables future TCP/WebSocket without touching the engine

**Notes:**
- The `.gitignore` entry `gov-lsp` was initially set without a leading `/`, causing `cmd/gov-lsp/main.go` to be excluded from git. Fixed to `/gov-lsp`.
- Skills submodules (`.github/skills/`, `.claude/skills/`) are declared in `.gitmodules` but must be initialised manually: `git submodule update --init --recursive`

---

## Next Steps

1. W-0003 — `textDocument/codeAction` handler for rename fix
2. W-0005 — Refactor engine to accept `fs.FS` (hermetic tests)
3. W-0008 — Integration tests for LSP handler
4. W-0004 — Policy hot-reload via `workspace/didChangeWatchedFiles`
