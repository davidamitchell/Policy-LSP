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

**Short answer: Yes — when the binary is present. The LSP server lifecycle constraint
is overcomeable; the only hard blocker is a missing binary.**

### 3.1 Correcting a Prior Misconception

An initial version of this document claimed "Claude via the iOS app has no runtime
enforcement." That was wrong. The UI (iOS, web, desktop) is irrelevant. The agent runs
in a server-side sandboxed compute environment that has a filesystem, shell execution,
and the ability to start and communicate with processes — exactly as evidenced by the
fact that git commands, file writes, and Bash tool calls all work in this session.
The UI is a display surface; the agent environment is where enforcement happens.

### 3.2 The Three Enforcement Paths

| Path | Mechanism | What triggers it | Binary required |
|---|---|---|---|
| **LSP server** | Full LSP protocol: `didOpen` → `publishDiagnostics` | Something manages the lifecycle (IDE or agent) | Yes |
| **PostToolUse hook** | `policy-gate.sh` calls `gov-lsp check` | Every Write/Edit/MultiEdit in Claude Code | Yes (fails-open if absent) |
| **MCP tool** | `gov_check_file` / `gov_check_workspace` | Agent explicitly calls the tool | Yes (auto-builds via `mcp-start.sh`) |

All three paths converge on the same `engine.Evaluate()` function. They differ only
in the transport layer.

### 3.3 "The LSP Server Needs an IDE" — and Why That Is Overcomeable

The LSP server process does not need an IDE. It needs _something_ that speaks LSP
protocol to it. An IDE is one such client. The agent environment is another. The
`cmd/gov-lsp/e2e_test.go` harness is a 200-line proof that a plain Go program can
manage the full LSP lifecycle: spawn process → initialize → didOpen/didChange →
receive publishDiagnostics → shutdown/exit. The agent's Bash tool can do the same:

```bash
# Start server in background, get its PID
./gov-lsp --policies ./policies &
# Send initialize over its stdin, read capabilities from stdout
# After each file write: send textDocument/didChange, read publishDiagnostics
# Act on violations before continuing
```

More practically, `lsp.json` registration already wires this for Claude Code sessions:
Claude Code sends `textDocument/didOpen` and `textDocument/didChange` on every file
event, receives `publishDiagnostics` inline, and the agent sees violations without any
explicit tool call. This is the path that most closely mimics IDE behaviour — and it
is already configured.

For Copilot in GitHub Actions (no IDE, no hooks), the MCP tool or the check CLI is
the right path. Both are instant and do not require a persistent server.

### 3.4 The Actual Blocker: Binary Availability

The constraint is not protocol complexity. It is binary availability. Every enforcement
path requires the `gov-lsp` binary to be built. When it is absent:

- `policy-gate.sh` fails-open (`exit 0`, silent)
- `lsp-start.sh` attempts `go build` inline, which fails without network
- `mcp-start.sh` same
- `gov-lsp check` simply is not found

In the current sandbox, `go build` fails because OPA cannot be downloaded (no outbound
network). The binary is absent. The entire enforcement layer is silently inactive.

**The fix is a SessionStart hook** that pre-builds the binary when the environment is
set up, before any agent writes occur. `scripts/lsp-start.sh` already has the build
logic; it just needs to be called at session start rather than on first use.

### 3.5 The Hook Is Untested

The test suite has zero coverage of `policy-gate.sh`. The hook's critical paths:

- Binary not found → fails-open (`exit 0`) — untested
- `jq` unavailable → Python fallback — untested
- File path extraction failure → silent exit 0 — untested
- Binary exits 1 with output → agent sees violation message — untested

A bash-based bats or shunit2 test suite for the hook script would close this gap.

### 3.6 Enforcement By Agent Type

| Agent / context | PostToolUse hook | LSP via `lsp.json` | MCP tool | Net result |
|---|---|---|---|---|
| Claude Code (any UI, binary present) | ✅ instant | ✅ automatic | ✅ on demand | Full enforcement |
| Claude Code (binary absent) | ❌ silent | ❌ build fails | ❌ build fails | No enforcement |
| Copilot in VS Code | ❌ no hook | ✅ VS Code manages | ✅ via `.github/mcp.json` | Full enforcement |
| Copilot in GitHub Actions | ❌ no hook | ❌ no IDE | ✅ if configured | MCP or check CLI only |

---

## 4. Can We Configure Autonomous Agents to Mimic IDE-LSP Interaction?

_The right question is not "can we mimic what an IDE does" but "can we control the
agent's environment so that policy enforcement is always present before code is
written." The answer is yes, and the mechanism already exists for both agents._

### 4.1 Environment Control Is the Key

Every autonomous agent session runs inside a controllable environment:

| Agent | Environment control mechanism | What it can install |
|---|---|---|
| GitHub Copilot | `copilot-setup-steps.yml` workflow | Any binary on PATH, env vars, config files |
| Claude Code | `SessionStart` hook (`.claude/settings.json`) | Binary builds, background processes, env vars |
| Claude Code (web/iOS UI) | Same — the UI is a display surface; the agent runs server-side with full tool access | Same as above |

This is the correct framing: the UI the user uses to talk to the agent (iOS, web,
desktop) is irrelevant to what the agent can do. What matters is the environment the
agent runs in and whether that environment has been provisioned with the binary.

Controlling the environment means:
1. Binary is pre-built and on PATH before the first file write
2. LSP server is registered and can start instantly when first file is opened
3. PostToolUse hook is active and calls `gov-lsp check` after every write
4. MCP tool is ready for on-demand structured queries

When all four are true, the agent has instant policy feedback from the first
keystroke — equivalent to what an IDE user has.

### 4.2 What an IDE Does (and What the Agent Already Does)

```
IDE startup                          Agent session startup (lsp.json active)
  → spawn LSP server (lsp-start.sh)   → Claude Code spawns LSP server (lsp-start.sh)
  → initialize handshake               → initialize handshake

File opened in editor                Agent opens/reads a file (Read tool)
  → textDocument/didOpen               → textDocument/didOpen (automatic via lsp.json)
  ← publishDiagnostics                 ← publishDiagnostics (agent sees violations)

File saved in editor                 Agent writes a file (Write/Edit tool)
  → textDocument/didChange             → textDocument/didChange (lsp.json)
  ← publishDiagnostics                 ← publishDiagnostics
  [hook also runs gov-lsp check]       [PostToolUse hook also runs gov-lsp check]
```

The two columns are already identical in design. The only difference in practice is
that `lsp-start.sh` needs a pre-built binary.

### 4.3 Copilot: `copilot-setup-steps.yml` Already Does This

`copilot-setup-steps.yml` builds `gov-lsp` and puts it on PATH before the Copilot
session starts. The binary is present. Copilot in VS Code then:
- Manages the LSP server lifecycle via the `lsp.json` equivalent
- Sees diagnostics in the Problems panel
- Can be instructed to check for violations before completing any task

For Copilot in GitHub Actions (no VS Code), the binary is on PATH, so:
```bash
gov-lsp check --format text <file>   # instant, runs after each write
```
can be embedded in the copilot-instructions or called via MCP.

### 4.4 Claude Code: The Missing Piece Is a SessionStart Hook

Claude Code has `PostToolUse` hooks (already configured). It also supports
`SessionStart` hooks — commands that run once when the session initialises, before
any agent turns. This is where the binary should be built:

```json
// .claude/settings.json — SessionStart addition
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash scripts/lsp-start.sh --policies ./policies"
          }
        ]
      }
    ],
    "PostToolUse": [ ... existing hook ... ]
  }
}
```

With this:
1. Session starts → binary built (if absent) → LSP server starts
2. Agent reads or writes any file → `lsp.json` client sends events → diagnostics arrive
3. Agent writes a file → `policy-gate.sh` also runs `check` as a double-check
4. Agent never reaches a state where enforcement is silently absent

This is backlog item B-12: implement the SessionStart hook.

### 4.5 The Engine as Universal Source

```
┌─────────────────────────────────────────────────────────────┐
│                     CONSUMERS                               │
│                                                             │
│  IDE (VS Code, Neovim, Zed)    Agent (Claude, Copilot)     │
│         │                              │                    │
│   LSP protocol              MCP tool / check CLI / hook     │
└──────────────────────┬──────────────────────────────────────┘
                       │
                 engine.Evaluate()
                 (OPA + Rego policies)
                       │
             violations + fix data
```

`diagnostic.data` containing `{"type":"rename","value":"LOWER_CASE.md"}` is
consumable by all four paths: LSP `WorkspaceEdit`, MCP JSON response, `check`
text/json output, hook exit-1 message. The engine is the universal source; the
transport is selected by what the consumer natively speaks. This is exactly the right
design for a multi-consumer governance tool.

### 4.6 LSP as the Stable Interface for Many Consumers

The user's framing is correct: the LSP interface IS the stable interface worth
investing in. Reasons:

1. **IDE users** get it for free (VS Code, Neovim, Zed, any editor with LSP support)
2. **Claude Code** gets it via `lsp.json` — same events, same protocol, no extra code
3. **Copilot in VS Code** gets it the same way
4. **Any future agent** that understands LSP gets it without changes to gov-lsp
5. The check CLI and MCP are thin wrappers over the same engine — adding a new
   transport (e.g., HTTP endpoint, gRPC) would not require changing the policies

Writing more code to make the LSP consumers work correctly (tests, SessionStart hook,
URI decoding fix) is the right investment because each fix benefits all consumers
simultaneously. The policy engine and LSP server are the stable core; the
agent-specific wiring (hooks, MCP config) is thin glue.

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
| B-10 | Architecture | Update docs to clarify: LSP server, check CLI, and MCP are all consumer interfaces to the same engine — not an IDE-only tool | Medium |
| B-11 | CI | Add a CI job that runs `make build` + `make check-policy` to verify the binary is always buildable and self-governance passes | High |
| B-12 | SessionStart hook | ~~Add `SessionStart` entry to `.claude/settings.json`~~ **Done** — `.claude/hooks/session-start.sh` + `SessionStart` registration implemented in this session | **Done** |
| B-13 | Copilot env | Verify `copilot-setup-steps.yml` puts binary on PATH before Copilot session starts, and that `gov-lsp check` works without explicit path prefix | High |
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
