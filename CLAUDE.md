# GOV-LSP: Policy-Enforced Repository

This repository uses `gov-lsp` — a governance Language Server that evaluates every
file against Rego policies and reports violations. **Policy compliance is mandatory.**
Fix all violations before marking any task complete.

---

## How It Works Without an IDE

There is no editor mediating between you and the policies. Three mechanisms ensure you
are always aware of violations:

**1. LSP server (native, continuous)** — `.claude/lsp.json` registers `gov-lsp` as a
Language Server. When Claude Code opens or edits a file it sends `textDocument/didOpen`
and `textDocument/didChange` events to the server; the server responds with
`textDocument/publishDiagnostics` — the same structured violation stream an IDE
displays as red squiggles. No polling, no manual check, violations arrive
automatically on every edit.

**2. PostToolUse hook (automatic fallback)** — After every `Write`, `Edit`, or
`MultiEdit` call, `.claude/hooks/policy-gate.sh` runs `gov-lsp check` on the modified
file and surfaces any violations inline. If the hook exits 1, you have violations that
must be fixed before continuing. This layer is active even if the LSP server is not.

**3. MCP tool (explicit, on-demand)** — The `gov-lsp` MCP server is registered in
`.mcp.json`. You can call `gov_check_file` or `gov_check_workspace` at any point to
get a structured list of violations.

All three mechanisms use the same engine and the same Rego policies in `policies/`.

---

## Bootstrap

If `./gov-lsp` does not exist yet, build it first. The hook attempts this
automatically, but an explicit build avoids silent failures:

```
make build
```

The binary lands in the repository root. Both `scripts/lsp-start.sh` (LSP mode) and
`scripts/mcp-start.sh` (MCP mode) auto-build the binary on first run if it is absent.

---

## Responding to Violations

When you see policy violations — from the hook, MCP tool, or manual check — follow
this protocol:

1. Read the violation id and message in full.
2. Apply the `fix` value if one is provided (rename, insert, or delete as indicated).
3. Re-check the file: `./gov-lsp check --format text <path>`
4. Confirm zero violations before moving on.

Do not skip, ignore, or defer violations. They are blocking.

---

## Manual Checks

Check one file:
```
./gov-lsp check --format text <path>
```

Check the whole workspace:
```
./gov-lsp check --format text .
```

Check with structured output:
```
./gov-lsp check --format json .
```

Via Makefile:
```
make check-policy
```

---

## Current Policies

| Policy file | Package | What it enforces |
|---|---|---|
| `policies/filenames.rego` | `governance.filenames` | Markdown docs must use SCREAMING_SNAKE_CASE |
| `policies/security.rego` | `governance.security` | No hardcoded credentials or API keys |

To add a policy: create `policies/<name>.rego`, define a `deny` set rule in the
`governance.<name>` package, add a Go unit test in `internal/engine/rego_test.go`.
See `docs/policies.md` for the full schema.

---

## Architecture Context

This repo is self-governing: the same tool it ships is running against its own source.
Violations in `docs/` (lowercase markdown names) are intentional — they demonstrate
the policy in action. In a consumer repo these would all be real errors.

Full agent instructions are in `AGENTS.md`.
Project status is in `PROGRESS.md`.
Work backlog is in `BACKLOG.md`.
