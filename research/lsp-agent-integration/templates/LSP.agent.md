# GOV-LSP Policy Enforcement — Agent Instructions

This file supplements the main `AGENTS.md` for the Research repo. It tells AI coding agents (GitHub Copilot, Claude Code) how to work with the GOV-LSP policy server that runs alongside this workspace.

---

## What GOV-LSP does

GOV-LSP is a Language Server Protocol (LSP) server running as a sidecar to your editor or agentic session. It evaluates every file you open or save against the Rego policies in `policies/`. Violations appear as LSP Diagnostics — the same kind your editor shows for type errors or lint warnings.

The binary is built from the `tools/gov-lsp/` submodule in this repo. Policies are in `policies/` (this repo owns them; they are not shared with the GOV-LSP upstream).

---

## Non-negotiable: check diagnostics before declaring done

Before marking any task complete, check for GOV-LSP policy violations:

**In VSCode (Copilot Agent):** Open the Problems panel (`Ctrl+Shift+M`). Filter by source `gov-lsp`. Any entry here is a policy violation that must be resolved before the task is done.

**In Neovim:** Run `:lua vim.diagnostic.setqflist()` to see all diagnostics from all LSP servers. Look for entries tagged with `gov-lsp`.

**Programmatically (Claude Code):** Use the OPA CLI directly:

```bash
opa eval \
  -d policies/ \
  --input /dev/stdin \
  'data.governance[_].deny' <<EOF
{"filename":"<filename>","extension":".<ext>","path":"<uri>","file_contents":"<contents>"}
EOF
```

---

## How to interpret a violation

Each violation has:

- `message` — plain-English description of what is wrong
- `code` — machine-readable rule ID (e.g., `markdown-naming-violation`)
- `data.type` — fix type: `rename`, `insert`, or `delete`
- `data.value` — the corrected value (e.g., the correct filename for a rename)

Example:

```json
{
  "severity": 1,
  "code": "markdown-naming-violation",
  "message": "'lower_case.md' must be SCREAMING_SNAKE_CASE",
  "data": { "type": "rename", "value": "LOWER_CASE.md" }
}
```

The `data.value` field is the answer. Apply it directly. Do not guess or improvise.

---

## How to apply a fix

For `"type": "rename"`: rename the file using `data.value` as the new filename. The path prefix stays the same; only the filename changes.

```bash
# Example: diagnostic says rename lower_case.md to LOWER_CASE.md
git mv docs/lower_case.md docs/LOWER_CASE.md
```

After renaming, update all references to the file (links in markdown, imports, etc.) before committing.

For `"type": "insert"`: the `data.value` is a string to insert at the location specified by the diagnostic range.

For `"type": "delete"`: remove the content at the diagnostic range.

---

## Policy rules in force

Policies are in `policies/`. Each `.rego` file is a self-contained rule set. Before starting work on a new file type or domain, check whether a policy applies.

Current policies:

| File | Rule | Applies to |
|---|---|---|
| `policies/filenames.rego` | `.md` files must be `SCREAMING_SNAKE_CASE` | All markdown files |

Add new policies for this repo in `policies/`. Follow the schema in [GOV-LSP docs/policies.md](tools/gov-lsp/docs/policies.md).

---

## When a violation cannot be fixed automatically

If you encounter a violation you cannot resolve with the `data.value` fix:

1. Do not suppress the diagnostic.
2. Explain the conflict in a comment in your PR.
3. Tag it with `TODO(policy): <reason>` in the source so it is visible in code review.

Suppressions require a human decision, not an AI one.

---

## Starting GOV-LSP

GOV-LSP must be running to produce diagnostics. It starts automatically if your editor is configured (see setup below). If it is not running, diagnostics will be absent and you may miss violations.

```bash
# Build the binary (one-time, or after submodule update)
cd tools/gov-lsp && go build -o ../../bin/gov-lsp ./cmd/gov-lsp && cd ../..

# Start manually (stdio — for debugging)
GOV_LSP_POLICIES=./policies ./bin/gov-lsp
```

**VSCode:** Install the workspace extension from `.vscode/extensions/gov-lsp/` (see setup guide).

**Neovim:** Add the config from `tools/gov-lsp/docs/integrations.md` to your init.

---

## Submodule maintenance

The GOV-LSP binary comes from the `tools/gov-lsp/` submodule. To initialise after cloning:

```bash
git submodule update --init --recursive
```

To update to a newer version of GOV-LSP:

```bash
git submodule update --remote tools/gov-lsp
git add tools/gov-lsp
git commit -m "chore: update gov-lsp to latest"
```

Do not update the submodule without reviewing the upstream CHANGELOG — a newer version may add new policies or change violation IDs.
