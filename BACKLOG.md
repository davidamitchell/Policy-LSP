# Backlog

> This file tracks **repo improvement** work — server features, tooling, and policy additions.
> Use the `backlog-manager` skill when adding, refining, or reviewing items.

---

## W-0001

status: done
created: 2026-02-28
updated: 2026-02-28

### Outcome

The repository compiles (`go build ./...`), all unit tests pass (`go test ./...`), and the smoke test (`scripts/smoke_test.sh`) passes end-to-end against a real built binary.

### Context

Foundation: Go module, OPA engine, LSP handlers, stdio loop, policies directory, Dockerfile.

---

## W-0002

status: done
created: 2026-02-28
updated: 2026-02-28

### Outcome

`AGENTS.md`, `BACKLOG.md`, `PROGRESS.md`, `.github/copilot-instructions.md`, `.github/mcp.json`, `.mcp.json`, `.gitmodules`, `.github/workflows/ci.yml`, and `docs/adr/` exist with content covering agent instructions, backlog, CI, skills, MCP config, and an initial ADR.

### Context

Agent-first scaffold — mirrors the structure of `davidamitchell/Research` but with Go/OPA/LSP-specific content.

---

## W-0003

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

`textDocument/codeAction` is handled by the server: when a client sends a `codeAction` request for a URI with a `markdown-naming-violation` diagnostic, the server returns a `WorkspaceEdit` that renames the file to the SCREAMING_SNAKE_CASE value from the diagnostic's `data.value` field. A unit test in `internal/lsp/` verifies the returned edit.

### Context

The fix data is already embedded in `Diagnostic.data` from W-0001. This slice wires up the LSP `codeAction` round-trip so editors can offer a one-click fix.

---

## W-0004

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

The server watches `*.rego` files in the policy directory via `workspace/didChangeWatchedFiles` and reloads the OPA engine (re-parses and re-prepares the query) within 500ms of a policy file change, without restarting the process. A test verifies that a newly written policy file produces a violation on the next `didOpen` evaluation.

### Context

Policy hot-reload removes the need to restart the LSP server when iterating on rules during development.

---

## W-0005

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

The engine layer uses `testing/fstest.MapFS` in all unit tests instead of real filesystem paths. `engine.New()` is refactored to accept an `fs.FS` parameter (with a convenience `engine.NewFromDir(path string)` wrapper that calls `os.DirFS`). All existing tests pass with the new signature.

### Context

The current `policyDir(t)` helper in `rego_test.go` resolves `../../policies` at runtime, coupling tests to the physical directory layout. Using `fstest.MapFS` makes tests hermetic and eliminates the path dependency.

---

## W-0006

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

Structured logging using `log/slog` replaces `log.Printf` throughout the server. Log output goes to stderr only. The log level is configurable via `--log-level` flag (`debug`, `info`, `warn`, `error`; default `warn`). In tests, logging is silenced by default to avoid polluting test output.

### Context

`log.Printf` has no level concept and produces output on every request in the current implementation, which corrupts the stdio LSP stream if a client reads stderr. `slog` with a stderr handler at `warn` level by default means normal operation is silent.

---

## W-0007

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

A `governance.content` policy package exists in `policies/content.rego`. It defines at least one rule: any file with extension `.go` that does not begin with a Go copyright or package comment produces a `"missing-package-comment"` violation. Unit tests in `internal/engine/rego_test.go` cover the compliant and violating cases. The smoke test is updated to verify no false positive on a compliant Go file.

### Context

The current policies directory contains only filename rules. A content-aware policy demonstrates that the engine's `file_contents` injection is exercised end-to-end, and validates the multi-policy evaluation path.

---

## W-0008

status: done
created: 2026-02-28
updated: 2026-03-02

### Outcome

Integration tests in `internal/lsp/handlers_test.go` exercise the full LSP round-trip: a test constructs a `Handler`, calls `Handle()` with a real `initialize` request, a `didOpen` request for a violating file, and asserts that the `Publisher` was called exactly once with a `publishDiagnostics` notification containing the expected diagnostic. Tests use `testing/fstest.MapFS` for policies.

### Context

The LSP handler package currently has no tests. The handler is the integration point between the transport and the engine; testing it directly (without the stdio loop) gives fast feedback on protocol correctness.

---

## W-0009

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A TCP transport mode exists: running `gov-lsp --transport tcp --addr :7998` accepts a single LSP client connection over TCP and processes messages identically to the stdio mode. The transport is abstracted behind a `Transport` interface with `Read() ([]byte, error)` and `Write([]byte) error` methods. Stdio and TCP are both implementations.

### Context

The spec calls for "modular expansion to TCP". This slice implements the architecture and the TCP variant, enabling integration with clients that do not support stdio (e.g., some remote agent frameworks).

---

## W-0010

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

The binary is published as a GitHub Release artifact on every semver tag (`v*`). A `.github/workflows/release.yml` workflow builds `linux/amd64`, `linux/arm64`, `darwin/amd64`, and `darwin/arm64` static binaries, attaches them to the release, and pushes the multi-arch Docker image to `ghcr.io/davidamitchell/gov-lsp:<tag>`. The release workflow passes on a tag push with no errors.

### Context

Portability is a core design goal. Without published binaries, every user must `go install` from source, which requires a Go toolchain and network access. Published binaries and a container image make the server drop-in for any IDE or MCP config.

---

## W-0011

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`.devcontainer/devcontainer.json` exists with a Go 1.24 base image. `postCreateCommand` builds the `gov-lsp` binary immediately so the hook and MCP server are available without a manual build step. Node.js is included for MCP server startup. `GOV_LSP_POLICIES` is set in `remoteEnv`.

### Context

Lowering the local setup barrier means contributors (human or AI) can open the repo and begin working on policies or server code without a local Go installation.

---

## W-0012

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`gov-lsp mcp` subcommand implemented in `cmd/gov-lsp/mcp.go`. Implements MCP protocol version 2024-11-05 over newline-delimited JSON-RPC 2.0 stdio. Exposes `gov_check_file` and `gov_check_workspace` tools. Registered in `.mcp.json` via `scripts/mcp-start.sh` (auto-builds binary if absent). ADR 0006 documents the decision to use a subcommand rather than a separate binary.

### Context

GOV-LSP is an LSP server and MCP is a different protocol. Agents like Claude Code and GitHub Copilot Agent use MCP, not LSP, as their tool protocol. The `mcp` subcommand calls `engine.Evaluate()` directly — the wrapper is thin and adds no new dependencies.

---

## W-0013

status: backlog
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `check_policy` LSAP cognitive capability exists: any LSAP-aware agent can send a `{"mode":"check_policy","file_path":"<path>","file_contents":"<text>"}` request and receive a structured Markdown report listing all policy violations, their messages, and fix suggestions. The LSAP endpoint uses the same `engine.Evaluate()` call as the MCP tool (W-0012).

### Context

LSAP (Language Server Agent Protocol — `github.com/lsp-client/LSAP`, v1.0.0-alpha, MIT) is an orchestration layer that translates LSP's atomic editor operations into high-level "cognitive" interfaces for AI agents. Its Markdown-first response format is token-efficient and directly consumable by LLMs without JSON parsing.

GOV-LSP is a natural fit: its diagnostics are already semantically rich (natural language messages, typed fix suggestions). Wrapping them in LSAP's `check_policy` interface requires no changes to the engine or policy files.

See `research/lsap/README.md` for protocol analysis, comparison with MCP, and a `check_policy` request/response design.

### Notes

Blocked on LSAP protocol stability (currently v1.0.0-alpha, Python SDK only, no Go SDK). Implement after W-0012 is done and the LSAP spec reaches a stable release or a Go SDK is available. The engine call and policy schema will not need to change — this is purely a new transport adapter.

---

## W-0014

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A `gov-lsp-governance` agent skill exists and installs into Claude Code (`~/.claude/skills/`), Gemini (`~/.gemini/skills/`), Codex, and any `agentskills.io`-compatible agent tool. The skill exposes a single command: `check-governance <file_path>`. The agent invokes it on changed files; it calls `gov-lsp check <file>` and returns a Markdown policy report listing violations and fix suggestions. An agent with the skill installed can enforce governance rules without an editor, without an LSP client, and without MCP.

### Context

The `lsp-client/lsp-skill` project (see `research/lsap/README.md`, section "The `lsp-skill` Ecosystem") demonstrates the pattern: a SKILL.md instruction file + a CLI subcommand. The skill installs into the same `~/.claude/skills/` directory already used by the `davidamitchell/Skills` submodule in this repo.

GOV-LSP already produces the right output — violation messages, severity, and self-contained fix suggestions. The skill is a thin adapter: a SKILL.md that documents the command interface, plus the `gov-lsp check` subcommand (already implemented in W-0001) that accepts a file path and prints Markdown.

This is the most direct path to autonomous agent governance enforcement without an editor — simpler than a full LSAP implementation (W-0013) and complementary to MCP (W-0012).

### Notes

The `gov-lsp check <file>` CLI subcommand is already implemented (see ADR 0005). W-0014 now depends only on the SKILL.md authoring work. The skill itself is ~50 lines of Markdown plus the command registration. No Go SDK or protocol stabilisation required. Write an ADR before implementation to decide whether the skill ships in this repo or as a separate `gov-lsp-skill` release artifact.

---

## W-0015

status: ready
created: 2026-02-28
updated: 2026-02-28

### Outcome

A minimal VS Code extension (`vscode-gov-lsp`) is published to the VS Code Marketplace. It starts the `gov-lsp` binary as a Language Server using `vscode-languageclient`, configures it to evaluate the current workspace's policy directory, and displays GOV-LSP diagnostics inline in the editor. A `gov-lsp.policies` setting allows workspace-level policy directory override.

### Context

The server binary already implements a complete LSP server. The only missing piece is the client-side glue that VS Code needs to launch and connect to a stdio LSP binary. `vscode-languageclient` makes this ~50 lines of TypeScript. The `.vscode/settings.json` and `.vscode/extensions.json` files already document the target config shape.

### Notes

This is the most common editor for the target audience. Write the extension in TypeScript using the standard `vscode-languageclient` + `vscode-languageserver-protocol` packages. The extension is separate from the Go binary — it wraps it, similar to how `gopls` is wrapped by `golang.go`. The binary path should default to the system PATH (`gov-lsp`) with a workspace override.

---

## W-0016

status: done
created: 2026-02-28
updated: 2026-03-01

### Outcome

`.github/workflows/ci.yml` includes a `policy-check` step that runs `gov-lsp check --format text .` on every push and PR. Currently informational (`|| true`) because this repo intentionally has demo violations in `docs/`. A consumer repo removes `|| true` to make it a hard gate. `.github/workflows/copilot-setup-steps.yml` builds `gov-lsp` and places it on PATH for GitHub Copilot agent sessions.

### Context

The `gov-lsp check` subcommand returns exit code 1 on violations. The CI step closes the loop: governance violations are surfaced on every PR even when no IDE extension is installed.

---

## W-0017

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`textDocument/didChange` is tested at both unit and e2e level. Unit: the handler debounce fires and calls `Evaluate` after the timer elapses; a second change within the debounce window does not double-fire. E2e: the binary receives a `didChange` event after `didOpen` and emits a second `publishDiagnostics` notification with correct content. The debounce timer (`time.AfterFunc`) goroutine lifecycle is verified — no goroutine leak after shutdown.

### Context

`didChange` is the primary LSP event: editors emit it on every keystroke. PR #3 delivered zero tests for this method. The handler contains a 200 ms debounce using `time.AfterFunc` that captures the request context in a goroutine closure — the most likely source of race conditions. Identified in the PR #3 audit (issue `docs/issues/issue-pr3-audit-2026-03-02.md`, C-1).

---

## W-0018

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

All three inline Rego policy copies in the test suite are replaced with a shared reference to the real on-disk policies. Option A: call `engine.NewFromDir("../../policies")` directly in tests. Option B: add a golden-file test that reads `policies/filenames.rego` and asserts it matches a known hash/content, failing loudly if the file changes without updating tests. Either way, a policy change to `policies/filenames.rego` automatically causes a test failure instead of silently testing stale behaviour.

### Context

Three test files contain identical verbatim inline copies of the filenames Rego policy (`cmd/gov-lsp/check_test.go`, `internal/engine/rego_test.go`, `internal/lsp/handlers_test.go`). None are validated against the disk file. Identified in PR #3 audit (C-2).

---

## W-0019

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`internal/engine/rego_test.go` includes tests for `governance.security`: at least one test proves a hardcoded credential string produces a `hardcoded-credential` violation, and at least one proves a non-credential string does not. LSP e2e: a `didOpen` with a violating file content triggers `publishDiagnostics` containing the security diagnostic. The `check` subcommand test also exercises the security policy.

### Context

`security.rego` is the highest-stakes policy (credential leakage) and has zero test coverage at any level in PR #3. Identified in PR #3 audit (§2.3 significant gaps).

---

## W-0020

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`TestE2E_Shutdown` asserts that the process exits with code 0 after a well-formed `shutdown` + `exit` LSP sequence. If the server exits non-zero (panic, unhandled error) the test fails.

### Context

The current test accepts any exit code with the comment "any exit code is acceptable (SIGKILL from cleanup vs clean exit)". The LSP specification requires exit code 0 after a clean shutdown. A panicking server would pass the current test. Identified in PR #3 audit (C-3).

---

## W-0021

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`cmd/gov-lsp/e2e_test.go` includes a test that opens a `.go` file without a package comment via `textDocument/didOpen` and asserts that `publishDiagnostics` contains a `missing-package-comment` diagnostic. This proves the full pipeline — LSP → engine → content policy → diagnostic — works end-to-end, not just the filenames policy path.

### Context

PR #3 `rego_test.go` has unit tests for the content policy at the engine level but no LSP e2e test exercises the full pipeline with a content-policy violation. Identified in PR #3 audit (§2.3).

---

## W-0022

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`TestRunCheck_SelfGovernance_DetectsRepoViolations` asserts `count > 0` — that is, the self-governance run actually found violations in the repo's own `docs/` directory (which contains intentional lowercase filenames). The test currently logs the count but does not assert it, meaning the property "this repo self-governs" is not machine-verified.

### Context

The self-governance property is the repo's primary claim. If the check runs but finds no violations, the test passes silently — which would mean the policy is broken. Identified in PR #3 audit (§2.3).

---

## W-0023

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`filenameFromURI` calls `url.PathUnescape` before `filepath.Base`. A file URI containing percent-encoded characters (e.g., `file:///workspace/my%20file.md`) correctly extracts `my file.md` rather than `my%20file.md`. A unit test covers the encoded-path case.

### Context

The current implementation strips `file://` and calls `filepath.Base` directly. Percent-encoded paths produce filenames containing `%XX` sequences which confuse the Rego regex. A valid uppercase file in a path with a space would be falsely flagged. Identified in PR #3 audit (§2.4, latent protocol bug).

---

## W-0024

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`.claude/hooks/policy-gate.sh` has automated test coverage (bats or shunit2) covering: (1) binary not present → exits 0 silently (fail-open path); (2) `jq` absent → Python fallback extracts file path correctly; (3) violation present → exits 1 with violation message visible in output; (4) clean file → exits 0.

### Context

The PostToolUse hook is the enforcement path active on every Write/Edit/MultiEdit in Claude Code. It has zero test coverage. The fail-open path (binary absent → silent exit 0) is the most dangerous: it means enforcement is silently inactive without the agent knowing. Identified in PR #3 audit (§3.5).

---

## W-0025

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

A test verifies that running `gov-lsp --log-level debug` produces log output to stderr and `gov-lsp --log-level error` suppresses info/debug messages. The `--log-level` flag is exercised and its effect on output is asserted.

### Context

W-0006 added `--log-level` and the flag is wired, but PR #3 never asserts its effect. The feature is "claimed delivered" but unverified. Identified in PR #3 audit (§2.3).

---

## W-0026

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`docs/` (or `AGENTS.md`) is updated to clearly document that the LSP server, `check` CLI, and MCP tool are all transport interfaces to the same `engine.Evaluate()` call — not IDE-only tools. Includes an architecture diagram showing the three transport paths converging on the engine.

### Context

The current documentation implies the LSP server requires an IDE. In practice, the agent environment can manage the LSP lifecycle directly (as the e2e test harness demonstrates), and the check CLI and MCP tool are equally valid for non-IDE consumers. Identified in PR #3 audit (B-10).

---

## W-0027

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`.github/workflows/ci.yml` includes a job that: (1) runs `make build` to verify the binary always compiles, and (2) runs `make check-policy` (or `./gov-lsp check --format text .`) and verifies that the violations found are exactly the expected intentional ones in `docs/`. An unexpected violation (or zero violations when some are expected) fails the job.

### Context

Currently CI runs tests but does not verify that the binary builds cleanly from a cold checkout or that self-governance finds exactly the expected violations. Identified in PR #3 audit (B-11).

---

## W-0028

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`copilot-setup-steps.yml` is verified to: (1) put the `gov-lsp` binary on PATH without an explicit path prefix, (2) allow `gov-lsp check <file>` to work from any working directory, and (3) pre-build the binary before the Copilot agent session starts. A smoke test in the workflow confirms the binary is reachable.

### Context

The workflow exists but its end-to-end correctness (binary on PATH, no prefix needed, works before any Copilot turns) has not been verified. Identified in PR #3 audit (B-13).

---

## W-0029

status: ready
created: 2026-03-02
updated: 2026-03-02

### Outcome

`go mod download` succeeds in the Claude Code web sandbox without vendoring. Before running `go mod download`, `NO_PROXY` is overridden to remove `*.googleapis.com` and `*.google.com` so Go routes `storage.googleapis.com` and `proxy.golang.org` through the Anthropic egress proxy (which allows both). For MCP GitHub tools: `global-agent` is installed and `NODE_OPTIONS=--require global-agent/bootstrap` is set in `scripts/mcp-start.sh` so the Node.js MCP server respects `GLOBAL_AGENT_HTTPS_PROXY` and can reach `api.github.com`.

### Context

Two distinct network failure modes affect the Claude Code web sandbox. (1) `go mod download` fails because `NO_PROXY=...*.googleapis.com...` causes Go to bypass the egress proxy and attempt direct DNS at `[::1]:53`, which fails (`CLAUDE_CODE_PROXY_RESOLVES_HOSTS=true`). The proxy WOULD work — `storage.googleapis.com` is in the JWT allowlist — but `NO_PROXY` prevents it from being tried. (2) MCP GitHub tools return `-32603: fetch failed` because Node.js `https.request` does not natively respect `HTTPS_PROXY`. The `global-agent` npm package fixes this by monkey-patching Node's http/https modules. Full diagnosis in `docs/issues/issue-pr3-audit-2026-03-02.md` §6.

### Notes

Fix for (1): `export NO_PROXY=$(echo "${NO_PROXY:-}" | sed 's/,\*\.googleapis\.com//g; s/,\*\.google\.com//g'); export no_proxy="$NO_PROXY"` before `go mod download`. Fix for (2): `npm install -g global-agent` in `copilot-setup-steps.yml` or as a devcontainer step; then set `NODE_OPTIONS=--require global-agent/bootstrap` in `scripts/mcp-start.sh`. The vendoring approach (W-0014 dependency: `make vendor`) sidesteps (1) entirely and is the preferred day-to-day path.

---

## W-0030

status: done
created: 2026-03-02
updated: 2026-03-02

### Outcome

`.claude/hooks/session-start.sh` pre-builds the `gov-lsp` binary at session start before any agent writes occur. Registered as a `SessionStart` hook in `.claude/settings.json`. Vendor-aware: uses `-mod=vendor` when `vendor/` is present, falls back to `go mod download` (with `NO_PROXY` fix) otherwise. Idempotent: skips build if binary already exists.

### Context

Without the SessionStart hook, all three enforcement paths (PostToolUse hook, LSP server, MCP tool) are silently inactive when the binary is absent. `lsp-start.sh` and `mcp-start.sh` attempt inline builds but fail without network or vendor/. The SessionStart hook fires before any agent turn, ensuring enforcement is always active. Implemented in this session (2026-03-02).

---

## W-0031

status: done
created: 2026-03-05
updated: 2026-03-05

### Outcome

`TestRunCheck_SelfGovernance_DetectsRepoViolations` replaced by `TestRunCheck_FilenamePolicy_DetectsViolations` in `cmd/gov-lsp/check_test.go` (commit `98c08a9`). The new test writes 3 known-violating files (`getting-started.md`, `policies.md`, `integrations.md`) and 2 compliant files (`README.md`, `CHANGELOG.md`) to `t.TempDir()`, then asserts `count == 3` with `t.Errorf`. The test fails immediately if the engine returns any count other than 3. No real filesystem access, no `t.Skipf`, no `t.Logf` swallowing failures.

### Context

The old test had three defects identified in PR review (2026-03-05):
1. **Not falsifiable** — the test comment explicitly said "If someone has renamed the files to be compliant, that is also correct", so `count == 0` passed. A test with no failure condition proves nothing (see AGENTS.md: "A Rego rule that cannot produce a falsifiable result has no value").
2. **Real-FS coupling** — `filepath.Abs("../../")` tied the test to physical repo layout; it silently skipped if `docs/` moved.
3. **Hidden output** — violations logged via `t.Logf` were swallowed without `-v`; the only live assertion (`strings.Contains(buf, "Checked")`) passed even when the engine returned 0 results.

---

## W-0032

status: ready
created: 2026-03-05
updated: 2026-03-05

### Outcome

The headless-agent enforcement loop is proved to work end-to-end. Specifically:

1. The copilot CLI receives `textDocument/publishDiagnostics` events from gov-lsp when it creates or edits a `.md` file.
2. The agent reacts to those diagnostics and self-corrects (renames or deletes the violating file) before completing its task.
3. `scripts/test_headless_agent.sh` captures evidence of (1) and asserts (2). If evidence of (1) is absent, the test exits 1 with "INCONCLUSIVE — LSP loop not confirmed". It must never exit 0 when the loop is not demonstrably active.
4. `.github/workflows/ci.yml` has no `continue-on-error` on the headless agent step — a test failure is a CI failure, full stop.

**Non-negotiable constraint:** a test that passes when the LSP loop is not demonstrably active is worse than no test. If diagnostic evidence cannot be captured for a given `copilot` CLI version, the test must fail loudly, not silently pass.

### Context

CI run 2026-03-05 confirmed the enforcement loop is broken: the copilot CLI created `my-notes.md` (the policy-violating file) and the LSP diagnostics did not prevent it. The test script correctly exited 1 with "Framework BROKEN", but `continue-on-error: true` in `.github/workflows/ci.yml` swallowed that failure and let the CI job succeed — producing a fake green build. That `continue-on-error` has now been removed (commit in this session).

The underlying architectural cause is still unknown: either the copilot CLI does not connect to gov-lsp via `lspServers`, does not block on `publishDiagnostics` events before completing file writes, or the diagnostic arrives after the file is already persisted. Diagnosing this requires the agent debug logs from the failed CI run.

---

## W-0033

status: ready
created: 2026-03-05
updated: 2026-03-05

### Outcome

Documentation across `README.md`, `docs/`, and `AGENTS.md` is reorganised to clearly present the two supported personas and their respective enforcement paths:

1. **Headless agent governance** — a coding agent (e.g. Copilot CLI, Claude Code) operating without an IDE receives real-time LSP diagnostics through the `lspServers` config in `.github/lsp.json` / `.claude/lsp.json`. Violations arrive as `publishDiagnostics` events on every file open/change, identical to IDE squiggles. The agent self-corrects before completing its task.

2. **IDE-integrated policy enforcement** — a human developer using VS Code, Neovim, or any LSP-capable editor gets inline diagnostics and one-click `codeAction` fixes from gov-lsp registered as a language server.

Current docs conflate the two or omit the IDE persona entirely. The ADR index (`docs/adr/README.md`) and `docs/integrations.md` are updated to cover both paths. `AGENTS.md` testing section is updated to distinguish unit tests (hermetic, `fstest.MapFS`), smoke tests (binary + real policies), and headless-agent integration tests (live `copilot` CLI, real auth required).

---

## W-0034

status: ready
created: 2026-03-05
updated: 2026-03-05

### Outcome

The Copilot CLI (`--autopilot --allow-all`) sends `textDocument/didOpen` (or equivalent) events to gov-lsp when the agent creates or modifies a `.md` file. The enforcement loop works end-to-end: agent creates file → gov-lsp receives event → gov-lsp publishes diagnostics → agent self-corrects.

### Context

CI run 2026-03-05 confirmed the loop is broken: the agent created `my-notes.md` without gov-lsp ever publishing diagnostics. The root cause is unknown. Three hypotheses, in priority order:

1. **No connection** — the Copilot CLI in `--autopilot` mode does not connect to LSP servers declared in `.github/lsp.json`. The `lspServers` feature may be interactive-only (requires `/lsp` command, not triggered in autopilot). Evidence: if CI agent debug logs contain no `gov-lsp initialize` line after adding debug logging (W-0034 prerequisite committed), the CLI never started gov-lsp.

2. **Connection established but no file-event** — the CLI connects and completes the LSP handshake, but the agent's internal "create file" tool does not send `textDocument/didOpen` or `textDocument/didChange`. LSP diagnostics are advisory-push; the server only evaluates when the client notifies it. Evidence: `gov-lsp initialize` appears in logs but no `gov-lsp didOpen`.

3. **Event arrives after file is persisted** — the CLI sends `didOpen` *after* writing the file to disk, so the diagnostic arrives too late for the agent to self-correct within the same tool call. Standard LSP is not transactional; there is no mechanism to block a file write pending a diagnostic response.

### Investigation Steps

1. Read the agent debug logs artifact from the next CI run (gov-lsp now emits `slog.Debug` at `initialize`, `didOpen`, `didChange`, `publishDiagnostics`; lsp-template.json now passes `--log-level debug`). The logs will confirm which hypothesis is correct.

2. If hypothesis 1 (no connection): file an issue against `github/copilot-cli` for `lspServers` not being activated in `--autopilot` mode. As a workaround, explore whether a `workspace/didCreateFiles` notification can be sent by the test harness (not the agent — the harness pre-creates the file and notifies gov-lsp, then asserts the agent's next action is compliant). This is not true enforcement but documents the limitation.

3. If hypothesis 2 (no file-event): add `workspace/didCreateFiles` handler to gov-lsp (LSP 3.16, params: `{ files: [{ uri }] }`). If the CLI sends this notification for agent-created files, gov-lsp can evaluate and publish diagnostics. Alternatively, add a filesystem watcher (fsnotify) so gov-lsp detects new files without waiting for LSP events — this is a server-side workaround that doesn't require CLI changes.

4. If hypothesis 3 (timing): explore whether the Copilot CLI agent loop re-evaluates after receiving `publishDiagnostics`, or whether it is a single-pass tool call. If re-evaluation is possible, the test needs a second agent turn (e.g., "now verify no violations exist"). Document this as an architectural constraint in `AGENTS.md`.

### Non-negotiable constraint

The fix must not involve the test script calling `gov-lsp check` directly. That bypasses the LSP loop entirely and proves nothing about the framework. The enforcement must happen inside the agent's session via the native LSP protocol.


