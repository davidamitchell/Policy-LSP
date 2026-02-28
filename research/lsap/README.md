# Research: LSAP — Language Server Agent Protocol

**Question:** Does the Language Server Agent Protocol (LSAP) help solve the gap between GOV-LSP's LSP interface and what AI coding agents need?

**Status:** Research complete (updated with full ecosystem scan). Recommendation and backlog item produced.

**Sources:**
- [LSAP GitHub](https://github.com/lsp-client/LSAP) — official spec and Python SDK (v1.0.0-alpha, MIT licence)
- [lsp-client ecosystem](https://lsp-client.github.io/) — website, blog, and architecture overview
- [Designing LSAP](https://lsp-client.github.io/blog/designing-lsap/) — protocol design rationale
- [lsp-skill GitHub](https://github.com/lsp-client/lsp-skill) — pre-built LSAP skill installable into Claude Code, Gemini, Codex
- [Announcing LSP Analysis Skill](https://lsp-client.github.io/blog/announcing-lsp-analysis-skill/) — announcement post
- [Agent Client Protocol](https://blog.promptlayer.com/agent-client-protocol-the-lsp-for-ai-coding-agents/) — ACP, a similar initiative by PromptLayer/Zed
- [LSP-AI](https://github.com/SilasMarvin/lsp-ai) — AI-powered language server as LSP backend
- [MCP Language Server](https://mcplane.com/mcp_servers/mcp-language) — proxy LSP features through MCP
- [Building a Least-Privilege AI Agent Gateway for Infrastructure](https://www.infoq.com/articles/building-ai-agent-gateway-mcp/) — OPA + MCP agent gateway pattern

---

## What LSAP Is

LSAP is an open protocol (v1.0.0-alpha, MIT) that sits **above** LSP as an orchestration layer. Its core insight is the same problem we face with GOV-LSP:

> LSP was designed for editors. It speaks in atomic, machine-friendly operations. AI agents need cognitive, intent-level operations.

| Perspective | Protocol | Style | Example |
|---|---|---|---|
| Editor | LSP | Atomic | `textDocument/definition` → single location |
| Agent | LSAP | Cognitive | `find_references` → Markdown report with context, callers, summaries |

LSAP wraps an LSP server and translates agent semantic requests into sequences of LSP calls, then formats the result as a Markdown document optimised for LLM consumption (token-efficient, no nested JSON).

### LSAP Request/Response shape

**Request:**
```json
{
  "locate": { "file_path": "src/models.py", "find": "class <|>User" },
  "mode": "references",
  "max_items": 5
}
```

**Response (Markdown):**
```markdown
# References Found
Total references: 12 | Showing: 5

### src/auth/login.py:45
In `LoginHandler.authenticate` (`method`)
```python
44 | def authenticate(credentials):
45 |     if not User.validate(credentials):
```
```

The agent receives one structured document, not a list of JSON locations requiring further LSP round-trips.

---

## Why This Is Directly Relevant to GOV-LSP

GOV-LSP already produces semantic, agent-readable diagnostics — the `diagnostic.data` field carries a complete fix suggestion. But the **transport gap** remains:

| Scenario | Today | With LSAP |
|---|---|---|
| Agent in VSCode | ✅ reads Problems panel | ✅ (same, or LSAP client) |
| Agent outside editor | ❌ must speak LSP | ✅ cognitive HTTP/stdio request |
| Agent in CI | ❌ must pipe LSP messages | ✅ single `check_policy` call |
| Any agent (no editor) | ❌ | ✅ |

GOV-LSP's diagnostic output is already "cognitive" by LSAP's definition — it returns policy violations with human-readable messages and machine-applicable fixes. The missing piece is a **cognitive request interface** to trigger evaluation. That is what LSAP (or MCP, or both) provides.

---

## LSAP vs MCP for GOV-LSP

Both solve the same transport gap. Here is how they compare for this use case:

| | LSAP | MCP |
|---|---|---|
| Design origin | Language-server-specific | General-purpose tool protocol |
| Transport | stdio / HTTP | stdio / HTTP (same) |
| Request shape | Semantic, LSP-vocabulary-aware | Arbitrary tool `call` |
| Response shape | Markdown-first (LLM-optimised) | Arbitrary JSON |
| Tooling support | Alpha, Python SDK only | Mature, broad client support |
| GitHub Copilot supports | No (not yet) | Via `mcpServers` config |
| Claude Code supports | No (not yet) | Via `.mcp.json` |
| Agent awareness | By protocol design | By tool description |

**For GOV-LSP today:** MCP (W-0012) has wider agent support and is the practical choice. LSAP is architecturally cleaner and more purpose-built for the problem but is v1.0.0-alpha with no Go SDK.

**Both can coexist.** The `engine.Evaluate()` function at the core of GOV-LSP is protocol-agnostic. The same engine can be exposed as:
1. An LSP server (what exists today)
2. An MCP tool (`gov-lsp-mcp`, W-0012)
3. An LSAP cognitive capability (future W-0013 — see below)

---

## The LSAP `check_policy` Capability for GOV-LSP

A GOV-LSP LSAP endpoint would look like this:

**Request:**
```json
{
  "mode": "check_policy",
  "file_path": "docs/getting-started.md",
  "file_contents": "..."
}
```

**Response (Markdown):**
```markdown
# Policy Check: docs/getting-started.md

## ❌ Violations (1)

### markdown-naming-violation
**Rule:** `governance.filenames`
**Message:** 'getting-started.md' must be SCREAMING_SNAKE_CASE
**Fix:** Rename to `GETTING_STARTED.md`

```diff
- docs/getting-started.md
+ docs/GETTING_STARTED.md
```

---
*Checked 1 policy file. 0 files passed, 1 file failed.*
```

An agent consuming this response knows exactly what to do without parsing LSP diagnostics JSON, mapping severity codes, or understanding `diagnostic.data` structure. The fix is stated in plain English and as a diff.

---

## The `lsp-skill` Ecosystem (Key New Finding)

The lsp-client organisation ships more than just the LSAP protocol. The **`lsp-skill`** project is a pre-built agent skill that installs LSAP-powered code intelligence directly into agent tools:

```
lsp-client/lsp-skill  →  Claude Code (~/.claude/skills/)
                       →  Gemini    (~/.gemini/skills/)
                       →  Codex     (~/.codex/skills/)
                       →  OpenCode  (~/.config/opencode/skill/)
```

Installation for Claude Code:
```bash
mkdir -p ~/.claude/skills/lsp-code-analysis
TMP=$(mktemp -d)
curl -sSL https://github.com/lsp-client/lsp-skill/releases/latest/download/lsp-code-analysis.zip -o "$TMP/lsp-code-analysis.zip"
unzip -o "$TMP/lsp-code-analysis.zip" -d ~/.claude/skills/
```

**This is the same `~/.claude/skills/` path used by the `davidamitchell/Skills` submodule already in this repo.** The skills system in GOV-LSP and the LSAP skill system are the same mechanism.

### What `lsp-skill` provides (code intelligence)

The `lsp-code-analysis` skill gives agents:
- Semantic navigation (definitions, references, implementations)
- Cross-file dependency tracing
- Type-aware inspection (signatures, docs) without reading implementation code
- Structural code outline (high-level map without reading full files)
- Supports Go (via `gopls`), Python, Rust, TypeScript, Java, Deno

### What `lsp-skill` does NOT provide (policy governance)

`lsp-skill` is a **code intelligence** skill. It bridges `gopls` (or other standard language servers) to agents. It does not evaluate Rego policies, report governance violations, or suggest compliance fixes.

**GOV-LSP is a different kind of language server.** It is a policy enforcement server, not a code intelligence server. The `lsp-skill` and GOV-LSP are **complementary**:

| Skill | What it does | Source |
|---|---|---|
| `lsp-code-analysis` (lsp-skill) | Navigate code: definitions, references, types | `gopls` via LSAP |
| `gov-lsp-skill` (to be built) | Enforce governance: naming, structure, content | GOV-LSP via LSAP |

### The `gov-lsp-skill` Opportunity

The `lsp-skill` architecture shows the exact pattern for a **`gov-lsp-skill`**:

1. The skill is a Markdown file (SKILL.md) that tells the agent what commands are available and how to invoke them.
2. The commands call a CLI tool (`lsp-cli` in the reference implementation; could be `gov-lsp check` for GOV-LSP).
3. The CLI returns Markdown-formatted results the agent reads directly.

A `gov-lsp-skill` would let any Claude Code, Gemini, or Codex agent run:
```
Please run the GOV-LSP policy check on the files I just changed.
```
...and receive a Markdown report without any LSP client, VSCode, or editor being involved.

This is **simpler than W-0012 (MCP)** for skill-aware agents and **simpler than W-0013 (full LSAP)** for non-skill-aware agents. It is a viable W-0014.

---

## Related Protocols in the Landscape

### Agent Client Protocol (ACP)
ACP is a similar initiative from PromptLayer/Zed — an open JSON-RPC protocol inspired by LSP, designed to connect editors to AI coding agents in a vendor-neutral way. It focuses on the editor→agent direction (agent discovery, invocation) rather than the agent→language-server direction that LSAP addresses.

### OpenAI Codex App Server Protocol
OpenAI's Codex uses a bidirectional JSON-RPC protocol over stdio or JSONL between the agent core and IDE clients (VSCode, JetBrains, CLI). Architecturally similar to LSP and MCP. Currently closed/proprietary.

### MCP Language Server (mcplane)
A Go project that proxies LSP features through MCP — symbol search, diagnostics, code actions — so AI clients (Claude Desktop) can call them as MCP tools. This is the closest existing thing to an LSAP implementation in Go, though it does not implement the LSAP protocol specifically.

---

## LSAP Implementation in Go

**Status:** No Go LSAP SDK exists yet. The reference implementation is Python only.

**Implementation path for GOV-LSP:**
1. LSAP's JSON Schema is formally defined in `schema/` in the protocol repo — these can drive a Go struct definition without depending on the Python SDK.
2. The transport is JSON-RPC over stdio (same as GOV-LSP already uses for LSP).
3. `engine.Evaluate()` already does all the work — an LSAP handler is a thin wrapper that maps a `check_policy` request to `engine.Evaluate()` and formats the result as Markdown.
4. The server would advertise `capabilities.lsap: true` in its initialize response alongside the LSP capabilities.

This is a meaningful but contained piece of work — roughly the same scope as W-0012 (MCP wrapper).

---

## Recommendation

1. **Proceed with W-0012 (MCP wrapper) as planned.** It has the widest agent support today (Copilot Agent, Claude Code both support MCP natively).

2. **Add W-0014: `gov-lsp-skill` — LSAP agent skill.** This is the most actionable near-term step. Modelled on `lsp-client/lsp-skill`, a `gov-lsp-skill` is a SKILL.md file + the `gov-lsp check` CLI subcommand (now implemented). The skill is ~50 lines of Markdown instructions. Installs into Claude Code at `~/.claude/skills/gov-lsp-governance/` — the same mechanism already used by `davidamitchell/Skills` in this repo. **The `gov-lsp check` subcommand is complete (W-0001/ADR-0005) — W-0014 only needs the SKILL.md wrapper now.**

3. **Add W-0013: Full LSAP cognitive endpoint.** Watch the LSAP spec stabilise (currently v1.0.0-alpha). When a Go-idiomatic path exists (the protocol schema is stable and a Go SDK or sufficient examples exist), implement a `check_policy` LSAP capability alongside the MCP tool. The engine call is identical; only the request/response shape differs.

4. **GOV-LSP is well-positioned.** Unlike `gopls` or a type-checker, GOV-LSP's output is already semantically rich — policy violation messages, severity, and fix suggestions are all natural language. Wrapping them in LSAP's Markdown-first format requires almost no interpretation. This makes GOV-LSP a natural early adopter of LSAP once the protocol matures.

5. **The `diagnostic.data` design was the right call.** Both MCP and LSAP require the fix to be self-contained in the response. The existing schema (type, value) maps directly to both protocols without changes to the engine or the policy files.

---

## How LSP and LSAP Combine (Deep Dive)

This section answers the question: *can LSP and LSAP work together to deliver LSP errors/hints directly to agents?*

**Yes. They serve different layers of the same stack.**

```
┌───────────────────────────────────────────────────────────┐
│                    AI Agent (Claude Code, Copilot, etc.)   │
│  understands: natural language, Markdown, tool calls       │
└──────────────────────┬────────────────────────────────────┘
                       │ cognitive request
                       │ "check governance on this file"
                       ▼
┌───────────────────────────────────────────────────────────┐
│          LSAP Orchestration Layer / Agent Skill            │
│  translates cognitive request → sequence of LSP calls     │
│  reformats LSP response → Markdown report for LLM          │
│                                                           │
│  gov-lsp-skill (W-0014):  calls `gov-lsp check <file>`    │
│  LSAP endpoint (W-0013):  speaks LSAP protocol            │
└──────────────────────┬────────────────────────────────────┘
                       │ LSP protocol (JSON-RPC)
                       │ textDocument/didOpen
                       │ textDocument/publishDiagnostics
                       ▼
┌───────────────────────────────────────────────────────────┐
│              GOV-LSP (Language Server)                     │
│  evaluates Rego policies via OPA SDK                       │
│  returns Diagnostic{code, message, severity, data.fix}     │
└───────────────────────────────────────────────────────────┘
```

### The signal flow

**Path A — Editor (today, works)**
1. Editor sends `textDocument/didOpen` to GOV-LSP over stdio.
2. GOV-LSP evaluates policies and sends `textDocument/publishDiagnostics`.
3. Editor renders diagnostics in the Problems panel.
4. Copilot Agent reads the Problems panel and can act on the violations.

**Path B — CLI check (implemented, works)**
1. Agent or CI calls `gov-lsp check <file>` directly.
2. `check` runs the OPA engine and prints `text` or `json` output.
3. Agent reads output and applies fixes (rename, insert, delete).

**Path C — MCP (W-0012, ready to build)**
1. Agent calls `tools/call` → `check_file` on the `gov-lsp-mcp` binary.
2. `gov-lsp-mcp` calls `engine.Evaluate()` and returns structured JSON.
3. Agent parses the MCP response and applies fixes.

**Path D — Agent skill (W-0014, ready to build)**
1. Agent says "check governance on this file" → skill intercepts.
2. Skill calls `gov-lsp check <file>`.
3. Skill formats results as a Markdown policy report and returns it to the agent.

**Path E — LSAP (W-0013, future)**
1. LSAP client sends `check_policy` request to GOV-LSP.
2. GOV-LSP LSAP handler calls `engine.Evaluate()`.
3. LSAP handler formats violations as a Markdown document.
4. Agent receives one structured Markdown report.

### What does "combine" mean in practice?

The LSP server handles **real-time streaming evaluation** (editor-attached mode). LSAP/MCP/CLI handle **on-demand batch evaluation** (agent/CI mode). The `engine.Evaluate()` function is shared across all paths. Adding new transport layers does not require changing the policies or the violation schema.

The `diagnostic.data.fix` field is the universal fix representation — it means the same thing whether the consumer is an editor (reads it as a `WorkspaceEdit`), an agent (reads it as a rename instruction), an MCP client (reads it as JSON), or an LSAP client (reads it as a Markdown diff).

### Self-governance example

Running `gov-lsp check .` on this repo demonstrates all of this working end-to-end:

```bash
$ make check-policy
docs/getting-started.md: [markdown-naming-violation] Markdown file 'getting-started.md' must be SCREAMING_SNAKE_CASE
  Fix (rename): GETTING_STARTED.md
...
Checked 31 file(s). 11 violation(s) found.
```

An agent with W-0014 (gov-lsp-skill) installed would receive:

```markdown
# Policy Check: docs/getting-started.md

## ❌ Violations (1)

### markdown-naming-violation  
**Rule:** `governance.filenames`  
**Message:** Markdown file 'getting-started.md' must be SCREAMING_SNAKE_CASE  
**Fix:** Rename to `GETTING_STARTED.md`

---
*Checked 1 file. 1 violation found.*
```

No JSON parsing. No LSP client. No editor. The agent knows what to do.

---

## Backlog Items (proposed)

See `BACKLOG.md`:

**W-0013** (already added): LSAP cognitive endpoint — blocked on protocol stability.

**W-0014** (updated): `gov-lsp-skill` — agent skill for governance checks. **`gov-lsp check` is now implemented. Only SKILL.md needed.**

**W-0015** (added): VS Code extension — wraps the binary for in-editor diagnostics.

**W-0016** (added): GitHub Actions integration — `gov-lsp check` in CI, violations as PR comments.
