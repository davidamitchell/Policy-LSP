# Agent Instructions

For AI coding agents (Claude Code, GitHub Copilot, etc.) working on this repository.

---

## Project Overview

**GOV-LSP** is a portable, Go-based Secondary Language Server (LSP) that acts as a "Policy Sidecar" for any workspace. It evaluates files against a library of [Open Policy Agent](https://www.openpolicyagent.org/) (OPA) Rego rules and surfaces violations as real-time LSP Diagnostics with automated CodeAction fixes.

### True Goal — Read This First

The policies bundled with this repo (`filenames.rego`, `content.rego`, etc.) are **example policies only**. They demonstrate that the framework works, not what the framework is for.

**The real goal:** Prove that a headless autonomous agent (e.g. GitHub Copilot via the `copilot` CLI) operating *without an IDE* can be given hard policy enforcement rails — exactly as an IDE gives human developers inline squiggles. GOV-LSP is the enforcement layer that fills that gap.

An IDE-free agent has no LSP client, no inline feedback, and no natural guardrails. GOV-LSP's MCP tools (`gov_check_file`, `gov_check_workspace`) and `policy-gate.sh` hook are what provide the rails. Every test, script, and integration in this repo should be understood in that context. The specific policy being enforced is secondary.

**What "enforcement works" means:** An agent given governance tools as part of its environment catches its own policy violations and self-corrects — before the violating file persists. The test for this is the outcome: the policy-violating file must not exist when the agent finishes. If it does exist, enforcement failed.

**Success Metrics for Code Quality:** All features must converge in tests (e.g., governance loops must reach zero violations within a small, bounded number of iterations — typically 5 or fewer for any real workspace — not spiral endlessly). Basic errors like undefined flags, missing dependencies, or misleading outputs indicate a failure in problem-solving — anticipate and test for them upfront.

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
- **Always verify external dependencies and CLI options before use.** Check that binaries and flags exist (e.g., run `copilot --help` before assuming `--trust` is a valid option). Provide fallbacks or clear error messages when tools are absent.
- **Logic must detect and prevent infinite loops.** In scripts like `governance_loop.sh`, hash the previous violation set per iteration and exit early when there is no change. Cap iterations at a sensible maximum.
- **Prompts and outputs must be resilient to parsing errors.** Include fallbacks for empty or malformed data. Never emit "No violations found" when violations are present; validate with a concrete example before shipping.

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

### Bash and Python Scripts

- Use `set -euo pipefail` at the top of every Bash script to fail on errors.
- Always quote variables (`"$var"`) to prevent word-splitting.
- Wrap external commands in functions that check exit codes and log failures (e.g., `"Command failed: $output"`).
- For `jq` / JSON parsing, dump raw output to a temp file (`mktemp`) when debugging manually and add unit tests for edge cases like empty arrays.
- In Python, use type hints and handle exceptions explicitly (e.g., `json.JSONDecodeError`).

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

Scripts must include preflight functions that check required binaries, valid flags, and optional dependencies before executing any substantive logic.

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
- Include a brief comment in each policy with an example compliant and violating input so agents can understand expected behaviour without reading the tests.

### Error Handling

- Engine evaluation errors must be logged to stderr and must not crash the server. Publish an empty diagnostics array on error to avoid stale diagnostics.
- LSP parse errors (malformed JSON-RPC) must log the error and continue the loop — do not `os.Exit`.
- Unknown LSP methods that have an `id` return a `method not found` error response (`code: -32601`).
- In scripts, wrap external commands (e.g., `jq`, `copilot`) in functions that check exit codes and provide meaningful error output (e.g., `"gov-lsp check failed: $output"`). Do not silently swallow non-zero exit codes.

### Testing

- Tests live in the package they test (`_test.go` suffix in same directory).
- External test packages (`package engine_test`) are preferred for public API coverage.
- Mock all filesystem access using `fs.FS` (`testing/fstest.MapFS`) — do not write to real directories in tests.
- **Bug fixes must start with a failing test.** Confirm the failure before writing the fix.
- The smoke test (`scripts/smoke_test.sh`) is an integration test; run it after building the binary.
- **Headless-agent integration tests prove the outcome, not the check.** `scripts/test_headless_agent.sh` tests the full enforcement loop with an authenticated `copilot` CLI session. The test creates a workspace with gov-lsp registered as its Language Server in `.github/lsp.json` (the `lspServers` schema the Copilot CLI reads at startup). Enforcement happens **inside the agent's session** — the Copilot CLI connects to gov-lsp via the LSP protocol and the agent receives inline diagnostics automatically when it opens or edits files. The test script never calls `gov-lsp check` directly. The test asserts the outcome: the policy-violating file must NOT exist when the agent finishes. **If `notes.md` exists, enforcement failed — the test must fail.** Do not bypass the authentication check or simulate the agent's action to make the test pass — a test that passes without the real environment tells you nothing about whether the framework works. If the test fails because `copilot` is not authenticated, that is the correct result for an unconfigured environment.
- **Tests must include both negative AND positive assertions.** A negative assertion (violating file absent) is necessary but not sufficient. Always add a positive assertion confirming the compliant outcome (e.g., `MY_NOTES.md` exists). Without the positive assertion, a test can pass even if the agent deleted the file entirely rather than renaming it — which is wrong behaviour that would go undetected. The filenames policy renames `my-notes.md` → `MY_NOTES.md` (not `MY-NOTES.md` — `upper(replace("my-notes", "-", "_"))` = `MY_NOTES`).
- **CI artifact upload requires the log file to survive the test script's EXIT trap.** If `trap 'rm -rf ... $LOG_FILE' EXIT` is set, the file is deleted when the script process exits — before the separate CI artifact upload step runs. Remove log files from the EXIT trap; let the CI runner's own cleanup handle `/tmp`. Only include workspace directories in the trap.
- **Add unit tests for all logic paths.** For Bash scripts use Bats; for Python use pytest. Cover happy paths, error paths (e.g., missing tool), and boundary cases (e.g., zero violations, malformed JSON). For rename-based policies, always test the exact `fix.value` produced (`MY_NOTES.md`, not a guess like `MY-NOTES.md`).

### Logging

- Use `log.Printf` to stderr for structured diagnostics during development.
- In production, the server must produce **no output to stderr** except genuine errors. Diagnostic output to stderr corrupts the LSP stdio stream.
- Do not use `fmt.Println` or `log.Fatal` anywhere that could emit on the stdio transport.

---

## Common Pitfalls and Prevention

To avoid basic errors that break tests or loops:

- **Undefined flags/options:** Always implement standard flags (`--version`, `--help`). Test CLI invocations in preflights before assuming options like `--trust` exist.
- **Missing dependencies:** Scripts must check for tools (`inotifywait`, `jq`) at startup and either fall back to polling or exit with a clear message. In CI/container environments, install required tools in the setup step; do not auto-install silently in user environments.
- **Formatting/parsing bugs:** Debug output pipelines with raw dumps (e.g., `echo "$json" > /tmp/debug.json`). Handle empty arrays explicitly — never produce "No violations found" when violations are present.
- **Looping logic flaws:** Compare violation fingerprints (e.g., `sha256sum`) across iterations. Exit immediately on no-change states; cap at a maximum iteration count.
- **Agent inaction:** Prompts must be imperative and include concrete examples (e.g., `mv notes.md NOTES.md`) plus a self-validation step so the agent can confirm the fix.

---

## Debugging and Problem-Solving Guidelines

When generating or fixing code:

- **Step-by-step before coding:** Outline (1) problem analysis, (2) assumptions checked, (3) solution plan, (4) tests needed. Do not skip to implementation.
- **Reproduce errors first:** For failing tests or scripts, run with verbose flags (`bash -x script.sh`, `go test -v ./...`) and read the full output before changing anything.
- **Validate outputs explicitly:** After a change, verify the result directly (e.g., `ls notes.md` must fail, `go test ./...` must pass). Update `PROGRESS.md` with findings.
- **Prompt engineering for agent loops:** Use imperative language, chain-of-thought steps, and few-shot examples. Include a fallback action for every conditional branch.

---

## Confirmed Behaviors and Known Facts

These are empirically confirmed findings that agents must not re-investigate without new evidence:

- **Copilot CLI `--autopilot` mode does NOT start gov-lsp.** Confirmed 2026-03-05 (W-0034). The `lspServers` config in `.github/lsp.json` is interactive-session-only. In `--autopilot` mode the LSP server is never launched. Do not rely on LSP diagnostics reaching a Copilot agent running in autopilot; use the MCP tool path instead.
- **Canonical headless invocation:** `copilot -p "PROMPT" --autopilot --allow-all` with `GH_TOKEN` env var. Install via `npm install -g @github/copilot`.
- **Governance loop location:** The canonical loop is `scripts/governance_loop/governance_loop.sh`. `scripts/governance_loop.sh` is a compatibility shim. LSP simulation uses `scripts/governance_loop/lsp_check.py`. Set `USE_LSP_SIM=0` to force batch-check mode.
- **Logging:** All Go layers use `slog` (debug default). Shell scripts source `scripts/lib/logging.sh` for `log_debug`/`info`/`warn`/`error` with ISO timestamps. `LOG_LEVEL` env var controls both Go (`--log-level` flag) and shell verbosity.

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
BACKLOG.md                 # Repo improvement backlog
PROGRESS.md                # Session history
CHANGELOG.md               # User-facing change history
.github/
├── copilot-instructions.md  # Agent instructions (single source of truth)
├── mcp.json               # MCP servers for GitHub Copilot
├── skills/                # Skills submodule (davidamitchell/Skills)
└── workflows/
    ├── ci.yml
    └── sync-skills.yml
docs/adr/                  # Architecture Decision Records
.mcp.json                  # MCP servers for Claude Code and other agents
```

---

## Agent Skills

Skills are available at `.github/skills/`. Key skills: `backlog-manager`, `research`, `technical-writer`, `code-review`, `strategy-author`, `decisions`.

`.github/skills/` is a git submodule tracking [`davidamitchell/Skills`](https://github.com/davidamitchell/Skills). A weekly workflow advances the submodule pointer to the latest commit.

| Skill | When it applies |
|---|---|
| `backlog-manager` | Adding, prioritising, or reviewing backlog items in `BACKLOG.md` |
| `remove-ai-slop` | Reviewing output for hollow filler language before committing |
| `speculation-control` | Flagging uncertain assumptions vs established protocol facts |
| `strategy-author` | Producing or reviewing architecture strategy documents |
| `decisions` | Recording Architecture Decision Records in `docs/adr/` |

---

## Backlog

The backlog is `BACKLOG.md` at the repo root. Use the `backlog-manager` skill from `.github/skills/backlog-manager/SKILL.md`. Read it at the start of every session.

---

## ADR Mandate

Every non-trivial architectural or design decision must be recorded as an ADR in `docs/adr/`. Use the `decisions` skill from `.github/skills/decisions/SKILL.md`. Format is MADR. Files named `docs/adr/NNNN-short-title.md`.

---

## PROGRESS.md Mandate

Append a dated entry to `PROGRESS.md` after every meaningful session or PR. Never edit old entries — append only. Format: `## YYYY-MM-DD` then what changed and why. Append-only prevents merge conflicts.

---

## CHANGELOG.md Mandate

Record every user-facing change in `CHANGELOG.md`. Follow Keep-a-Changelog 1.0.0. New entries go under `## [Unreleased]` at the top.

---

## Policy Enforcement in the Agent Loop

This repository is self-governing. The same `gov-lsp` tool it ships runs against
its own source on every file write.

### Native LSP Client (GitHub Copilot CLI)

`.github/lsp.json` registers `gov-lsp` as a Language Server for the GitHub Copilot CLI using the `lspServers`
schema the CLI reads at startup:

```json
{
  "lspServers": {
    "gov-lsp": {
      "command": "bash",
      "args": ["scripts/lsp-start.sh"],
      "fileExtensions": { ".md": "markdown", ".go": "go", ".rego": "rego" }
    }
  }
}
```

The CLI connects to the declared LSP server via stdio at session start. When the agent
creates or edits a file, the Copilot CLI sends `textDocument/didOpen` and
`textDocument/didChange` events; gov-lsp responds with `textDocument/publishDiagnostics`
— the same signal path that puts red squiggles in an IDE, delivered directly into the
agent's context. Violations are `Diagnostic` objects with exact line/column positions,
severity, and `data.fix` containing the suggested correction.

This is the highest-fidelity integration: no polling, no manual invocation, violations
appear in real time on every file event.

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
