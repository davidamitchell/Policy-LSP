# PIV Testing — Policy Integration Verification

This document describes how to verify that `gov-lsp` policy enforcement
is working end-to-end in a new Claude Code session (or GitHub Copilot Agent
session) started from the iOS app or any other no-IDE trigger.

---

## What "Working" Looks Like

When fully operational, creating a file that violates a policy produces an
inline error in Claude's context **without Claude asking for it**. The agent
sees something like:

```
=== GOV-LSP POLICY VIOLATIONS ===
File: /path/to/bad-name.md

/path/to/bad-name.md: [markdown-naming-violation] File must use SCREAMING_SNAKE_CASE
  Fix (rename): BAD_NAME.md

Checked 1 file(s). 1 violation(s) found.

Fix these violations before completing this task.
```

This is exit code 1 from `.claude/hooks/policy-gate.sh`, fed back to Claude
by the PostToolUse hook infrastructure. Claude must fix the violation before
proceeding — exactly like IDE red squiggles but in the agent loop.

---

## Prerequisite: Binary Must Exist

The hook fails open (silently) when `./gov-lsp` is absent. Before PIV testing:

```bash
make build          # builds ./gov-lsp from source
# or
make setup          # builds + runs a quick self-check
```

In a Codespace or devcontainer this happens automatically via `postCreateCommand`.
In CI, `copilot-setup-steps.yml` handles it.

---

## Prompt to Use for PIV Testing

Paste this as your opening message in a **fresh** Claude Code session started
in this repository:

```
You are working in the Policy-LSP repo. Read CLAUDE.md first.

To verify that policy enforcement is working, do the following in order:

1. Run `make build` to ensure the gov-lsp binary exists.
2. Use the Write tool to create a file called `test-violation.md` at the
   repo root with any markdown content.
3. Report exactly what happened after the Write — did you see a policy
   violation message? What was the exit code? What did the hook output?
4. Now rename/move it to `TEST_VIOLATION.md` (or delete it).
5. Confirm that no violation appears for the renamed file.
6. Run `./gov-lsp check --format text .` and report the output.
7. Call the MCP tool gov_check_file with path="./PROGRESS.md" and report
   what violations (if any) are returned.

Log the full results of each step.
```

---

## What to Expect at Each Step

### Step 1 — `make build`
- Go downloads dependencies and compiles `./gov-lsp`
- Output: `go build -o gov-lsp ./cmd/gov-lsp`
- Binary exists at `./gov-lsp` (exit 0)

### Step 2 — Write `test-violation.md`
- Write tool creates the file
- **PostToolUse hook fires immediately after Write returns**
- Claude sees inline output (exit 1 from the hook):

```
=== GOV-LSP POLICY VIOLATIONS ===
File: /path/to/test-violation.md

test-violation.md: [markdown-naming-violation] File must use SCREAMING_SNAKE_CASE
  Fix (rename): TEST_VIOLATION.md

Fix these violations before completing this task.
```

- If Claude does NOT see this output: the hook is not active for this session.
  This happens when `.claude/settings.json` was created *during* the session
  rather than before it started. Start a new session and retry.

### Step 3 — Report
- Claude should describe: "I saw a policy violation from gov-lsp after the
  Write. The hook exited 1. The violation id is markdown-naming-violation
  and the fix suggests renaming to TEST_VIOLATION.md."
- If Claude says "no violation appeared": the hook is not active (see Step 2).

### Step 4 — Rename to `TEST_VIOLATION.md`
- Either delete `test-violation.md` or rename it
- Write the new file `TEST_VIOLATION.md`
- **Hook fires again**, this time exit 0 (no violations)
- No inline violation message — the file is compliant

### Step 5 — Confirm no violation for renamed file
- Claude should report: "No violation appeared after writing TEST_VIOLATION.md"

### Step 6 — `gov-lsp check --format text .`
- Scans the whole workspace
- Output includes violations for intentional demo files in `docs/` (lowercase
  markdown names — these are expected, they demonstrate the policy)
- Example output:

```
docs/getting-started.md: [markdown-naming-violation] ...
  Fix (rename): GETTING_STARTED.md
...
Checked N file(s). N violation(s) found.
```

- Exit code 1 (violations exist)
- `TEST_VIOLATION.md` should NOT appear in the output

### Step 7 — MCP `gov_check_file`
- `PROGRESS.md` is SCREAMING_SNAKE_CASE — should return "No violations"
- If `PROGRESS.md` had a lowercase name it would appear here
- MCP tool returns:

```json
{
  "content": [{"type": "text", "text": "No violations in ./PROGRESS.md"}],
  "isError": false
}
```

---

## Pass / Fail Criteria

| Check | Pass | Fail |
|---|---|---|
| Hook fires on lowercase .md Write | Violation message inline, exit 1 | No message (hook not active) |
| Hook silent on SCREAMING_SNAKE.md Write | No violation message | Violation fires incorrectly |
| gov-lsp check on workspace | Exit 1, docs/ violations listed | Binary not found / crashes |
| MCP gov_check_file on clean file | "No violations" response | Error response |
| MCP gov_check_file on violating file | Violation + message | No violation (false negative) |

---

## Known Limitations in This Sandbox

This sandbox environment cannot build the real `gov-lsp` binary because
`github.com/open-policy-agent/opa` Go module source is not in the local
module cache and there is no network. Specific limitations:

- `make build` will fail in the sandbox
- The hook will fail-open (no violations surfaced)
- A **Codespace**, **devcontainer**, or any machine with network access will
  build cleanly and pass all PIV steps

The Rego policies themselves have been verified with OPA v0.70.0 (10/10 live
tests pass). The hook script has been verified with a mock binary (6/6 tests
pass). CI (`ci.yml`) runs the full build and test suite on push.

---

## Session Log: 2026-03-01 (Reference)

The session that built this system ran the following actual tests:

**Hook layer (mock binary, 6/6 pass):**
- Write lowercase .md → hook exits 1, violation message displayed
- Write SCREAMING_SNAKE_CASE .md → hook exits 0, no message
- Edit .go file → hook exits 0, no message
- Missing file_path in stdin → hook exits 0 (fail-open)
- Garbage JSON input → hook exits 0 (fail-open)
- Dash-named .md → hook exits 1, fix suggestion shows underscore form

**OPA Rego layer (real OPA v0.70.0, 10/10 pass):**
- `filenames.rego` deny fires on `getting-started.md`, fix = `GETTING_STARTED.md`
- `filenames.rego` does not fire on `GETTING_STARTED.md`
- `filenames.rego` does not fire on `main.go`
- `filenames.rego` fix converts dashes: `my-policy.md` → `MY_POLICY.md`
- `security.rego` fires on `api_key = "sk-abcdef..."` (20+ char value)
- `security.rego` fires on `password = "hunter2_this_is_very_long_password"`
- `security.rego` does not fire on `api_key = os.Getenv("API_KEY")`
- `security.rego` does not fire on `api_key = "short"` (< 20 chars)
- `security.rego` excludes `_test.go` files
- `security.rego` excludes `go.sum` file

**Honest gap: hook NOT active in the build session itself**
- `.claude/settings.json` was created during the session, not before it
- When the Write tool created `test-violation.md` no hook fired inline
- Manual invocation of the hook on that file produced the expected exit 1
- In any fresh session starting AFTER this commit, the hook is active

---

## What a Full-Pass PIV Run Proves

1. The binary builds cleanly from source
2. The Rego policies evaluate correctly via the Go OPA SDK
3. Claude Code's PostToolUse hook fires on every file write
4. The hook correctly surfaces violations inline in the agent context
5. Compliant files produce no false positives
6. The MCP server initializes and responds correctly to tool calls
7. The `gov-lsp check` CLI produces correct exit codes for CI use
