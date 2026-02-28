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

## Claude Code (MCP)

Add GOV-LSP as an MCP tool so Claude can check file compliance during a session.

In your project's `.mcp.json` (or `~/.config/claude/mcp.json`):

```json
{
  "mcpServers": {
    "gov-lsp": {
      "command": "/path/to/gov-lsp",
      "args": ["--policies", "/path/to/policies"],
      "env": {
        "GOV_LSP_POLICIES": "/path/to/policies"
      }
    }
  }
}
```

Once connected, Claude will surface violations as tool results when opening or editing files. Example prompt: *"Check this file against the governance policies"* — Claude will see the diagnostics in its tool output and can apply fixes.

**Using the workspace policies automatically:**

If your project ships policies in a `policies/` directory at the repo root, Claude Code respects the `.mcp.json` in the workspace root, so policies are always project-specific.

---

## GitHub Copilot Agent (Workspace)

Add to `.github/mcp.json`:

```json
{
  "mcpServers": {
    "gov-lsp": {
      "type": "stdio",
      "command": "/path/to/gov-lsp",
      "args": ["--policies", "${workspaceFolder}/policies"]
    }
  }
}
```

Copilot Agent will include GOV-LSP diagnostics when editing files in the workspace. The `data` field on each diagnostic carries the fix payload that Copilot can apply via `workspace/applyEdit`.

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
