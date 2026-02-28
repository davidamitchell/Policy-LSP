# MCP Configuration and Agent Skills

This page covers how GOV-LSP is configured for AI coding agents via the Model Context Protocol (MCP), and how the agent skills from [`davidamitchell/Skills`](https://github.com/davidamitchell/Skills) are used in this repository.

---

## MCP server configuration

MCP server configs live in two files:

| File | Used by |
|---|---|
| `.github/mcp.json` | GitHub Copilot Agent |
| `.mcp.json` | Claude Code and other MCP-compatible agents |

### Available servers

| Server | Purpose |
|---|---|
| `fetch` | HTTP fetches (OPA docs, LSP spec lookups) |
| `sequential_thinking` | Multi-step reasoning chains |
| `time` | Current date/time for commit messages and ADR dates |
| `memory` | Cross-session persistent facts about the codebase |
| `git` | Git operations (log, diff, blame) |
| `filesystem` | Read/write `/workspace` files |
| `brave_search` | Web search for LSP spec, OPA docs, Go stdlib |
| `github` | GitHub API (issues, PRs, releases) |

### Connecting GOV-LSP itself as an MCP tool

To use the server as an MCP compliance tool for another agent:

```json
{
  "mcpServers": {
    "gov-lsp": {
      "command": "/path/to/gov-lsp",
      "args": ["--policies", "/path/to/policies"]
    }
  }
}
```

See [`docs/integrations.md`](integrations.md) for per-agent setup details.

---

## Agent skills

Skills are located in `.github/skills/` and `.claude/skills/` — both are git submodules tracking [`davidamitchell/Skills`](https://github.com/davidamitchell/Skills). A weekly workflow (`.github/workflows/sync-skills.yml`) advances both pointers to the latest commit automatically.

To initialise the submodules after cloning:

```bash
git submodule update --init --recursive
```

### Skills reference

| Skill | File | When to use |
|---|---|---|
| `backlog-manager` | `backlog-manager/SKILL.md` | Adding, refining, or reviewing items in `BACKLOG.md` |
| `remove-ai-slop` | `remove-ai-slop/SKILL.md` | Reviewing docs or commit messages for hollow filler language |
| `speculation-control` | `speculation-control/SKILL.md` | Checking whether a claim is established fact or uncertain assumption |
| `strategy-author` | `strategy-author/SKILL.md` | Writing architecture strategy documents or ADRs |
| `decisions` | `decisions/SKILL.md` | Recording Architecture Decision Records |

---

## Using the backlog-manager skill

The `backlog-manager` skill manages `BACKLOG.md` — the repo improvement backlog.

### Commands

```
Add: <description>         # Create a new item; defaults to needing_refinement
Refine W-XXXX              # Sharpen the Outcome statement, set status to ready
List                       # Show all items: ID – status – first line of Outcome
Next                       # Return the first ready item
Start W-XXXX               # Set status to active
Complete W-XXXX            # Set status to done
Archive W-XXXX             # Set status to archived
```

### Example: adding a backlog item

In Claude Code or Copilot, invoke the skill and say:

```
Add: The server should support TCP transport in addition to stdio, 
     so that remote agent frameworks that don't support stdio can connect.
```

The skill will create a new `W-XXXX` entry with a clear Outcome and set it to `needing_refinement` if the outcome statement needs sharpening, or `ready` if it's specific enough.

### Outcome standard

Every backlog item must have an observable Outcome. Good outcomes:
- ✅ `Running gov-lsp --transport tcp --addr :7998 accepts a single LSP connection and processes messages identically to stdio mode`
- ❌ `Add TCP support` (this is a task, not an outcome)

---

## Using the decisions skill

When making a significant design decision, invoke the `decisions` skill to generate a MADR-format ADR:

```
Use the decisions skill to write an ADR for: choosing stdio-first transport over TCP
```

The skill will produce a `docs/adr/NNNN-short-title.md` with Context, Decision, and Consequences sections.

After generating:
1. Review and edit for accuracy
2. Update `docs/adr/README.md` with the new entry
3. Commit with message `docs: add ADR NNNN - <title>`

---

## Using remove-ai-slop

Before committing documentation, commit messages, or ADRs, run the `remove-ai-slop` skill:

```
Review this text for hollow filler language and remove it:
<paste text>
```

The skill flags phrases like "seamlessly", "robust", "comprehensive", "leverages", and any sentence that says something without meaning it.

---

## Keeping skills up to date

The weekly `sync-skills.yml` workflow runs every Monday at 06:00 UTC and advances both submodule pointers. To manually sync:

```bash
git submodule update --remote .github/skills
git submodule update --remote .claude/skills
git add .github/skills .claude/skills
git commit -m "chore: update skills submodules to latest"
```
