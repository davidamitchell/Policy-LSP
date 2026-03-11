# Backlog

> This file tracks **repo improvement** work — server features, tooling, and policy additions.
> Use the `backlog-manager` skill when adding, refining, or reviewing items.
>
> Status values: `done` | `ready` | `needing_refinement` | `backlog` | `wont-do`

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

status: wont-do
created: 2026-02-28
updated: 2026-03-11

### Outcome

A TCP transport mode exists: running `gov-lsp --transport tcp --addr :7998` accepts a single LSP client connection over TCP and processes messages identically to the stdio mode. The transport is abstracted behind a `Transport` interface with `Read() ([]byte, error)` and `Write([]byte) error` methods. Stdio and TCP are both implementations.

### Context

The spec calls for "modular expansion to TCP". This slice implements the architecture and the TCP variant, enabling integration with clients that do not support stdio (e.g., some remote agent frameworks).

### Notes

Evaluated 2026-03-11: none of the integration surfaces in this repo require TCP:

- **Claude Code** runs via hooks (shell invocation, no transport).
- **GitHub Copilot Agent** connects via stdio (`lspServers` in `.github/lsp.json`) in interactive mode only — confirmed NOT started in `--autopilot` mode (see "Confirmed Behaviors" in `.github/copilot-instructions.md`).
- **Governance loop wrapper** (`scripts/governance_loop/governance_loop.sh`) uses `gov-lsp check --format json` (batch subprocess, not a persistent connection) or the LSP simulation in `lsp_check.py` (stdio).
- **MCP server** runs over stdio.

No planned consumer — not even a remote-agent framework currently in scope — requires TCP. Implementing TCP would add protocol-level complexity (connection lifecycle, port management, security) with no concrete consumer. If a future integration surface requires TCP, the `Transport` interface can be introduced at that time alongside the implementation.

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
updated: 2026-03-11

### Outcome

`gov-lsp mcp` subcommand implemented in `cmd/gov-lsp/mcp.go`. Implements MCP protocol version 2024-11-05 over newline-delimited JSON-RPC 2.0 stdio. Exposes `gov_check_file` and `gov_check_workspace` tools. Registered in `.mcp.json` via `scripts/mcp-start.sh` (auto-builds binary if absent). ADR 0006 documents the decision to use a subcommand rather than a separate binary.

### Context

GOV-LSP is an LSP server and MCP is a different protocol. Agents like Claude Code and GitHub Copilot Agent use MCP, not LSP, as their tool protocol. The `mcp` subcommand calls `engine.Evaluate()` directly — the wrapper is thin and adds no new dependencies.

### Notes

Updated 2026-03-11: the governance loop wrapper (`scripts/governance_loop/governance_loop.sh`, W-0032) closes the feedback loop this tool was designed to enable. The wrapper uses `gov-lsp check --format json` (batch mode) or LSP simulation (`lsp_check.py`) for real-time diagnostics, then injects violations as structured JSON into the agent's correction prompt. The MCP tools (`gov_check_file`, `gov_check_workspace`) remain the preferred path when the agent drives the loop itself (e.g. Claude Code or Copilot CLI in `--autopilot` mode with `--additional-mcp-config`). Remaining gap: explicit test coverage for the governance loop wrapper's fail-closed path (binary absent), violation surfacing, and clean-workspace silence (tracked as W-0036).

---

## W-0013

status: backlog
created: 2026-02-28
updated: 2026-03-11

### Outcome

A `check_policy` LSAP cognitive capability exists: any LSAP-aware agent can send a `{"mode":"check_policy","file_path":"<path>","file_contents":"<text>"}` request and receive a structured Markdown report listing all policy violations, their messages, and fix suggestions. The LSAP endpoint uses the same `engine.Evaluate()` call as the MCP tool (W-0012).

### Context

LSAP (Language Server Agent Protocol — `github.com/lsp-client/LSAP`, MIT) is an orchestration layer that translates LSP's atomic editor operations into high-level "cognitive" interfaces for AI agents. Its Markdown-first response format is token-efficient and directly consumable by LLMs without JSON parsing.

GOV-LSP is a natural fit: its diagnostics are already semantically rich (natural language messages, typed fix suggestions). Wrapping them in LSAP's `check_policy` interface requires no changes to the engine or policy files.

See `research/lsap/README.md` for protocol analysis, comparison with MCP, and a `check_policy` request/response design.

### Notes

Blocked on LSAP protocol stability and Go SDK availability. Re-evaluated 2026-03-11: the LSAP Python SDK is now at 0.2.0 on PyPI (pre-stable; 0.x.x carries no stable API guarantee). There is no Go SDK for LSAP as of this date — Go support is provided only by running `gopls` as a language server via the Python client or CLI. Keeping as `backlog` (not `ready`). Revisit when either the LSAP spec reaches 1.0 or a native Go SDK is published. The engine call and policy schema will not need to change — this is purely a new transport adapter.

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

Fix for (1): `export NO_PROXY=$(echo "${NO_PROXY:-}" | sed 's/,\*\.googleapis\.com//g; s/,\*\.google\.com//g'); export no_proxy="$NO_PROXY"` before `go mod download`. Fix for (2): `npm install -g global-agent` in `copilot-setup-steps.yml` or as a devcontainer step; then set `NODE_OPTIONS=--require global-agent/bootstrap` in `scripts/mcp-start.sh`. Vendoring sidesteps issue (1) entirely and is the preferred day-to-day path. The `vendor/` directory was committed as part of the Session 6 work (see W-0030) — the `go mod vendor` step referenced here is already done and the directory exists in the repository. The original note's reference to "W-0014 dependency" was misleading (W-0014 is the agent skill, unrelated to vendoring); that coupling no longer applies.

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
created: 2026-03-07
updated: 2026-03-07

### Outcome

Repository structure is standardised: single `.github/copilot-instructions.md` source of truth, `.github/skills` submodule, `sync-skills.yml` workflow, `BACKLOG.md`, `PROGRESS.md`, `CHANGELOG.md`, and `docs/adr/` all present and consistent.

### Context

Standardisation pass to remove AGENTS.md, CLAUDE.md, .claude/, scripts/sync-copilot-instructions.sh and align with all other repos in the davidamitchell organisation.

### Notes


---

## W-0032

status: done
created: 2026-03-11
updated: 2026-03-11

### Outcome

A production-quality governance loop wrapper exists at `scripts/governance_loop/governance_loop.sh` that orchestrates a headless Copilot CLI agent in a policy-governed workspace. It runs Phase 1 (initial agent task), then Phase 2 (convergence correction loop): collects violations via LSP simulation (`lsp_check.py`) or batch `gov-lsp check --format json` fallback, formats them as human-readable summary + raw JSON, injects them into a correction prompt, and runs the agent iteratively until zero violations or `MAX_ITER` is reached. Stuck-loop detection (SHA-256 fingerprint of the violation set across two consecutive iterations) prevents infinite loops. The loop is a feedback harness only — it never modifies workspace files; the agent applies all fixes.

### Context

The original governance loop concept (W-0012) required a lightweight IDE emulator to close the Policy-LSP enforcement feedback loop into agent context. Without it, the MCP and LSP enforcement tools existed but there was no orchestration layer to run the agent in a governed workspace, detect violations, and drive the agent towards convergence. The wrapper fills that gap: it provides the enforcement rails for a headless agent the way an IDE provides inline squiggles for a human developer.

Key design decisions (see `docs/adr/0006-agent-loop-integration.md`):
- The loop is a feedback harness, not a fix engine. The agent decides how to fix each violation.
- `USE_LSP_SIM=1` (default) exercises the full LSP protocol path via `lsp_check.py`; `USE_LSP_SIM=0` uses batch check.
- `scripts/governance_loop.sh` is a compatibility shim that delegates to the canonical implementation.
- `tests/governance_loop.bats` covers logging helpers, workspace isolation, LSP simulation, and `tee` pipeline semantics (16 tests).

### Notes

Implemented across Sessions 8–10 (2026-03-05 to 2026-03-10). The `auto_apply_rename_fixes()` function was added then removed — renaming via shell was the wrong design. Remaining gaps in test coverage tracked as W-0036.

---

## W-0033

status: ready
created: 2026-03-11
updated: 2026-03-11

### Outcome

The engine test suite includes property-based tests using Go's `testing/quick` package: for every input satisfying a policy's precondition (e.g. a `.md` filename that is not SCREAMING_SNAKE_CASE), the `deny` rule always fires; for every input not satisfying it (e.g. a valid SCREAMING_SNAKE_CASE `.md` filename), it never fires. At least one property test exists for each policy in `policies/`.

### Context

The current test suite uses example-based tests (specific filenames, specific violation messages). Example tests verify known cases but do not prove the rule is correct for the entire input space. Property-based tests define the invariant directly and use a random generator to find counterexamples — they catch edge cases the examples miss (e.g. files that look like they should pass but trigger a regex boundary, or files with unusual Unicode that break assumptions). `testing/quick` is already in the Go standard library; no new dependency is required.

### Notes

Start with `governance.filenames` — the precondition (non-SCREAMING_SNAKE_CASE `.md` filename) is straightforward to express as a generator. `testing/quick.Check` runs 100 random inputs by default; increase to 1000 for policy tests. For `governance.content`, the precondition is "file extension is `.go` and content does not start with `//` or `/*`" — use a custom `Generate` method on the input struct.

---

## W-0034

status: ready
created: 2026-03-11
updated: 2026-03-11

### Outcome

`gov-lsp list-invariants` subcommand (or MCP tool `gov_list_invariants`) outputs a machine-readable JSON array of all policy rules known to the server. Each entry has at minimum: `"id"` (string, the violation ID from the `deny` rule), `"description"` (string, the human-readable message template), `"severity"` (string, `"error"` | `"warning"` | `"info"`), and `"file_pattern"` (string, the glob or extension the rule applies to). The output is valid JSON, stable across invocations for the same policy set, and suitable for piping into `jq`.

### Context

This is the interface the planned `Governance-Framework` repo will consume to query which invariants exist and cross-reference them against test scenarios. Without it, an external coverage tool must parse Rego source to discover rules — a fragile approach that breaks whenever rule structure changes. The `list-invariants` subcommand makes the rule set first-class: it is queryable, versionable, and auditable without source access.

### Notes

Implementation: evaluate each policy with a synthetic input that triggers no violations, then introspect the `deny` partial set metadata. Alternatively, add a companion `metadata` rule to each Rego file (e.g. `metadata := {"id": "...", "description": "...", ...}`) and collect those. The latter is more explicit and decoupled from evaluation. Write an ADR before implementation to choose the approach.

---

## W-0035

status: backlog
created: 2026-03-11
updated: 2026-03-11

### Outcome

`gov-lsp coverage-report --scenarios <dir>` reads a directory of evaluation scenario files (JSON, same format as `davidamitchell/Agent-Evaluation` datasets) and reports: (1) which policy invariants are exercised by at least one scenario, (2) which invariants have no matching scenario (coverage gap), (3) a summary coverage percentage. Exit code 1 if any invariant is unexercised.

### Context

This closes the loop between Policy-LSP enforcement and Agent-Evaluation testing. The scenario files describe agent actions and expected outcomes. Cross-referencing them against the live invariant list (W-0034) reveals which policies have never been tested by a real agent scenario — a coverage gap that could hide silent enforcement failures. The intended consumer is the `davidamitchell/Governance-Framework` repo, which coordinates Policy-LSP, Agent-Evaluation, and the governance loop.

### Notes

Depends on W-0034 (invariant registry). The scenario file format must be agreed with `davidamitchell/Agent-Evaluation` before implementation — raise a cross-repo issue. Mark `ready` once W-0034 is done and the scenario format is stable.

---

## W-0036

status: ready
created: 2026-03-11
updated: 2026-03-11

### Outcome

`tests/governance_loop.bats` includes explicit tests for three paths that are currently uncovered: (a) `gov-lsp` binary absent → the loop exits non-zero with a clear error message (fail-closed, not silent); (b) a workspace containing a policy-violating file → the loop collects violations and the correction prompt includes both the human-readable summary and the raw violation JSON; (c) a workspace with only compliant files → the loop exits 0 after Phase 1 with no correction prompt emitted (no noise).

### Context

The governance loop wrapper (W-0032) is the primary enforcement mechanism for headless agents. Its correctness properties are: fail-closed when the binary is absent (prevents silent bypass), accurate violation surfacing (agent receives all violations), and clean exit on a clean workspace (no false prompts that waste agent turns). These three properties are not currently covered by the 16 existing bats tests.

### Notes

The binary-absent test must verify exit code 2 (missing prerequisite) per the loop's documented exit code contract. The violation-surfacing test can use a synthetic workspace with a single `my-notes.md` file and assert the correction prompt contains `"my-notes.md"` and `"markdown-naming-violation"`. The clean-workspace test asserts the loop prints a convergence message and exits 0 without calling the agent a second time. Use `bats` helper functions (`assert_output`, `assert_failure`) for readable assertions.

---

## W-0037

status: ready
created: 2026-03-11
updated: 2026-03-11

### Outcome

`docs/writing-policies.md` exists and covers: (1) the required `deny` rule shape (package namespace, `import future.keywords`, set-of-objects return type); (2) the required fields in each violation object (`id`, `message`) and the optional fields (`level`, `location`, `fix`); (3) how `input` is structured when the engine calls a policy (the `filename`, `extension`, `path`, `file_contents` fields); (4) how to write a `fix` object for the `codeAction` round-trip; (5) how to test the rule in isolation using `engine.New(fstest.MapFS{...})` before wiring it into the server; (6) a minimal end-to-end example: a complete Rego file + its Go unit test.

### Context

A developer wanting to add an organisation-specific policy currently has to read `internal/engine/rego.go`, `internal/engine/rego_test.go`, and an existing policy file to understand the required shape. There is no single document explaining the authoring contract. The guide makes Policy-LSP extensible without requiring the author to understand the LSP implementation, and is the primary reference for any `Governance-Framework` consumer that needs to add a repo-specific rule.

### Notes

Keep the guide focused on the authoring contract, not the LSP protocol or the engine internals. Link to `docs/adr/0003-rego-deny-schema.md` (the deny rule schema decision) and `docs/adr/0004-policies-as-runtime-directory.md` (why policies are a runtime directory). Include at least one worked example of a content-aware policy (file contents check) and one filename/path policy to demonstrate both `file_contents` and `filename` input fields.
