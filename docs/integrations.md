# Editor and Agent Integrations

GOV-LSP communicates over stdio using the standard LSP `Content-Length` framing, so any LSP-aware client can use it. This page covers setup for the most common editors and AI agents.

---

## VSCode

VSCode requires an extension to connect to an arbitrary stdio LSP server. The recommended approach is a minimal custom extension using the [`vscode-languageclient`](https://www.npmjs.com/package/vscode-languageclient) package from Microsoft.

See the [VSCode Language Server Extension Guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide) for the full boilerplate. The relevant `serverOptions` block:

```ts
const serverOptions: ServerOptions = {
  command: "/path/to/gov-lsp",
  args: ["--policies", "/path/to/policies"],
  options: { env: { ...process.env } },
};
```

The extension can be placed in `.vscode/extensions/` and loaded via `--extensionDevelopmentPath` for project-local use without publishing to the marketplace.


---

## Neovim (nvim-lspconfig)

```lua
-- ~/.config/nvim/after/plugin/gov_lsp.lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.gov_lsp then
  configs.gov_lsp = {
    default_config = {
      cmd = {
        "/path/to/gov-lsp",
        "--policies", vim.fn.expand("~/.config/gov-lsp/policies"),
      },
      filetypes = { "markdown", "go", "python", "javascript", "typescript" },
      root_dir = lspconfig.util.root_pattern(".git", "go.mod"),
      settings = {},
    },
  }
end

lspconfig.gov_lsp.setup({
  on_attach = function(_, bufnr)
    -- Optional: show virtual text for diagnostics
    vim.diagnostic.config({ virtual_text = true }, vim.lsp.diagnostic.get_namespace(0))
  end,
})
```

To use a project-local policy directory:

```lua
root_dir = function(fname)
  local root = lspconfig.util.root_pattern(".git")(fname)
  return root
end,
cmd = function()
  local cwd = vim.fn.getcwd()
  local policies = cwd .. "/policies"
  return { "/path/to/gov-lsp", "--policies", policies }
end,
```

---

## Zed

Zed uses a `~/.config/zed/settings.json` LSP configuration. Add a custom language server:

```json
{
  "lsp": {
    "gov-lsp": {
      "binary": {
        "path": "/path/to/gov-lsp",
        "arguments": ["--policies", "/path/to/policies"]
      }
    }
  },
  "languages": {
    "Markdown": {
      "language_servers": ["gov-lsp", "..."]
    }
  }
}
```

---

## Claude Code

> **Note:** GOV-LSP is an LSP server, not an MCP server. Direct `mcpServers` connection is not currently supported — that requires the MCP wrapper in backlog W-0012. The integration described here uses Claude Code's native filesystem tools to call the engine indirectly.

**What works today — invoke via CLI in a Claude session:**

Claude Code can evaluate files directly by running the binary with the OPA CLI:

```bash
# Build first
go build -o /usr/local/bin/gov-lsp ./cmd/gov-lsp

# Evaluate a file using the OPA CLI directly against the policies
opa eval \
  -d /path/to/policies \
  --input /dev/stdin \
  'data.governance[_].deny' <<'EOF'
{"filename":"lower_case.md","extension":".md","path":"file:///ws/lower_case.md","file_contents":"# hello"}
EOF
```

**Planned integration (W-0012):** Once the MCP wrapper is built, you will add it to `.mcp.json`:

```json
{
  "mcpServers": {
    "gov-lsp": {
      "command": "/path/to/gov-lsp-mcp",
      "args": ["--policies", "/path/to/policies"]
    }
  }
}
```

The MCP wrapper (`gov-lsp-mcp`) will expose a `check_file` tool that accepts `{path, contents}` and returns a list of violations — without going through the LSP protocol.

---

## GitHub Copilot Agent

> **Note:** GOV-LSP is an LSP server, not an MCP server. Listing `gov-lsp` in an `mcpServers` block will not work — the binary speaks LSP protocol, not MCP `tools/call` protocol. The MCP wrapper in backlog W-0012 will solve this.

**What works today — Copilot reads LSP diagnostics from the VSCode Problems panel:**

When GOV-LSP is running as a VSCode extension (see [VSCode section above](#vscode)), GitHub Copilot Agent in VSCode can read the Problems panel diagnostics and incorporate them into its edits. You don't need MCP for this — Copilot already sees all LSP diagnostics from installed extensions.

Workflow:
1. Build and install the VSCode extension wrapper (see [VSCode](#vscode))
2. Open the project in VSCode — GOV-LSP starts automatically and populates the Problems panel
3. In Copilot Agent chat: *"Fix the policy violations shown in the Problems panel"*
4. Copilot reads the diagnostics (including `data.value` for suggested renames) and can apply the fixes

**Planned integration (W-0012):** Once the MCP wrapper is built, it can be added to `.github/mcp.json`:

```json
{
  "mcpServers": {
    "gov-lsp": {
      "type": "stdio",
      "command": "/path/to/gov-lsp-mcp",
      "args": ["--policies", "${workspaceFolder}/policies"]
    }
  }
}
```

This will let Copilot Agent call `check_file` as a tool during agentic sessions outside of an editor context.

---

## Docker sidecar (CI / remote agents)

```bash
# Build the image
docker build -t gov-lsp:local .

# Run with external policies
docker run --rm -i \
  -v /your/project/policies:/policies:ro \
  gov-lsp:local

# Or pass the policies dir as an arg
docker run --rm -i \
  -v /your/project:/workspace:ro \
  gov-lsp:local --policies /workspace/policies
```

The image uses a `scratch` base and the binary is fully static (`CGO_ENABLED=0`), so it can be embedded in any Docker-based CI pipeline.

---

## Testing the connection

After connecting any client, open a file named `lower_case.md`. You should see:

- A red underline on line 1
- Message: `'lower_case.md' must be SCREAMING_SNAKE_CASE`
- Quick-fix: `Rename to LOWER_CASE.md`

If no diagnostic appears, check:
1. The `--policies` directory exists and contains `.rego` files
2. The server process started without error (check editor logs / stderr)
3. The server received an `initialize` request (some editors delay this)
