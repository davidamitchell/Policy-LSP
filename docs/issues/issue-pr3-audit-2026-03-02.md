# Issue Audit — PR #3 Tests, Agent Enforcement, and LSP-as-Client Feasibility

_2026-03-02. Covers the test audit of PR #3 (W-0003/W-0005/W-0006/W-0007/W-0008), an
evaluation of whether the current system actually prevents autonomous agent violations,
and a feasibility assessment for configuring agents to mimic IDE-LSP interaction._

---

## 1. Context

PR #3 (branch `copilot/review-backlog-outcomes`) delivers five backlog items and
includes Copilot's claim that eight handler unit tests plus six binary end-to-end tests
"prove the protocol works." This audit evaluates that claim, then answers two
architectural questions that the test results expose.

**Tooling note**: the `mcp__github__get_pull_request_files` MCP tool call failed
at the start of this session with:

```
MCP error -32603: fetch failed
```

See §6 for full diagnosis. The audit proceeded via `WebFetch` on the PR HTML page and
`git fetch origin copilot/review-backlog-outcomes` — both succeeded. No information
was lost; the same diff data was available by both paths.

---

## 2. PR #3 Test Audit

### 2.1 Summary Table

| Test file | Count | Method | What it covers |
|---|---|---|---|
| `internal/lsp/handlers_test.go` | 8 | Unit | initialize, didOpen, codeAction, unknown method, notification |
| `internal/engine/rego_test.go` | 12 | Unit | OPA evaluation: filenames policy + content policy |
| `cmd/gov-lsp/check_test.go` | 8 | Unit | `runCheck`: text/JSON output, multi-file, hidden dirs, self-governance |
| `cmd/gov-lsp/e2e_test.go` | 6 | Binary E2E | Full LSP wire protocol over stdin/stdout |

### 2.2 Critical Issues

**C-1 — `textDocument/didChange` is completely untested**

Not one test in any of the four files exercises this method. It is the primary LSP
event: editors emit it on every keystroke. The handler contains a 200 ms debounce
timer using `time.AfterFunc` that captures the request context in a goroutine
closure. The debounce interaction, the goroutine lifecycle, and the resulting
`publishDiagnostics` notification are entirely unverified.

**C-2 — Three disconnected inline copies of the Rego policy**

The filenames policy appears as a verbatim inline string in:

| File | Constant name |
|---|---|
| `cmd/gov-lsp/check_test.go` | (anonymous) |
| `internal/engine/rego_test.go` | `filenamesPolicy` |
| `internal/lsp/handlers_test.go` | `filenamePolicy` |

None of these copies is checked against `policies/filenames.rego` on disk. If
the real policy changes — a regex update, a new fix field, a renamed key — all
three test files silently continue testing the old behaviour. The test suite does
not validate the policies the binary actually ships.

**C-3 — `TestE2E_Shutdown` does not assert the LSP exit code**

```go
case <-done:
    // exited, any exit code is acceptable (SIGKILL from cleanup vs clean exit)
```

The LSP specification requires exit code 0 after a well-formed `shutdown` + `exit`
sequence. The test accepts any exit code, meaning it would pass if the server panicked.
The comment conflates cleanup SIGKILL timing with the process's own exit code.

**C-4 — Diagnostic ordering assumption in `TestE2E_DidOpen_ViolatingFile`**

```go
diag, ok := diags[0].(map[string]interface{})
```

Checks position 0 rather than searching by `code`. Safe today because only the
filenames policy fires for `.md` files. Breaks if any future policy fires first.

### 2.3 Significant Coverage Gaps

| Gap | Risk |
|---|---|
| `security.rego` — zero tests at any level | Highest-stakes policy, completely unverified |
| W-0006 `--log-level` flag — no assertions | Claimed delivered; the flag is wired but never verified |
| Content policy — engine tests only, no LSP e2e | Full pipeline (LSP → engine → content policy → diagnostic) unproven |
| `TestHandle_Notification_ReturnsNil` — only tests `initialized` (named case), not the default notification path | Default-branch coverage gap |
| `TestRunCheck_SelfGovernance_DetectsRepoViolations` — never asserts `count > 0` | Self-governance property is logged, not asserted |
| `check_test.go` engine loads only `filenames.rego` | `TestRunCheck_NonMarkdownFile_NoViolation` would fail if `content.rego` were included |

### 2.4 Latent Protocol Bug

`filenameFromURI` strips `file://` and calls `filepath.Base`:

```go
func filenameFromURI(uri string) string {
    path := strings.TrimPrefix(uri, "file://")
    return filepath.Base(path)
}
```

File URIs are percent-encoded. `file:///workspace/my%20file.md` produces the
filename `my%20file.md`. The Rego regex `^[A-Z0-9_]+$` does not include `%`, so
`MY%20FILE.md` fails the compliant check: a valid uppercase file with a space in
the path would be falsely flagged. Untested and latent in production.

### 2.5 What the Tests Do Well

- The e2e protocol framework (Content-Length framing, `recvUntil` predicate, session
  lifecycle management) is solid and would catch real LSP protocol regressions.
- `TestE2E_CodeAction_RenameRoundTrip` uses the server-emitted diagnostic to drive
  the codeAction — a genuine round-trip, not a hardcoded input.
- `fstest.MapFS` isolation in unit tests is the right approach for hermetic tests.
- The `check` subcommand tests cover text/JSON format, multi-file walks, hidden
  directory skipping, and dash-to-underscore fix suggestions.

### 2.6 Verdict

Copilot's claim that "these tests prove the protocol works" is **overstated**.

The tests prove the initialize → didOpen → publishDiagnostics → codeAction pipeline
works for `.md` files under the filenames policy. They do not prove:
- The `didChange` handler works at all
- The security policy catches anything
- The shipped policies match what the tests evaluate
- The `--log-level` flag has any effect
- The exit protocol is spec-compliant

---

## 3. Will This LSP Prevent an Autonomous Agent From Violating Policies?

_Question: a purely autonomous coding agent, no IDE. Will the LSP stop it?_

**Short answer: No — not via the LSP server. Partially — via the hook and check CLI.**

### 3.1 The Three Enforcement Paths

The system has three distinct enforcement paths. They do not use the same code:

| Path | Mechanism | What triggers it | Who it works for |
|---|---|---|---|
| **LSP server** | Full LSP protocol: `didOpen` → `publishDiagnostics` | An IDE (or LSP client) sending events | Claude Code CLI (via `lsp.json`), VS Code, Neovim, Zed |
| **PostToolUse hook** | `policy-gate.sh` calls `gov-lsp check` (CLI, not LSP) | Every Write / Edit / MultiEdit call in Claude Code | Claude Code CLI only |
| **MCP tool** | `gov_check_file` / `gov_check_workspace` tool call | Agent explicitly calls the tool | Any MCP-capable agent that chooses to call it |

### 3.2 For a Purely Autonomous Agent (No IDE)

The LSP server is never started. No process is spawned. No `initialize` handshake
occurs. No `textDocument/didOpen` events are sent. No `publishDiagnostics`
notifications are received. **The LSP server contributes nothing to enforcement
without something managing its lifecycle.**

What actually enforces policy depends on which agent and which runtime:

**Claude Code CLI (desktop/server)**
The PostToolUse hook fires after every Write/Edit/MultiEdit and runs `gov-lsp check`.
This IS enforcement — violations surface inline and block continuation. The hook is
the primary enforcement layer for this agent type. Caveat: the hook fails-open if
the binary is absent (`exit 0` by design). In this sandbox (no network → `go build`
fails → no binary), the hook does nothing. An agent running here today could write
violations freely.

**Claude Code (iOS / web chat app)**
No hook mechanism. No shell execution. No MCP server processes running locally. The
only enforcement is CLAUDE.md appearing in the system context and Claude following its
written instructions. There is no runtime enforcement — it is entirely prompt-based.

**GitHub Copilot (VS Code)**
VS Code manages the LSP server lifecycle. The server is started, events are sent, and
the Problems panel receives diagnostics. This IS enforcement — but it requires an
open editor window and the `lsp-start.sh` integration configured. In an autonomous
agentic session without VS Code open (e.g., GitHub Actions `copilot-setup-steps`
workflow), there is no LSP client and no hook. Only MCP (if configured) or explicit
`gov-lsp check` calls in instructions.

**GitHub Copilot (GitHub Actions — fully autonomous, no IDE)**
No hook. No LSP client. No MCP unless `mcpServers` is configured and the runner
has the binary. Enforcement reduces to: instructions in `.github/copilot-instructions.md`
telling Copilot to run `./gov-lsp check` after edits. Prompt-based, not protocol-based.

### 3.3 The Hook Is Untested — and Currently Broken

The test suite has zero coverage of `policy-gate.sh`. The hook's critical paths:
- Binary not found → fails-open (`exit 0`) — untested
- `jq` unavailable → falls back to Python → untested
- File path extraction failure → exits 0 silently — untested
- Binary exits 1 with output → agent sees violation message — untested

In the current sandbox environment, `make build` fails (no network to download OPA
dependency). The hook's auto-build attempt also fails. The hook silently exits 0 for
every file write. **The enforcement layer is invisible in this environment.**

### 3.4 Summary

The LSP server alone cannot prevent violations from an autonomous agent that does not
manage the LSP lifecycle. The system prevents violations through the hook (Claude Code
CLI) + MCP tool (any capable agent). Enforcement is complete only when:
1. The binary is built and available.
2. The agent's runtime supports hooks (Claude Code CLI) or the agent explicitly calls
   the MCP/check tool.
3. The agent is instructed to treat hook exit-1 as a blocking error.

---

## 4. Can We Configure Autonomous Agents to Mimic IDE-LSP Interaction?

_Question: can Claude (iOS chat) and GitHub Copilot be set up to act as LSP clients,
so the LSP server becomes a universal policy interface any agent can consume?_

### 4.1 What an IDE Does (the Full Lifecycle)

```
IDE startup
  → spawn LSP server process (pipes to stdin/stdout)
  → send: {"method":"initialize","id":1,"params":{"rootUri":"..."}}
  ← recv: {"result":{"capabilities":{"textDocumentSync":1,"codeActionProvider":true}}}
  → send: {"method":"initialized"}                   (notification, no id)

File opened
  → send: {"method":"textDocument/didOpen","params":{"textDocument":{...}}}
  ← recv: {"method":"textDocument/publishDiagnostics","params":{"diagnostics":[...]}}

User requests fix
  → send: {"method":"textDocument/codeAction","id":5,"params":{...}}
  ← recv: {"result":[{"kind":"quickfix","edit":{"documentChanges":[{"kind":"rename"}]}}]}

Session end
  → send: {"method":"shutdown","id":99}
  ← recv: {"id":99,"result":null}
  → send: {"method":"exit"}
  (process exits, code 0)
```

This lifecycle requires: a persistent process, bidirectional pipes, async notification
handling, and application of `WorkspaceEdit` responses. The e2e test harness in
`cmd/gov-lsp/e2e_test.go` is a 200-line implementation of exactly this.

### 4.2 Can Agents Do This?

| Agent | Can manage LSP lifecycle? | Practical path |
|---|---|---|
| Claude Code CLI | ✅ via Bash tool + background process | Already done via `lsp.json` registration |
| Claude (iOS / web chat) | ❌ No shell, no filesystem, no background processes | Prompt-only; see §4.4 |
| Copilot in VS Code | ✅ VS Code manages it natively | Configure `lsp-start.sh`; works today |
| Copilot in GitHub Actions | ❌ No IDE host, no persistent process | Use MCP or check CLI |
| Any MCP-capable agent | Partial ✅ via `gov-lsp-mcp` tool | MCP wraps the engine; no protocol management needed |

### 4.3 Three Viable Paths — Ordered by Complexity

**Path 1 (simplest): `check` CLI + agent instructions**

```bash
./gov-lsp check --format text <file>
```

The agent is instructed to run this after every file write. Output is plain text.
No process management. No protocol. Works in CI, works in any shell-capable agent.
Already implemented. This is what the hook does.

**Path 2 (agent-native): MCP tool call**

```json
{"method": "tools/call", "params": {"name": "gov_check_file", "arguments": {"path": "..."}}}
```

The MCP server (`scripts/mcp-start.sh`) handles spawning gov-lsp, running the
engine, and returning structured JSON. No LSP protocol in the agent. Copilot supports
MCP via `mcpServers` config. Claude Code supports it via `.mcp.json`. Already
built (W-0012). The gap: untested in the current test suite.

**Path 3 (full mimic): Agent manages the LSP process directly**

Agent background-spawns the server, manually frames JSON-RPC messages, reads
`publishDiagnostics` notifications asynchronously. Possible for Claude Code CLI
via Bash tool. Complex (200 lines in the test harness) and brittle. The only
advantage over Path 1 is receiving real-time streaming diagnostics during multi-file
operations — which is the same data as calling `check` after each file.

**Recommendation**: Path 1 for CI and Copilot Actions. Path 2 for Claude Code
and Copilot Agent in VS Code. Path 3 is not worth the complexity for policy
enforcement; it is the domain of code intelligence tools (e.g., `gopls`) where
incremental streaming matters.

### 4.4 Claude in the iOS Chat App — No Runtime Enforcement

The iOS Claude.ai app has no filesystem, no shell, no background processes, and no
MCP server connections. It cannot run `gov-lsp check`, cannot spawn the LSP server,
and cannot execute hooks. The session context (including CLAUDE.md) is available as
a system prompt, but all enforcement is **purely prompt-based**:
- Claude reads CLAUDE.md and knows the policies
- Claude can describe what violations would exist
- Claude cannot verify its own output against the Rego engine at runtime

The practical implication: when working from the iOS app and pushing to a branch,
CI (`github/workflows/ci.yml` with `gov-lsp check`) is the only runtime enforcement
layer. The agent loop works correctly only when the CI runner has the binary built.

### 4.5 Making the LSP a Universal Consumer Interface

The LSAP research (see `research/lsap/README.md`) identifies the right framing:

```
┌─────────────────────────────────────┐
│      Agent (any: Claude, Copilot)   │
│  understands: natural language,     │
│  Markdown, tool calls               │
└──────────────┬──────────────────────┘
               │ cognitive request
               ▼
┌─────────────────────────────────────┐
│  MCP / check CLI / gov-lsp-skill    │  ← the translation layer
│  (W-0012, W-0014, W-0013)           │
└──────────────┬──────────────────────┘
               │ engine.Evaluate()
               ▼
┌─────────────────────────────────────┐
│  GOV-LSP Engine (OPA + Rego)        │
│  returns: violations + fix data     │
└─────────────────────────────────────┘
```

The LSP server is **one consumer interface** (for IDE clients). MCP and the check CLI
are the **agent interfaces** to the same engine. The LSP protocol itself is not the
right interface for autonomous agents — it was designed for editors, not for programs
that receive one structured response and apply a fix.

The design of `diagnostic.data` (self-contained fix with `type` and `value`) was
exactly the right call: the same data is consumable via LSP (WorkspaceEdit), MCP
(JSON tool response), CLI (text/json output), and a future LSAP endpoint (Markdown
report). The engine is the universal source; the transports are consumer-specific.

---

## 5. Issues to Open / Backlog Items

| # | Area | Action | Priority |
|---|---|---|---|
| B-1 | Test coverage | Add `textDocument/didChange` tests (unit + e2e with debounce timing) | High |
| B-2 | Test coverage | Replace all three inline policy copies with a call to `NewFromDir("../../policies")` — or add a golden-file test that compares inline vs disk | High |
| B-3 | Test coverage | Add `security.rego` tests to `rego_test.go` (credential caught, false-positive cases) | High |
| B-4 | Test coverage | Assert exit code = 0 in `TestE2E_Shutdown` | Medium |
| B-5 | Test coverage | Add LSP e2e test: open `.go` file without comment → expect `missing-package-comment` diagnostic | Medium |
| B-6 | Test coverage | Fix `TestRunCheck_SelfGovernance_DetectsRepoViolations` to assert `count > 0` | Low |
| B-7 | Bug | Fix `filenameFromURI` to call `url.PathUnescape` before `filepath.Base` | Medium |
| B-8 | Hook | Add test coverage for `policy-gate.sh`: binary-missing path, jq-absent path, violation path | High |
| B-9 | W-0006 | Add test verifying `--log-level debug` produces log output, `error` suppresses it | Low |
| B-10 | Architecture | Document that the LSP server is for IDE clients only; the check CLI + MCP are the agent interfaces. Update CLAUDE.md accordingly. | Medium |
| B-11 | CI | Add a CI job that runs `make build` + `make check-policy` to verify the binary is always buildable and self-governance is always verified | High |
| W-0014 | Backlog | `gov-lsp-skill` — SKILL.md wrapper for `gov-lsp check` so any skill-aware agent gets governance without hooks, MCP, or LSP | Ready to build |

---

## 6. MCP GitHub Tool Failure — Diagnosis and Mitigation

**Failure**: `mcp__github__get_pull_request` and `mcp__github__get_pull_request_files`
both returned `MCP error -32603: fetch failed` at session start.

**Root cause assessment**:

The sandbox environment has no outbound network access. This is evidenced by:
- `make build` failing: `dial tcp: lookup storage.googleapis.com … connection refused`
- The same DNS failure pattern for Go module downloads

The MCP GitHub server (`@modelcontextprotocol/server-github`) makes direct HTTPS
requests to `api.github.com`. In this sandbox, DNS resolution of `api.github.com`
fails for the same reason Go's module proxy fails. The MCP server returns -32603
(internal error) when the underlying HTTP call fails.

The local Gitea mirror (`http://127.0.0.1:21766`) is accessible to git commands but
the MCP server does not know about it and uses its own HTTP client.

**Mitigation used**:
1. `WebFetch` against `https://github.com/davidamitchell/Policy-LSP/pull/3` — succeeded
   (the web fetch proxy is on a different network path than the MCP server).
2. `git fetch origin copilot/review-backlog-outcomes` — succeeded via the local mirror.

Both provided complete PR content. No information gap.

**Recommended fixes**:

1. Add a health-check call at session start (e.g., `get_pull_request` on a known
   public repo) and surface the error immediately rather than discovering it mid-task.
2. Configure the MCP GitHub server with a `GITHUB_API_URL` environment variable
   pointing at the local Gitea mirror when network is restricted.
3. In `scripts/mcp-start.sh`, detect network availability before starting MCP servers
   that require outbound access and skip them with a clear warning.

---

_→ `PR3_TEST_AUDIT.md` contains the full per-test breakdown with code excerpts_
_→ `research/lsap/README.md` covers the LSAP/MCP/skill transport landscape in depth_
_→ `research/lsp-agent-integration/README.md` covers the Copilot + LSP integration pattern_
