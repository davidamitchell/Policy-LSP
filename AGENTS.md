# Agent Instructions

For AI coding agents (Claude Code, GitHub Copilot, etc.) working on this repository.

---

## Project Overview

**GOV-LSP** is a portable, Go-based Secondary Language Server (LSP) that acts as a "Policy Sidecar" for any workspace. It evaluates files against a library of [Open Policy Agent](https://www.openpolicyagent.org/) (OPA) Rego rules and surfaces violations as real-time LSP Diagnostics with automated CodeAction fixes.

### True Goal — Read This First

The policies bundled with this repo (`filenames.rego`, `content.rego`, etc.) are **example policies only**. They demonstrate that the framework works, not what the framework is for.

**The real goal:** Prove that a headless autonomous agent (e.g. GitHub Copilot via the `copilot` CLI) operating *without an IDE* can be given hard policy enforcement rails — exactly as an IDE gives human developers inline squiggles. GOV-LSP is the enforcement layer that fills that gap.

An IDE-free agent has no LSP client, no inline feedback, and no natural guardrails. GOV-LSP's `check` subcommand and `policy-gate.sh` hook are what provide the rails. Every test, script, and integration in this repo should be understood in that context. The specific policy being enforced is secondary.

The two core concerns of this repo are intentionally separate:

1. **Server** — `cmd/gov-lsp/` and `internal/` contain the Go LSP implementation. This is a protocol-correct, stdio-based JSON-RPC server with a clean transport/engine boundary.
2. **Policies** — `policies/` contains Rego files that encode project governance rules. Policies are evaluated by the OPA SDK at runtime; no recompilation is needed to add or change a rule.

### Why This Matters

AI agents and human developers both drift toward local idiom and away from project standards. GOV-LSP provides a feedback loop fast enough to self-correct *before* a change is committed. By encoding rules as Rego, the "Project Laws" remain declarative, versioned, and auditable without modifying the server binary.

---

## Non-Negotiable Constraints

- **Never commit secrets.** No API keys, tokens, or credentials in source. Use environment variables or GitHub Secrets.
- **The LSP protocol must remain correct.** Responses to `initialize` must include the `result` field. Notifications must have no `id`. Violating the protocol silently breaks all LSP clients.
- **The transport layer and the engine are separate concerns.** `cmd/gov-lsp/main.go` handles framing only. `internal/engine/` is pure OPA evaluation logic with no protocol knowledge.
- **Every policy must be end-to-end testable.** A Rego rule that cannot produce a falsifiable result (pass and fail) has no value. Unit tests must cover both the compliant and violating cases.
- **Keep PROGRESS.md updated** after every meaningful commit. It is the primary handoff document between sessions.

---

## Coding Standards

### Language & Runtime

- **Go 1.24+**; use the version declared in `go.mod` as the floor.
- All exported types, functions, and methods must have doc comments.
- No `init()` functions. Explicit initialization over side-effect imports.
- Error values must not be discarded silently. Use `//nolint:errcheck` only for genuinely unrecoverable paths (e.g., flushing a buffer) and add a comment explaining why.
- Avoid `interface{}` / `any` in public APIs. Prefer typed structs. Use `map[string]interface{}` only at the OPA boundary where Rego result types are genuinely dynamic.

### Style

- `gofmt` / `goimports` — code must be formatted before committing.
- Run `go vet ./...` before committing.
- Variable names follow Go convention: short in narrow scope (`v`, `err`), descriptive in wide scope (`violationList`).
- Prefer table-driven tests (`for _, tc := range cases { ... }`) over duplicated test functions.

### Project Layout

```
cmd/
└── gov-lsp/
    └── main.go           # Entry point: CLI flags, JSON-RPC stdio loop

internal/
├── engine/
│   ├── rego.go           # OPA SDK wrapper: load policies, evaluate input
│   └── rego_test.go      # Unit tests for evaluation logic
└── lsp/
    └── handlers.go       # LSP method dispatch, diagnostic mapping

policies/
└── filenames.rego        # Reference policy: SCREAMING_SNAKE_CASE for .md files

docs/
└── adr/                  # Architecture Decision Records (MADR format)
    ├── README.md
    └── NNNN-title.md

scripts/
└── smoke_test.sh         # End-to-end: pipe mock LSP messages, assert diagnostic output
```

### LSP Protocol Rules

- **Request vs Notification**: a message with an `id` field is a request and requires a response. A message without `id` is a notification; do not respond.
- **`initialize` handshake**: always respond before processing any other method.
- **`shutdown` + `exit`**: respond to `shutdown` with `null` result, then exit on `exit`.
- **`publishDiagnostics`**: send as a notification (no `id`). Sending an empty `diagnostics` array clears all diagnostics for a URI.
- **Positions are 0-based** in LSP. Rego `location.line` and `location.column` are 1-based. Convert on the boundary in `handlers.go`, not in the engine.

### OPA / Rego Rules

- All policies must live under the `governance.*` package namespace.
- Use `import future.keywords.if` and `import future.keywords.contains` for idiomatic multi-value rules.
- The `deny` rule returns a **set of objects**. Each object must have at minimum `"id"` and `"message"` fields. Optional fields: `"level"` (`"error"` | `"warning"` | `"info"`), `"location"` (`{"line": int, "column": int}`), `"fix"` (`{"type": "rename" | "insert" | "delete", "value": string}`).
- Policies are loaded at startup from `--policies` flag or `GOV_LSP_POLICIES` env var. They are not hot-reloaded by default (see backlog W-0004).
- Tests for Rego policies belong in Go test files in `internal/engine/`, not in separate `.rego` test files.

### Error Handling

- Engine evaluation errors must be logged to stderr and must not crash the server. Publish an empty diagnostics array on error to avoid stale diagnostics.
- LSP parse errors (malformed JSON-RPC) must log the error and continue the loop — do not `os.Exit`.
- Unknown LSP methods that have an `id` return a `method not found` error response (`code: -32601`).

### Testing

- Tests live in the package they test (`_test.go` suffix in same directory).
- External test packages (`package engine_test`) are preferred for public API coverage.
- Mock all filesystem access using `fs.FS` (`testing/fstest.MapFS`) — do not write to real directories in tests.
- **Bug fixes must start with a failing test.** Confirm the failure before writing the fix.
- The smoke test (`scripts/smoke_test.sh`) is an integration test; run it after building the binary.
- **Headless-agent integration tests must require real prerequisites.** `scripts/test_headless_agent.sh` tests the full enforcement loop with an authenticated `copilot` CLI session. Do not bypass the authentication check or simulate the agent's action to make the test pass — a test that passes without the real environment tells you nothing about whether the framework works. If the test fails because `copilot` is not authenticated, that is the correct result for an unconfigured environment.

### Logging

- Use `log.Printf` to stderr for structured diagnostics during development.
- In production, the server must produce **no output to stderr** except genuine errors. Diagnostic output to stderr corrupts the LSP stdio stream.
- Do not use `fmt.Println` or `log.Fatal` anywhere that could emit on the stdio transport.

---

## Repository Layout

```
cmd/gov-lsp/main.go        # stdio JSON-RPC loop, CLI flags
internal/engine/rego.go    # OPA SDK wrapper
internal/lsp/handlers.go   # LSP handlers + diagnostic mapping
policies/                  # Rego policy files
docs/adr/                  # Architecture Decision Records
scripts/smoke_test.sh      # End-to-end smoke test
Dockerfile                 # Multi-stage static build
AGENTS.md                  # This file
BACKLOG.md                 # Repo improvement backlog
PROGRESS.md                # Session history
.github/
├── copilot-instructions.md
├── mcp.json               # MCP servers for GitHub Copilot
├── skills/                # Skills submodule (davidamitchell/Skills)
└── workflows/
    ├── ci.yml
    └── sync-skills.yml
.claude/
└── skills/                # Same Skills submodule, for Claude Code
.mcp.json                  # MCP servers for Claude Code
```

---

## Agent Skills

`.github/skills/` and `.claude/skills/` are git submodules tracking [`davidamitchell/Skills`](https://github.com/davidamitchell/Skills). A weekly workflow advances the submodule pointer to the latest commit.

| Skill | When it applies |
|---|---|
| `backlog-manager` | Adding, prioritising, or reviewing backlog items in `BACKLOG.md` |
| `remove-ai-slop` | Reviewing output for hollow filler language before committing |
| `speculation-control` | Flagging uncertain assumptions vs established protocol facts |
| `strategy-author` | Producing or reviewing architecture strategy documents |
| `decisions` | Recording Architecture Decision Records in `docs/adr/` |

---

## Policy Enforcement in the Agent Loop

This repository is self-governing. The same `gov-lsp` tool it ships runs against
its own source on every file write.

### Native LSP Client (Claude Code + GitHub Copilot Agent)

`.claude/lsp.json` registers `gov-lsp` as a Language Server for Claude Code.
`.github/lsp.json` does the same for GitHub Copilot Agent. The agent starts the server
via `scripts/lsp-start.sh` (which auto-builds the binary if absent), then sends
`textDocument/didOpen` and `textDocument/didChange` events for every file it views or
modifies. The server streams `textDocument/publishDiagnostics` notifications back —
the same signal path that puts red squiggles in an IDE, delivered directly into the
agent's context. Violations are `Diagnostic` objects with exact line/column positions,
severity, and `data.fix` containing the suggested correction.

This is the highest-fidelity integration: no polling, no manual invocation, violations
appear in real time on every file event.

### Automatic: PostToolUse Hook (Claude Code)

`.claude/settings.json` configures a `PostToolUse` hook on `Write`, `Edit`, and
`MultiEdit`. After every file modification, `.claude/hooks/policy-gate.sh` runs
`gov-lsp check` on the changed file and exits 1 with violation output if any policy
is violated. Claude Code surfaces the output inline and the agent is expected to fix
violations before continuing.

### Explicit: MCP Tool (`gov_check_file`, `gov_check_workspace`)

`gov-lsp mcp` runs as an MCP stdio server registered in `.mcp.json`. Agents can
call `gov_check_file` or `gov_check_workspace` at any point for structured
violation output.

The MCP server starts via `scripts/mcp-start.sh`, which auto-builds the binary if
it is absent.

### GitHub Copilot Agent

`.github/workflows/copilot-setup-steps.yml` builds `gov-lsp` and places it on PATH
before the agent session begins. The agent is expected to run `gov-lsp check .`
and fix violations before submitting changes.

### CI Gate

`.github/workflows/ci.yml` includes a policy-check step that runs
`gov-lsp check .` on every push and pull request.

---

## MCP Configuration

MCP server configs are defined in:

- `.github/mcp.json` — GitHub Copilot Agent
- `.mcp.json` — Claude Code and other agents

Servers available: `gov-lsp` (policy tools), `fetch`, `sequential_thinking`,
`time`, `memory`, `git`, `filesystem`, `brave_search`, `github`, `tavily`

### gov-lsp MCP Tools

| Tool | Input | Returns |
|---|---|---|
| `gov_check_file` | `{ "path": "<file>" }` | Violation list for one file |
| `gov_check_workspace` | `{ "path": "<dir>" }` | Violation summary for entire directory |

---

## Adding a New Policy

1. Create `policies/<name>.rego` with `package governance.<name>`.
2. The policy must define a `deny` set rule. Returning from `deny` means a violation exists.
3. Add Go unit tests in `internal/engine/rego_test.go` covering the compliant and violating cases.
4. Run `go test ./...` and `scripts/smoke_test.sh` to verify end-to-end.
5. Update `BACKLOG.md` (mark the slice done) and `PROGRESS.md`.

## Adding a New LSP Method

1. Add a case to `Handle()` in `internal/lsp/handlers.go`.
2. Write unit tests for the new handler using a mock `Publisher`.
3. If the method changes server capabilities, update `InitializeResult` in `handleInitialize`.
4. Write an ADR in `docs/adr/` if the approach involves a significant design decision.
5. Update `BACKLOG.md` and `PROGRESS.md`.

## Adding an ADR

ADRs follow the [MADR format](https://adr.github.io/madr/). File naming: `docs/adr/NNNN-short-title.md` (zero-padded 4 digits). Update `docs/adr/README.md` after adding.

Status values: `proposed` → `accepted` → `superseded` / `deprecated`

An ADR **must** be written any time:
- A new external dependency is introduced or a major version is bumped
- The transport layer or policy evaluation architecture changes significantly
- A protocol-level decision is made that would be costly to reverse

---

## Slice Completion Checklist

Before marking a backlog slice as done:

- [ ] Code merged to the development branch
- [ ] `go build ./...` succeeds
- [ ] `go vet ./...` passes
- [ ] `go test ./...` passes
- [ ] `scripts/smoke_test.sh` passes (if server binary is affected)
- [ ] `PROGRESS.md` updated
- [ ] Any new ADRs written and indexed
- [ ] README updated if user-facing behaviour changed

---

## Working Methodology

### Root Cause Before Action

When something is broken or unclear, spend time on *why* before reaching for a fix.

Most problems fall into one of three categories:

**Context gap** — the information needed to do the right thing was never provided. Surface the missing information; don't guess.

**Model error** — the mental model of how the system works is wrong. Update the model first, then re-derive the solution. For this project: if LSP client behaviour is unexpected, check the protocol spec before changing the server.

**Specification error** — the task was stated in a way that made the wrong solution look right. Re-examine framing before retrying.

### Before Writing Code

- State what you understand the problem to be. If the statement is fuzzy, stop and sharpen it.
- Identify what you don't know. For LSP: check the [LSP spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/) before assuming. For OPA: check the [OPA policy reference](https://www.openpolicyagent.org/docs/latest/policy-reference/) before assuming.
- Note any assumptions explicitly. Assumptions about Rego evaluation order or Go interface behaviour are common failure modes.

### When an Attempt Fails

- Do not retry the same thing. Understand why it failed first.
- "It didn't work" is not a diagnosis. "The LSP client didn't receive diagnostics because the notification was sent before `initialize` completed" is.
- For Rego evaluation failures: add a `fmt.Println` in a test to print the raw `rego.ResultSet` before interpreting it.

### Progress and Documentation

Update documentation before context degrades, not after.

- After each meaningful unit of work: commit, update status, note what changed and why.
- `PROGRESS.md` is the handoff document. A new session reading it should know exactly where to pick up.

---

## Mini-Retro — After Each Piece of Work

1. **Did the process work?** Was there a test-first cycle where required?
2. **What broke the process?** Identify the exact moment — the assumption, the missing context, the skipped step.
3. **How can the instructions be improved?** If a convention would have prevented the problem, add it to this file *now*.
4. **Is this a pattern?** Has this class of issue appeared before?

The goal: the next agent should not be able to make the same class of mistake.
