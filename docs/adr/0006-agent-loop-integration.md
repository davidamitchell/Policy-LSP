# 0006. Agent Loop Integration: PostToolUse Hook + MCP Server

Date: 2026-03-01
Status: accepted

## Context

The primary consumers of GOV-LSP are AI coding agents working without an IDE
— specifically Claude Code triggered from a mobile device and GitHub Copilot
working autonomously on issues. Neither agent has a human sitting at an editor
watching for red squiggles.

The core challenge: LSP is a client–server protocol designed around an editor
that initiates requests (open document, change document, request diagnostics).
Without an editor, nothing initiates those events. Policy violations only become
visible when something explicitly asks for them.

Two candidate integration paths exist:

**Path A: MCP tool.** Expose `gov-lsp` as an MCP tool. The agent explicitly
calls `gov_check_file` or `gov_check_workspace` when it decides to. This is
correct and explicit but relies on the agent remembering to check — it is opt-in
and can be skipped.

**Path B: PostToolUse hook.** Claude Code's hook system fires a shell command
after every `Write`, `Edit`, or `MultiEdit` tool call. The hook can run
`gov-lsp check` on the modified file and return violations as exit-1 output.
This is always-on and does not require the agent to remember anything.

The two paths are complementary, not alternatives: the hook is the background
enforcement layer; the MCP tool is the explicit query interface.

## Decision

Implement both:

1. **PostToolUse hook** — `.claude/settings.json` triggers
   `.claude/hooks/policy-gate.sh` after every file write. The script locates
   (or silently builds) the `gov-lsp` binary, runs `gov-lsp check` on the
   modified file, and exits 1 with formatted violation output. Claude Code
   surfaces the output inline and the agent is expected to fix violations
   before continuing. The hook fails open (exit 0) if the binary is not
   available.

2. **MCP server** — A new `gov-lsp mcp` subcommand implements the Model Context
   Protocol over newline-delimited JSON-RPC 2.0 on stdio. It exposes two tools:
   `gov_check_file` and `gov_check_workspace`. The server is registered in
   `.mcp.json` via `scripts/mcp-start.sh`, which auto-builds the binary on
   first run. No new binary is introduced; the `mcp` subcommand is added to the
   existing `gov-lsp` entry point alongside `check`.

3. **GitHub Copilot integration** — `.github/workflows/copilot-setup-steps.yml`
   builds `gov-lsp` and places it on PATH before the agent session starts.
   Instructions in `.github/copilot-instructions.md` make compliance mandatory.
   The CI workflow runs `gov-lsp check .` on every push.

4. **CLAUDE.md** — A project-level `CLAUDE.md` gives Claude Code explicit
   instructions about the policy system, violation response protocol, and how
   to bootstrap the binary.

5. **Devcontainer** — `.devcontainer/devcontainer.json` builds `gov-lsp` on
   container creation so GitHub Codespaces users and agents working in a
   container environment have the binary immediately available.

The MCP server uses the same `engine.Engine` and the same Rego policies as the
LSP server and the `check` subcommand. No new evaluation logic is introduced.

## Consequences

**Easier:**
- Policy violations are surfaced automatically during agent coding loops, even
  when triggered from a mobile device with no IDE.
- Agents do not need to remember to check — the hook fires unconditionally.
- GitHub Copilot agent and CI both have access to the same policy tool.
- The `gov-lsp` binary remains the single artefact to build and distribute.
- Policies remain pure Rego and are unchanged; the integration is purely at the
  invocation layer.

**Harder / New constraints:**
- The hook requires `jq` or `python3` to parse tool context from stdin. It
  fails open on parse failure, which means a missing parser silences violations.
  This is acceptable for now (prefer noise-free failure over a blocked agent).
- The MCP server requires a built binary. `scripts/mcp-start.sh` handles this
  automatically but adds a build step to first-time MCP client connections.
- The `mcp` subcommand shares the `main` package with the LSP server and check
  subcommand. If the binary grows further, splitting into separate commands
  should be reconsidered.

**Out of scope for this ADR:**
- LSAP (Language Server Agent Protocol) integration (tracked as W-0013).
- TCP transport for the MCP server (tracked as W-0009).
- Hot-reload of policies within a running MCP session (tracked as W-0004).
