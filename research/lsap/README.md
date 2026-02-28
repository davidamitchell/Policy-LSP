# Research: LSAP — Language Server Agent Protocol

**Question:** Does the Language Server Agent Protocol (LSAP) help solve the gap between GOV-LSP's LSP interface and what AI coding agents need?

**Status:** Research complete. Recommendation and backlog item produced.

**Sources:**
- [LSAP GitHub](https://github.com/lsp-client/LSAP) — official spec and Python SDK (v1.0.0-alpha, MIT licence)
- [Designing LSAP](https://lsp-client.github.io/blog/designing-lsap/) — protocol design rationale
- [Agent Client Protocol](https://blog.promptlayer.com/agent-client-protocol-the-lsp-for-ai-coding-agents/) — ACP, a similar initiative by PromptLayer/Zed
- [LSP-AI](https://github.com/SilasMarvin/lsp-ai) — AI-powered language server as LSP backend
- [MCP Language Server](https://mcplane.com/mcp_servers/mcp-language) — proxy LSP features through MCP

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

2. **Add W-0013: LSAP cognitive endpoint.** Watch the LSAP spec stabilise (currently v1.0.0-alpha). When a Go-idiomatic path exists (the protocol schema is stable and a Go SDK or sufficient examples exist), implement a `check_policy` LSAP capability alongside the MCP tool. The engine call is identical; only the request/response shape differs.

3. **GOV-LSP is well-positioned.** Unlike `gopls` or a type-checker, GOV-LSP's output is already semantically rich — policy violation messages, severity, and fix suggestions are all natural language. Wrapping them in LSAP's Markdown-first format requires almost no interpretation. This makes GOV-LSP a natural early adopter of LSAP once the protocol matures.

4. **The `diagnostic.data` design was the right call.** Both MCP and LSAP require the fix to be self-contained in the response. The existing schema (type, value) maps directly to both protocols without changes to the engine or the policy files.

---

## Backlog Item (proposed)

See `BACKLOG.md` — add W-0013 once W-0012 is complete:

```
W-0013 | LSAP cognitive endpoint
Status: backlog (pending LSAP Go SDK or protocol stability)
Outcome: gov-lsp exposes a `check_policy` LSAP capability; any LSAP-aware agent can call it with a file path + contents and receive a Markdown policy report.
Depends on: W-0012 (engine already exposed), LSAP protocol reaching beta stability.
```
