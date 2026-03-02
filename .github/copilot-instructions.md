# Copilot Instructions

All project instructions, coding standards, working methodology, and conventions
are in [`AGENTS.md`](../AGENTS.md) at the repository root. Read that file for the
full context before starting any task.

---

## Policy Enforcement

This repository uses `gov-lsp` to enforce governance policies defined as Rego rules.
**Policy compliance is mandatory.** Fix all violations before submitting changes.

### During Your Session

The `copilot-setup-steps.yml` workflow builds `gov-lsp` and places it on PATH before
your session starts. Use it to check compliance at any time:

```bash
# Check the whole workspace
gov-lsp check --format text .

# Check a specific file
gov-lsp check --format text <path>

# Get structured output for programmatic processing
gov-lsp check --format json .
```

Exit code 0 means clean. Exit code 1 means violations exist and must be fixed.

### Violation Response Protocol

1. Read the violation `id` and `message` in full.
2. Apply the `fix` value if one is provided (rename / insert / delete as indicated).
3. Re-check the file to confirm zero violations.
4. Never submit a PR with known policy violations.

### Available Policies

| Policy | Package | Enforces |
|---|---|---|
| `policies/filenames.rego` | `governance.filenames` | Markdown files must use SCREAMING_SNAKE_CASE |
| `policies/security.rego` | `governance.security` | No hardcoded credentials or API keys |

### Adding Policies

Create `policies/<name>.rego` in the `governance.<name>` package. Define a `deny`
set rule. Add Go unit tests in `internal/engine/rego_test.go`. See
`docs/policies.md` for the full schema and examples.
