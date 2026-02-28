# GOV-LSP

A portable governance Language Server that enforces project policies — defined as [OPA Rego](https://www.openpolicyagent.org/) rules — against any file your editor opens. Violations appear as real-time diagnostics with one-click fix suggestions, the same way a linter or type checker would.

## What it does

- Loads `.rego` policy files from a directory at startup (no recompile needed to add rules)
- Evaluates every open file against all loaded policies when you open or edit it
- Publishes `textDocument/publishDiagnostics` notifications so any LSP-aware editor shows errors and warnings inline
- Carries fix metadata (e.g. a suggested rename) in the `Diagnostic.data` field so editors can offer CodeAction quick-fixes

## Quick start

**Prerequisites:** Go 1.24+ or Docker.

```bash
# Build the binary
go build -o gov-lsp ./cmd/gov-lsp

# Run against the bundled policies
GOV_LSP_POLICIES=./policies ./gov-lsp
```

The server reads JSON-RPC from **stdin** and writes to **stdout** using the standard LSP `Content-Length` framing. Point any LSP client at it.

## Editor integration

### VSCode

VSCode requires a custom extension to connect to an arbitrary stdio LSP server. Create a minimal extension using the [`vscode-languageclient`](https://www.npmjs.com/package/vscode-languageclient) package — see the [VSCode Language Server Extension Guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide) for the full boilerplate:

```ts
const serverOptions: ServerOptions = {
  command: "/path/to/gov-lsp",
  args: ["--policies", "${workspaceFolder}/policies"],
};
```

### Neovim (nvim-lspconfig)

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.gov_lsp then
  configs.gov_lsp = {
    default_config = {
      cmd = { "/path/to/gov-lsp", "--policies", "/path/to/policies" },
      filetypes = { "markdown", "go", "python" },
      root_dir = lspconfig.util.root_pattern(".git"),
      settings = {},
    },
  }
end

lspconfig.gov_lsp.setup({})
```

### Claude Code

> GOV-LSP is an LSP server, not an MCP server. Direct `mcpServers` connection requires the MCP wrapper in backlog **W-0012** (not yet built). See [`docs/integrations.md`](docs/integrations.md) for the current workaround.

### GitHub Copilot Agent

> Same caveat as Claude Code — direct MCP connection requires W-0012. **What works today:** run GOV-LSP as a VSCode extension; Copilot Agent reads diagnostics from the Problems panel without any MCP config. See [`docs/integrations.md`](docs/integrations.md).

### Docker sidecar

```bash
docker run --rm -i \
  -v /your/policies:/policies:ro \
  ghcr.io/davidamitchell/gov-lsp:latest
```

## Configuration

| Method | Example |
|---|---|
| CLI flag | `gov-lsp --policies ./policies` |
| Environment variable | `GOV_LSP_POLICIES=./policies gov-lsp` |
| Binary-relative default | `<binary-dir>/policies/` |

## Writing a policy

Create `policies/my_rule.rego`:

```rego
package governance.my_rule

import future.keywords.if
import future.keywords.contains

deny contains msg if {
    endswith(input.filename, ".md")
    not regex.match(`^[A-Z0-9_]+$`, trim_suffix(input.filename, ".md"))
    msg := {
        "id":      "markdown-naming-violation",
        "level":   "error",
        "message": sprintf("'%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
        "fix":     {"type": "rename", "value": upper(input.filename)},
    }
}
```

Every policy receives `input` with four fields:

| Field | Description |
|---|---|
| `input.filename` | Base filename (e.g. `README.md`) |
| `input.extension` | File extension (e.g. `.md`) |
| `input.path` | Full URI (e.g. `file:///workspace/README.md`) |
| `input.file_contents` | Full text content of the file |

See [`docs/policies.md`](docs/policies.md) for the complete deny rule schema and testing guide.

## Documentation

| Guide | Contents |
|---|---|
| [`docs/getting-started.md`](docs/getting-started.md) | Build, run, verify |
| [`docs/policies.md`](docs/policies.md) | Writing, testing, and deploying policies |
| [`docs/integrations.md`](docs/integrations.md) | VSCode, Neovim, Zed, Claude Code, Copilot |
| [`docs/development.md`](docs/development.md) | Contributing, testing, building from source |
| [`docs/mcp-and-skills.md`](docs/mcp-and-skills.md) | MCP configuration and agent skills |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records |

## Repository layout

```
cmd/gov-lsp/main.go        # stdio JSON-RPC loop, CLI flags
internal/engine/rego.go    # OPA SDK wrapper
internal/lsp/handlers.go   # LSP method dispatch + diagnostic mapping
policies/                  # Rego policy files (hot-swappable)
docs/                      # Human-facing documentation
scripts/smoke_test.sh      # End-to-end integration test
Dockerfile                 # Multi-stage static build → scratch image
```

## License

MIT
