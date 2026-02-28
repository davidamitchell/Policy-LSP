# Adding GOV-LSP to the Research Repo via Git Submodule

This guide walks through adding the `davidamitchell/Policy-LSP` binary as a git submodule in another repo (e.g., the Research repo), so the server source is pinned and auditable.

---

## Why a submodule instead of `go install`

| | Submodule | `go install` |
|---|---|---|
| Version pinning | ✅ exact commit | ❌ latest HEAD |
| Works offline | ✅ after init | ❌ needs network |
| Auditable in git history | ✅ submodule pointer | ❌ |
| CI-reproducible | ✅ | ❌ |
| Policy changes visible in PR | ✅ | ❌ |

---

## Step 1 — Add the submodule

In the root of the Research repo:

```bash
git submodule add https://github.com/davidamitchell/Policy-LSP.git tools/gov-lsp
git commit -m "chore: add gov-lsp as submodule at tools/gov-lsp"
```

This creates `tools/gov-lsp/` with the Policy-LSP source pinned to the current HEAD.

---

## Step 2 — Build the binary

Add a `Makefile` target (or script) that builds the binary:

```makefile
# Makefile
.PHONY: gov-lsp
gov-lsp: bin/gov-lsp

bin/gov-lsp: tools/gov-lsp/go.mod $(shell find tools/gov-lsp -name '*.go')
	mkdir -p bin
	cd tools/gov-lsp && go build -o ../../bin/gov-lsp ./cmd/gov-lsp

clean-gov-lsp:
	rm -f bin/gov-lsp
```

Or a simple shell script `scripts/build-gov-lsp.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../tools/gov-lsp"
go build -o ../../bin/gov-lsp ./cmd/gov-lsp
echo "gov-lsp built at bin/gov-lsp"
```

---

## Step 3 — Add project-specific policies

Create a `policies/` directory at the root of the Research repo. This is where the Research repo's own governance rules live — they are *not* inherited from the submodule.

```bash
mkdir -p policies
```

Minimal starter policy (copy and adapt):

```rego
# policies/filenames.rego
package governance.filenames

import future.keywords.if
import future.keywords.contains

# All markdown files must be SCREAMING_SNAKE_CASE
deny contains msg if {
    endswith(input.filename, ".md")
    name_root := trim_suffix(input.filename, ".md")
    not regex.match(`^[A-Z0-9_]+$`, name_root)
    msg := {
        "id":      "markdown-naming-violation",
        "message": sprintf("'%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
        "level":   "error",
        "fix": {
            "type":  "rename",
            "value": sprintf("%s.md", [upper(replace(name_root, "-", "_"))]),
        },
    }
}
```

---

## Step 4 — Configure your editor

**Neovim (`~/.config/nvim/after/plugin/gov_lsp.lua`):**

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.gov_lsp then
  configs.gov_lsp = {
    default_config = {
      cmd = function()
        local root = vim.fn.getcwd()
        return { root .. "/bin/gov-lsp", "--policies", root .. "/policies" }
      end,
      filetypes = { "markdown", "go", "python" },
      root_dir = lspconfig.util.root_pattern(".git"),
      settings = {},
    },
  }
end

lspconfig.gov_lsp.setup({})
```

**Zed (`~/.config/zed/settings.json`):**

```json
{
  "lsp": {
    "gov-lsp": {
      "binary": {
        "path": "./bin/gov-lsp",
        "arguments": ["--policies", "./policies"]
      }
    }
  },
  "languages": {
    "Markdown": { "language_servers": ["gov-lsp", "..."] }
  }
}
```

---

## Step 5 — Add `LSP.agent.md`

Copy `templates/LSP.agent.md` (from this research directory) to the root of the Research repo:

```bash
cp tools/gov-lsp/research/lsp-agent-integration/templates/LSP.agent.md LSP.agent.md
```

Update the Research repo's `.github/copilot-instructions.md` to reference it:

```markdown
# Copilot Instructions

All project instructions are in `AGENTS.md`.
LSP policy enforcement instructions are in `LSP.agent.md`.
Read both before starting any task.
```

And add a pointer in `AGENTS.md`:

```markdown
## Policy enforcement

This repo uses GOV-LSP for real-time policy feedback. Before completing any task,
read `LSP.agent.md` and verify no GOV-LSP diagnostics are present.
```

---

## Step 6 — Add to `.gitignore`

```gitignore
# Built binary
bin/gov-lsp
```

---

## Step 7 — CI integration (optional)

To fail CI on policy violations, add a step that builds the binary and runs the OPA CLI check:

```yaml
# .github/workflows/ci.yml
- name: Check policy violations
  run: |
    cd tools/gov-lsp && go build -o ../../bin/gov-lsp ./cmd/gov-lsp && cd ../..
    # Check all markdown files
    find . -name '*.md' -not -path './.git/*' -not -path './tools/*' | while read f; do
      filename=$(basename "$f")
      contents=$(cat "$f")
      result=$(echo "{\"filename\":\"$filename\",\"extension\":\".md\",\"path\":\"file://$f\",\"file_contents\":\"$contents\"}" \
        | opa eval -d policies/ --stdin-input 'count(data.governance[_].deny) > 0')
      if echo "$result" | grep -q '"result":true'; then
        echo "Policy violation in $f"
        exit 1
      fi
    done
```

> **Note:** This requires `opa` CLI on the CI runner. Alternatively, add an `eval` mode to GOV-LSP (backlog W-0012 covers this).

---

## Ongoing maintenance

When Policy-LSP ships a new version you want to adopt:

```bash
# In the Research repo
git submodule update --remote tools/gov-lsp
# Review what changed:
git -C tools/gov-lsp log --oneline HEAD@{1}..HEAD
# If happy:
git add tools/gov-lsp
git commit -m "chore: update gov-lsp to <new version>"
```

The submodule pointer is versioned, so the upgrade is visible in the PR diff and can be reverted if needed.
