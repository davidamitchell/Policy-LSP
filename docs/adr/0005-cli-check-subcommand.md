# 0005 — CLI Check Subcommand (`gov-lsp check`)

| Field | Value |
|---|---|
| Status | accepted |
| Date | 2026-02-28 |
| Deciders | GOV-LSP maintainers |
| Supersedes | — |

---

## Context

GOV-LSP was initially designed purely as a stdio LSP server. To use it, a developer needs an editor with an LSP client (VSCode extension, Neovim `nvim-lspconfig`, Zed). This creates friction for:

1. **CI pipelines** — a GitHub Actions job cannot run an interactive LSP client.
2. **Agentic sessions** — Claude Code, Gemini, and Codex run outside an editor; they cannot connect to a stdio LSP server without an intermediary.
3. **Quick spot-checks** — developers and agents want to run a fast policy scan without starting an editor.
4. **Self-governance** — the Policy-LSP repo itself uses lowercase markdown filenames in `docs/` to demonstrate the policy. Verifying this without a running editor is otherwise impossible.

The LSP server mode will remain the primary runtime, but a complementary batch mode is needed.

---

## Decision

Add a `check` subcommand to the existing `gov-lsp` binary:

```
gov-lsp check [--policies <dir>] [--format text|json] [path...]
```

**Behaviour:**
- Walks the given paths recursively (default: `.`)
- Skips hidden directories (`.git`, `.github`, etc.)
- Evaluates each file against all loaded policies using the existing `engine.Evaluate()`
- Prints results to stdout:
  - `text` format: one line per violation with an optional `Fix (rename): <value>` line
  - `json` format: a JSON array of `CheckResult` objects suitable for machine consumption
- Exits `0` if no violations, `1` if violations found, `2` on usage error

**Implementation:**
- Single binary — no separate `gov-lsp-check` command; the subcommand is detected by checking `os.Args[1] == "check"` before flag parsing.
- `runCheck(eng, paths, format, w)` is extracted as a pure function to make it testable without OS side effects (takes `io.Writer`).
- `CheckResult` struct is exported so it can be used by the future MCP wrapper (W-0012) and agent skill (W-0014).

---

## Alternatives Considered

### A: Separate `gov-lsp-check` binary under `cmd/gov-lsp-check/`

- **Pro:** Clean separation of concerns.
- **Con:** Doubles the build and release surface. Requires distributing two binaries. The engine is already shared; a subcommand achieves the same result.

### B: Keep batch mode as a shell script using `opa eval`

- **Pro:** No binary changes required; uses OPA CLI directly.
- **Con:** Requires `opa` to be installed separately. Does not produce the same violation schema as the LSP server (different output format, no `fix` field). Cannot be embedded in editor extensions or MCP wrappers.

### C: Add a `--check` flag instead of a subcommand

- **Pro:** Simpler arg parsing.
- **Con:** Mixes two operating modes in a single flag namespace. Subcommands are the conventional Go CLI pattern (cf. `go build`, `go test`).

---

## Consequences

**Positive:**
- Enables CI policy enforcement without an editor: `make check-policy` or `gov-lsp check .` in a workflow.
- Enables agents (Claude Code, Gemini, Codex) to call `gov-lsp check <file>` directly — the foundation for the `gov-lsp-governance` skill (W-0014).
- Self-governance demonstration: running `gov-lsp check .` on the Policy-LSP repo itself produces real violations (`docs/getting-started.md`, `docs/policies.md`, etc.), which confirms the tool works end-to-end against real files.
- `CheckResult` JSON output is identical in structure to the LSP `Diagnostic.data` field, making it easy to consume in scripts, MCP tools, and skills.

**Negative / Trade-offs:**
- The `check` subcommand makes the binary dual-purpose. Any future subcommand (e.g., `gov-lsp lint`, `gov-lsp serve --tcp`) must be added to the same top-level dispatcher in `main.go`.
- The walk logic reads entire file contents into memory before evaluation; for very large files this is wasteful. Acceptable for the current use cases (governance files are typically small).

---

## Path Forward

| Item | Status |
|---|---|
| W-0012 — MCP wrapper (`gov-lsp-mcp`) | ready — calls `engine.Evaluate()` directly, exposes `check_file` MCP tool |
| W-0014 — `gov-lsp-governance` skill | ready after W-0012 — wraps `gov-lsp check` as an agent skill |
| W-0015 — VS Code extension | ready — wraps the binary in the LSP server mode for in-editor diagnostics |
