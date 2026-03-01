# Progress

Last updated: 2026-03-01

---

## Current Status

**Phase:** Epic 0 — Foundation (complete), Epic 1 — check subcommand (complete), W-0012/W-0011/W-0016 complete
**Active slice:** W-0003 (codeAction handler) is next
**Branch:** `claude/setup-lsp-policy-server-qOq0H`

---

| Epic | Title | Status | Complete |
|---|---|---|---|
| 0 | Foundation | Done | 2 / 2 slices |
| 1 | LSP Feature Completeness | In progress | 1 / 5 slices |
| 2 | Operational Readiness | In progress | 2 / 4 slices (W-0011 devcontainer, W-0016 CI done) |
| 3 | MCP + Agent Integration | In progress | 1 / 1 slice (W-0012 MCP server done) |

---

## Work Log

### 2026-02-28 — Session 3

**Completed:**

- `cmd/gov-lsp/main.go` — added `check` subcommand: `gov-lsp check [--policies <dir>] [--format text|json] [path...]`. Batch policy evaluation from the CLI. Exit code 1 on violations.
- `cmd/gov-lsp/check_test.go` — 8 unit tests covering: violating file, compliant file, non-markdown, multiple files, dash→underscore fix, JSON format, self-governance (docs/ violations), hidden dir skipping
- `Makefile` — `make build`, `make test`, `make vet`, `make smoke`, `make check-policy`, `make clean`
- `.vscode/settings.json` + `.vscode/extensions.json` — VS Code config with Go and OPA extension recommendations; explains the extension gap (W-0015)
- `docs/adr/0005-cli-check-subcommand.md` — ADR documenting the check subcommand decision, alternatives, and path forward
- `docs/adr/README.md` — updated index with ADR 0005
- `docs/getting-started.md` — added batch check section with self-governance demo
- `docs/development.md` — added Makefile section and CLI modes reference
- `BACKLOG.md` — added W-0015 (VS Code extension), W-0016 (GitHub Actions integration); updated W-0014 context (check subcommand now done, no longer a dependency)
- `research/lsap/README.md` — deep-dive section on LSP+LSAP combination

**Self-governance demo output:**

Running `make check-policy` (= `gov-lsp check .`) on this repo produces:
```
docs/getting-started.md: [markdown-naming-violation] SCREAMING_SNAKE_CASE
  Fix (rename): GETTING_STARTED.md
... (11 violations total)
Checked 31 file(s). 11 violation(s) found.
```

This is intentional — the docs use lowercase names to demonstrate the policy.

**Notes:**
- The `check` subcommand gives agents (`gov-lsp check <file>`) a direct path to policy evaluation without an editor, without MCP, and without LSAP. It is the foundation for W-0014 and W-0016.
- `CheckResult` JSON struct matches `Diagnostic.data` — no schema translation needed for agent consumption.

---

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

---

### 2026-03-01 — Session 4

**Completed (agent-loop integration):**

- `CLAUDE.md` — primary instructions for Claude Code: policy system overview,
  bootstrap instructions, violation response protocol, MCP tool reference
- `.claude/settings.json` — PostToolUse hook config (matcher: `Write|Edit|MultiEdit`)
- `.claude/hooks/policy-gate.sh` — hook script: parses tool context from stdin
  (jq or python3), runs `gov-lsp check` on the modified file, exits 1 on violations
- `cmd/gov-lsp/mcp.go` — MCP stdio server (`gov-lsp mcp` subcommand): implements
  MCP 2024-11-05 protocol with `gov_check_file` and `gov_check_workspace` tools
- `cmd/gov-lsp/main.go` — dispatches `mcp` subcommand alongside `check` and server
- `scripts/mcp-start.sh` — auto-build wrapper; builds `gov-lsp` if absent, then
  exec's into MCP mode
- `.mcp.json` — added `gov-lsp` MCP server entry (via `scripts/mcp-start.sh`)
- `.devcontainer/devcontainer.json` — Go 1.24 devcontainer with `postCreateCommand`
  that builds `gov-lsp` immediately
- `.github/workflows/copilot-setup-steps.yml` — builds `gov-lsp`, installs on PATH,
  prints agent instructions before GitHub Copilot agent session starts
- `.github/workflows/ci.yml` — added `policy-check` step (informational, `|| true`)
- `.github/copilot-instructions.md` — updated with policy enforcement section,
  compliance commands, violation response protocol
- `policies/security.rego` — new content-based policy: detects hardcoded credentials
  and API keys in source files using regex; excludes test/example/template files
- `AGENTS.md` — added "Policy Enforcement in the Agent Loop" section documenting
  hook, MCP, CI gate, and Copilot integration
- `Makefile` — added `setup` target and `make setup` to help text
- `docs/adr/0006-agent-loop-integration.md` — ADR for hook + MCP decision
- `docs/adr/README.md` — updated index with ADR 0006

**Architecture:**

Three enforcement layers, each targeting a different integration point:

```
Claude Code (iOS trigger)        GitHub Copilot Agent
  └─ PostToolUse hook              └─ copilot-setup-steps.yml
       └─ policy-gate.sh                └─ gov-lsp check .
            └─ gov-lsp check         └─ CI policy-check step

Claude Code / Copilot / any agent
  └─ MCP tool call
       └─ gov-lsp mcp
            └─ gov_check_file / gov_check_workspace

All paths → internal/engine/rego.go → policies/*.rego
```

---

## Next Steps

1. W-0003 — `textDocument/codeAction` handler for rename fix (one-click fixes in editors)
2. W-0015 — VS Code extension wrapper (live in-editor diagnostics)
3. W-0014 — `gov-lsp-governance` agent skill
4. W-0004 — Policy hot-reload
5. W-0007 — Content policies (Go package comment enforcement, go-header)
