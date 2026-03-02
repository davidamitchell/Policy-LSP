# PR #3 Test Audit — gov-lsp Handler Tests & E2E Tests

**PR**: davidamitchell/Policy-LSP#3
**Auditor**: Claude (claude-sonnet-4-6)
**Date**: 2026-03-02
**Claim under review**: "These tests prove the protocol works"

---

## Repo Purpose (Context)

`gov-lsp` is a self-governing LSP server that enforces Rego policies on files and
reports violations as LSP diagnostics. It ships three layers of policy enforcement:
real-time LSP server, PostToolUse hook, and MCP tool. The repo uses itself — violations
in `docs/` are intentional demonstrations. The core claim of PR #3 is that 8 handler
unit tests + 6 binary e2e tests prove the system works end-to-end.

**Verdict: Overstated.** The tests cover the primary happy paths well, but several
critical paths are entirely untested, three tests have weak or missing assertions, and
the test isolation strategy contains a silent divergence risk between inline policy
copies and the real shipped policies.

---

## Critical Issues

### 1. `textDocument/didChange` is completely untested

Neither the 8 handler unit tests nor the 6 e2e tests exercise
`textDocument/didChange`. This is a primary LSP method — editors emit it on every
keystroke. The implementation has a 200 ms debounce timer via `time.AfterFunc`, which
captures the request `ctx` in a goroutine closure. In the current server loop
`context.Background()` is used (never cancelled), so evaluations do eventually run.
But the debounce interaction is entirely unverified:

- No test confirms that a change event eventually produces a `publishDiagnostics`
  notification.
- No test confirms that rapid changes collapse into a single evaluation (the whole
  point of debouncing).
- No test catches the goroutine capturing a stale context if the architecture changes.

**Risk**: The feature exists in the implementation but is not tested at all.

### 2. Three disconnected copies of the Rego policy source

The same Rego logic appears in three separate inline strings across the test suite:

| File | Constant |
|------|----------|
| `cmd/gov-lsp/check_test.go` | (anonymous inline) |
| `internal/engine/rego_test.go` | `filenamesPolicy` |
| `internal/lsp/handlers_test.go` | `filenamePolicy` |

None of these are verified against the actual `policies/filenames.rego` on disk.
If the real policy changes (updated regex, new fix format, renamed field), all three
copies silently test the old behaviour. The handler and check tests would stay green
while the shipped binary would behave differently from what the tests prove.

**This is the single largest gap.** The test suite does not validate the _actual
policies the binary ships with_.

### 3. `TestE2E_Shutdown` does not assert the LSP exit code

```go
case <-done:
    // exited, any exit code is acceptable (SIGKILL from cleanup vs clean exit)
```

The LSP spec requires exit code 0 after a well-formed `shutdown` + `exit` sequence.
The test accepts any exit code, meaning it would pass if the server panicked or exited
with code 1. The comment conflates cleanup SIGKILL (which could happen _after_ the
done channel fires) with the process's own exit code. These are separate events and
the distinction matters for spec conformance.

### 4. `TestE2E_DidOpen_ViolatingFile` assumes position 0

```go
diag, ok := diags[0].(map[string]interface{})
```

The test asserts on `diags[0]` without searching for the diagnostic by `code`. When
the full real policies directory is used (including `content.rego` and `security.rego`),
only the filenames policy fires for `.md` files today. But if a future policy were
added that fires first, the test would check the wrong diagnostic and either pass
incorrectly or give a misleading failure.

---

## Significant Missing Coverage

### 5. `security.rego` has zero test coverage in this PR

The `governance.security` package — which detects hardcoded credentials — has no tests
in `internal/engine/rego_test.go`. There is no test for:

- A file containing a credential pattern that should be caught.
- A `_test.go` file with a credential-shaped string that should be excluded.
- A `go.sum` file that should be excluded.
- A file with a short string (< 20 chars) that should not trigger a false positive.

The security policy is the highest-stakes policy in the repo and is completely
untested.

### 6. W-0006 (`--log-level` flag) has no assertions

The PR description lists structured logging via `log/slog` as a deliverable (W-0006).
The e2e tests use `--log-level error` but only to suppress output — no test verifies:

- That debug/info messages appear at the correct level.
- That an invalid log level falls back gracefully (it does: defaults to `warn`, but
  this is untested).
- That the `--log-level` flag is wired to the actual slog handler level.

### 7. Content policy has no LSP e2e test

`policies/content.rego` (`missing-package-comment`) is tested at the engine and
`check` subcommand levels, but no e2e test opens a Go file via `textDocument/didOpen`
and verifies the resulting `publishDiagnostics` notification. The full pipeline
(LSP framing → handler → engine → content policy → diagnostic) is not validated.

Relatedly, `handleCodeAction` silently skips diagnostics with `nil` Data (which
`missing-package-comment` produces since it has no fix). This is correct behaviour
but is not covered by any test.

### 8. `TestHandle_Notification_ReturnsNil` does not test the generic notification path

The test sends `initialized`, which has its own named `case` in the switch:

```go
case "initialized":
    return nil // notification, no response needed
```

The test passes, but it does not exercise the `default` branch's notification
handling logic (`if req.ID != nil`). A new unknown notification method sent without
an ID would also return nil via the `default` case — and that path is never tested.

### 9. `TestRunCheck_SelfGovernance_DetectsRepoViolations` never asserts violations exist

```go
t.Logf("self-governance check: %d violation(s) in docs/\n%s", count, buf.String())
if !strings.Contains(buf.String(), "Checked") {
    t.Error("expected summary line in output")
}
```

The test only checks that the output contains the word `"Checked"`. It never asserts
`count > 0`. The CLAUDE.md explicitly states that violations in `docs/` are
intentional — this test is meant to prove the policy is detecting real violations in
the repo — but the test passes even if zero violations are found. The self-governance
property is not actually asserted.

### 10. `check_test.go` uses only the filenames policy

`policyEngine` in `check_test.go` loads only `filenames.rego`. This means
`TestRunCheck_NonMarkdownFile_NoViolation` creates `main.go` with content
`"package main"` (no package comment) and expects zero violations — which is only
true because `content.rego` isn't loaded. The test would fail if ever updated to
use the full policy set, silently misleading about real-world behaviour.

---

## Protocol Correctness Concerns

### 11. `filenameFromURI` does not decode percent-encoding

```go
func filenameFromURI(uri string) string {
    path := strings.TrimPrefix(uri, "file://")
    return filepath.Base(path)
}
```

File URIs are percent-encoded. `/workspace/my file.md` is transmitted as
`file:///workspace/my%20file.md`. After stripping `file://` and taking `filepath.Base`,
the filename becomes `my%20file.md` — which the Rego filenames policy evaluates against
its `^[A-Z0-9_]+$` regex. The `%` character is not in that set, so `MY%20FILE.md`
would fail the compliant check. This is a latent bug affecting any workspace path with
spaces or non-ASCII characters, and it is untested.

---

## What the Tests Do Well

- The e2e framework (Content-Length framing, JSON-RPC session management, `recvUntil`
  predicate filtering) is solid and would catch real regressions in the protocol layer.
- `TestE2E_CodeAction_RenameRoundTrip` correctly uses the _server-emitted_ diagnostic
  to drive the codeAction request — a genuine round-trip, not a hardcoded input.
- `fstest.MapFS` isolation in unit tests is the right approach.
- The handler tests cover initialize, didOpen (both compliant and violating), codeAction
  with and without diagnostics, unknown methods, and URI-without-directory edge cases.
- The `check` subcommand tests cover text format, JSON format, multi-file walks, hidden
  directory skipping, and dash-to-underscore fix suggestions.

---

## Summary Table

| Area | Covered | Notable Gaps |
|------|---------|-------------|
| `initialize` handshake | Yes (unit + e2e) | — |
| `textDocument/didOpen` | Yes (unit + e2e) | — |
| `textDocument/didChange` | **No** | Debounce logic entirely untested |
| `textDocument/codeAction` | Yes (unit + e2e) | Content-policy no-fix path untested |
| `shutdown` / `exit` | Yes (e2e) | Exit code not asserted |
| Filenames policy | Yes (engine + e2e) | Inline copies diverge from real policies |
| Content policy | Partial (engine only) | No LSP e2e test |
| Security policy | **No** | Zero coverage at any level |
| `--log-level` flag | No | Flag wired but untested |
| Self-governance | Partial | Violation count never asserted |
| URI percent-encoding | **No** | Latent bug, untested |

---

## Troubleshooting Note — MCP GitHub Tool Fetch Failure

During this audit the `mcp__github__get_pull_request` and
`mcp__github__get_pull_request_files` MCP tool calls failed with:

```
MCP error -32603: fetch failed
```

This occurred before any fallback strategy was attempted. Likely causes:

1. **Network routing**: The MCP GitHub server may be resolving
   `api.github.com` and getting blocked or timing out in this sandbox
   environment. The local Gitea mirror (accessible via `127.0.0.1:21766`)
   is available to `git` commands but the MCP server uses its own HTTP
   client and may not be configured to hit the mirror.

2. **Token scope**: The MCP GitHub token may not have read access to this
   repository if it is private.

3. **MCP server state**: The server may have encountered an initialisation
   error and is returning -32603 for all calls.

**Mitigation used**: Fell back to `WebFetch` (fetched the PR page directly
from GitHub) and `git fetch origin <branch>` to get the actual PR diff.
Both succeeded and provided equivalent data.

**Recommendation**: Add a health-check MCP call at session start
(e.g., `get_pull_request` on a known-good public repo) and surface the
error to the user immediately if it fails, rather than discovering it mid-task.
