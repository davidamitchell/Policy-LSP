# Research: LSP Agent Integration for the Research Repo

**Question:** How can the `davidamitchell/Research` repository use GOV-LSP so that GitHub Copilot Agent enforces policies during agentic coding sessions?

**Status:** Findings complete. Templates produced. Submodule setup documented.

---

## What We Want

When Copilot Agent (or Claude Code) edits files in the Research repo, it should:

1. Know that GOV-LSP is the policy enforcement mechanism.
2. Check GOV-LSP diagnostics as part of its definition of done before marking a task complete.
3. Understand what policy violations look like and how to fix them (rename suggestion in `diagnostic.data`).

This is an *agent instructions* problem, not a protocol problem. GOV-LSP speaks LSP. Copilot Agent speaks MCP or reads the VSCode Problems panel. The bridge is the agent instruction file.

---

## Approach A — `LSP.agent.md` in the Research repo (recommended today)

GitHub Copilot Agent reads instruction files from `.github/copilot-instructions.md`. Claude Code reads `AGENTS.md`. Both can be pointed at additional domain-specific instruction files.

The `LSP.agent.md` file in the Research repo tells the agent:

- GOV-LSP is running as an LSP server on the workspace (via Neovim, VSCode, or Zed)
- Before completing any task, ask: "Are there any LSP diagnostics from gov-lsp?"
- If there are violations, apply the fix from `diagnostic.data.value` or ask the user
- The specific policy rules in force are in `policies/` of this repo

**How Copilot Agent reads the diagnostics today (without MCP):**

In VSCode with the GOV-LSP extension installed, every `didOpen` / `didChange` event triggers policy evaluation. Diagnostics appear in the Problems panel. Copilot Agent in VSCode has implicit access to the Problems panel — when asked to fix policy violations, it sees the diagnostic message, range, and `data.value` (the suggested rename).

**Template:** `templates/LSP.agent.md`

---

## Approach B — Git submodule (brings the binary into the Research repo)

The Research repo adds Policy-LSP as a git submodule. This means:

- The server source lives at `tools/gov-lsp/` (pinned to a specific commit)
- The Research repo builds the binary as part of its setup
- Policies live in the Research repo's own `policies/` directory (project-specific rules)
- The submodule is updated deliberately — governance rules are not silently changed by upstream

**Why a submodule rather than `go install`:**

`go install` fetches HEAD and requires a Go toolchain. A submodule pins the server version and the binary can be pre-built in CI. Contributors (human or AI) opening the repo in a devcontainer get the exact version without any network fetch.

**Setup guide:** `templates/submodule-setup.md`

---

## Approach C — MCP wrapper (future, W-0012)

Once `gov-lsp-mcp` is built (backlog W-0012 in this repo), the Research repo can add it to `.github/mcp.json` and `.mcp.json`. Copilot Agent and Claude Code can then call `check_file` as a tool during agentic sessions — no editor required.

This is the cleanest long-term integration but is not yet built.

---

## Recommended path for the Research repo (today)

1. Add the git submodule (see `templates/submodule-setup.md`)
2. Add `policies/` with Research-repo-specific Rego rules
3. Add `LSP.agent.md` (see `templates/LSP.agent.md`) — instruct Copilot to check GOV-LSP diagnostics
4. Update the Research repo's `.github/copilot-instructions.md` to reference `LSP.agent.md`
5. Connect via VSCode or Neovim (see `docs/integrations.md` in this repo)

When W-0012 is done, replace the editor-only path with the MCP config and the agent instructions become fully autonomous.

---

## What Copilot Agent can see today vs. after W-0012

| Capability | Today (VSCode) | After W-0012 (MCP) |
|---|---|---|
| Detect violations | ✅ via Problems panel | ✅ via `tools/call` |
| Read fix suggestion | ✅ via `diagnostic.data.value` | ✅ in tool response |
| Apply rename fix | ✅ via `workspace/applyEdit` (Copilot reads suggestion) | ✅ same |
| Works outside editor | ❌ needs VSCode open | ✅ any agentic session |
| Works in CI | ❌ | ✅ |
| Zero-config for agent | ❌ needs extension installed | ✅ just `.github/mcp.json` |

---

## Key finding: `diagnostic.data` is the bridge

The GOV-LSP server embeds the fix suggestion in `diagnostic.data`:

```json
{
  "severity": 1,
  "code": "markdown-naming-violation",
  "message": "'lower_case.md' must be SCREAMING_SNAKE_CASE",
  "data": {
    "type": "rename",
    "value": "LOWER_CASE.md"
  }
}
```

Copilot Agent can read this `data` field from the VSCode Problems panel context and knows exactly what file rename to suggest. No separate CodeAction request is required — the fix is self-contained in the diagnostic payload. This design was deliberate (see `docs/adr/0003-rego-deny-schema.md`).
