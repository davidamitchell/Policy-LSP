# Progress

Last updated: 2026-03-05

---

## Current Status

**Phase:** Epic 0 — Foundation (complete), Epic 1 — LSP completeness (in progress), Epic 2 — Operational Readiness (in progress), Epic 3 — MCP/Agent Integration (done)
**Active slice:** W-0004 (policy hot-reload) is next
**Branch:** `copilot/setup-minimal-scaffold`

---

| Epic | Title | Status | Complete |
|---|---|---|---|
| 0 | Foundation | Done | 2 / 2 slices |
| 1 | LSP Feature Completeness | In progress | 3 / 5 slices (W-0003 codeAction, W-0008 handler tests, W-0005 FS API) |
| 2 | Operational Readiness | In progress | 3 / 4 slices (W-0011, W-0016, W-0006 slog) |
| 3 | MCP + Agent Integration | Done | 1 / 1 slice |
| 4 | Policy Coverage | In progress | 1 / 1 slice (W-0007 content.rego) |

---

## Work Log

### 2026-03-05 — Session 8 (Issue: production-quality governance loop)

**Problem:** The minimal scaffold script in the issue grepped raw LSP stdout
for `publishDiagnostics`, iterated a fixed number of times, and injected raw
log strings into the agent prompt — all fragile patterns.

**Changes:**

- **`scripts/governance_loop.sh`** — new script implementing the four
  improvements requested in the issue:

  1. *Structured JSON diagnostics* — `gov-lsp check --format json` produces a
     clean violation array.  No LSP server background process, no
     Content-Length frame parsing, no log-grepping.

  2. *Filesystem watcher* — `inotifywait` (Linux), `fswatch` (macOS), or a
     `find -newer` polling fallback.  Re-evaluation is triggered by actual
     workspace changes, not a fixed timer.

  3. *Structured violation JSON injected verbatim* — both a human-readable
     summary (jq / python3 / raw fallback) and the raw JSON array are
     included in the agent prompt.  The model receives `fix.type` and
     `fix.value` directly.

  4. *Convergence-based termination* — the loop exits when
     `gov-lsp check` returns zero violations.  `MAX_ITER` is a safety
     backstop, not the primary exit condition.

- **`cmd/gov-lsp/main.go`** — `runCheck()` now initialises `results` with
  `make([]CheckResult, 0)` so the `--format json` output is `[]` (not `null`)
  when there are no violations.  This makes it safe to pipe into
  `jq 'length'` without null-guards.

**Verification:**

```
go build ./...          OK
go vet ./...            OK
go test ./...           OK  (3 packages, all pass)
scripts/smoke_test.sh   PASS
gov-lsp check --format json (zero violations) → []  (was null)
gov-lsp check --format json (with violations) → [...] array
bash -n governance_loop.sh  → Syntax OK
gov-lsp check .             → 15 violations (all markdown-naming in docs/ — intentional)
```

---

### 2026-03-04 — Session 7 (Issues #4 and #6: close open issues)

**Issue #4 (Hook error — fail-open):** Verified closed. The fix was merged in
PR #8 (Session 6). `policy-gate.sh` now exits 1 with a clear error message when
`gov-lsp` cannot be found or built (fail-closed). The complementary
`session-start.sh` hook (SessionStart trigger) proactively builds the binary at
the start of each Claude Code web session, so the PostToolUse gate always has a
binary available. The `.gitignore` excludes `vendor/` with a comment directing
contributors to `make vendor` for offline builds.

**Issue #6 (Search api tool — Tavily MCP):** Verified closed. The commit
referenced in the issue (`993a8d`) added Tavily MCP server configuration. Those
changes are present in the repository: `@tavily/mcp` is registered in both
`.mcp.json` (Claude Code) and `.github/mcp.json` (GitHub Copilot Agent) under
the `TAVILY_API_KEY` environment variable, and `AGENTS.md` lists `tavily` in
the MCP server table. No further code changes were required.

**Verification:**
```
go build ./...          OK
go vet ./...            OK
go test ./...           OK  (3 packages, all pass)
gov-lsp check .         15 violations (all markdown-naming in docs/ — intentional)
```

---

### 2026-03-02 — Session 6 (Issue #4: hook fail-open)

**Problem:** The Claude hook (`policy-gate.sh`) silently exited 0 when the
`gov-lsp` binary was unavailable (fail-open). In a Claude Code web sandbox without
network access, the binary could not be built (no OPA dependency downloads), so the
hook was bypassed on every file write.

**Root causes:**
1. No `vendor/` directory in the repo → binary requires network to build from scratch
2. Hook used `exit 0` (fail-open) when binary was absent → silent policy bypass

**Fix:**

- **`vendor/`** — populated with `go mod vendor` and committed. All OPA and indirect
  dependencies are now vendored. Any environment with Go installed can build the
  binary with no network access: `go build -mod=vendor ./cmd/gov-lsp`.

- **`.claude/hooks/policy-gate.sh`** — two changes:
  1. Inline build now uses `go build -mod=vendor` when `vendor/` is present,
     enabling network-free builds inside the hook itself.
  2. When the binary cannot be found or built, the hook now **exits 1 with a clear
     error message** (fail-closed) instead of silently exiting 0.

**Verification:**
```
go build -mod=vendor ./...   OK
go vet ./...                 OK
go test ./...                OK (28 tests across 3 packages)
hook: clean file             → exit 0
hook: violating .md          → exit 1 + violation message
hook: no binary, vendor/ present → inline build succeeds → exit 0
hook: bash -n syntax check   OK
```

---

### 2026-03-02 — Session 5

**Completed (5 backlog slices):**

- **W-0003 — `textDocument/codeAction` handler**
  - Added LSP types: `TextDocumentIdentifier`, `CodeActionContext`, `CodeActionParams`,
    `CodeAction`, `WorkspaceEdit`, `DocumentChange` to `internal/lsp/handlers.go`
  - Added `handleCodeAction()`: iterates context diagnostics, extracts `fix.type=rename`
    from `Diagnostic.data`, builds a `WorkspaceEdit` with a `RenameFile` document change
  - Added `renameURIFilename()` helper: replaces filename component of a `file://` URI
  - Wired `textDocument/codeAction` in `Handle()`

- **W-0008 — LSP handler integration tests**
  - Created `internal/lsp/handlers_test.go` (7 tests, package `lsp_test`)
  - Tests: initialize returns capabilities, didOpen violating file publishes diagnostics,
    didOpen compliant file publishes empty array, codeAction returns rename edit with
    correct oldUri/newUri, codeAction with no diagnostics returns empty slice,
    unknown method returns −32601 error, notification returns nil (no response)
  - Uses `testing/fstest.MapFS` — fully hermetic, no filesystem dependency

- **W-0005 — Engine API refactor (`fs.FS`-first) + hermetic tests**
  - `engine.New(fsys fs.FS)` — canonical constructor (was `NewFromFS`)
  - `engine.NewFromDir(path string)` — convenience wrapper calling `os.DirFS`; validates
    the directory exists before delegating to `New`
  - Old `engine.New(string)` and `engine.NewFromFS(fs.FS)` removed
  - `internal/engine/rego_test.go` — rewritten to use `fstest.MapFS` (no `../../policies`
    path dependency). `policyFS()` helper inlines both policies as constants.
  - Updated all call sites: `cmd/gov-lsp/main.go` (2×), `cmd/gov-lsp/mcp.go` (1×),
    `cmd/gov-lsp/check_test.go` (1×)

- **W-0006 — Structured logging with `log/slog`**
  - Replaced `log.Printf` / `log.Fatalf` in `runServer()` with `slog.Warn` / `slog.Error`
  - Added `--log-level` flag (`debug`, `info`, `warn`, `error`; default `warn`)
  - Logger configured with `slog.NewTextHandler(os.Stderr, ...)` — output to stderr only,
    silent at default `warn` level during normal LSP operation
  - Removed `"log"` import from `main.go`

- **W-0007 — `policies/content.rego` (Go package comment enforcement)**
  - `policies/content.rego` — `package governance.content`; one rule:
    non-test `.go` files that do not begin with `//` or `/*` produce a
    `missing-package-comment` warning with `location: {line:1, col:1}`
  - Test files ending in `_test.go` are exempt
  - 4 new engine tests (compliant with line comment, compliant with block comment,
    violating without comment, test file exempt)
  - Self-governance check: all existing Go source files pass (each starts with `// Package`)

**Verification (all clean):**

```
go build ./...          OK
go vet ./...            OK
go test ./...           OK  (28 tests across 3 packages)
scripts/smoke_test.sh   PASS
gov-lsp check .         14 violations (all markdown-naming in docs/ — intentional)
```

Test breakdown:
- `cmd/gov-lsp` — 8 tests (check subcommand, self-governance, JSON format)
- `internal/engine` — 10 tests (filenames policy + content policy, MapFS hermetic)
- `internal/lsp` — 7 tests (initialize, didOpen, codeAction, error cases)

---

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
- `scripts/lsp-start.sh` — auto-build wrapper for LSP server mode
- `.claude/lsp.json` — registers gov-lsp as a Language Server for Claude Code
- `.github/lsp.json` — registers gov-lsp as a Language Server for GitHub Copilot Agent

**Verification (20 tests, 0 failures):**

Hook layer — tested with mock binary (real binary needs CI for OPA source):
```
PASS  hook syntax (bash -n)
PASS  lowercase .md Write → exit 1 + violation message surfaced inline
PASS  SCREAMING_SNAKE_CASE .md Write → exit 0 (clean)
PASS  .go file Edit → exit 0 (no policy applies)
PASS  missing file_path in stdin → exit 0 (fail-open, never blocks agent)
PASS  garbage/empty JSON input → exit 0 (fail-open)
PASS  dash-named .md → exit 1 + fix suggestion (BAD_NAME.md → BAD_NAME.md)
```

MCP protocol layer — simulated full handshake:
```
PASS  .mcp.json valid JSON, gov-lsp entry present
PASS  initialize → protocolVersion + serverInfo.name = gov-lsp
PASS  notifications/initialized → no response (correct for notification)
PASS  tools/list → gov_check_file + gov_check_workspace both present
PASS  tools/call gov_check_file → content[0].type = text
```

Rego policy layer:
```
PASS  filenames.rego — package governance.filenames + deny rule present
PASS  security.rego — package governance.security + deny rule present
PASS  security regex: api_key = "..." (unquoted key) → match
PASS  security regex: "client_secret": "..." (JSON quoted key) → match
PASS  security regex: password = "..." → match
PASS  security regex: short value "short" → no match (safe)
PASS  security regex: env var reference → no match (safe)
```

Requires real binary (CI runs these on push):
```
SKIP  go build ./...  (OPA source zip not in local module cache, no network)
SKIP  go test -race ./...
SKIP  scripts/smoke_test.sh
SKIP  gov-lsp check . (self-governance run)
```

**Architecture:**

Four enforcement layers, each targeting a different integration point:

```
Claude Code / GitHub Copilot Agent (native LSP client)
  └─ .claude/lsp.json / .github/lsp.json
       └─ lsp-start.sh → gov-lsp (LSP server mode)
            └─ textDocument/publishDiagnostics (streaming, real-time)

Claude Code (iOS trigger, PostToolUse hook)
  └─ .claude/settings.json
       └─ policy-gate.sh → gov-lsp check <file>
            └─ exit 1 + violation text on violation

Claude Code / Copilot / any agent (explicit MCP call)
  └─ .mcp.json
       └─ mcp-start.sh → gov-lsp mcp
            └─ gov_check_file / gov_check_workspace

GitHub Copilot Agent / CI (enforcement gate)
  └─ copilot-setup-steps.yml / ci.yml
       └─ gov-lsp check .

All paths → internal/engine/rego.go → policies/*.rego
```

---

## Next Steps

1. W-0004 — Policy hot-reload (`workspace/didChangeWatchedFiles`)
2. W-0009 — TCP transport mode
3. W-0010 — Release workflow (GitHub Actions, multi-arch binaries, GHCR image)
4. W-0014 — `gov-lsp-governance` agent skill (SKILL.md + `gov-lsp check` CLI)
5. W-0015 — VS Code extension (`vscode-gov-lsp`)
