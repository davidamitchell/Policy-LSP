# 0004. Policies as a Runtime Directory, Not Embedded in the Binary

Date: 2026-02-28
Status: accepted

## Context

The GOV-LSP binary needs access to Rego policy files to function. There are three broad approaches:

1. **Embedded** — compile policy files into the binary using `go:embed`. The binary is self-contained.
2. **Runtime directory** — load policy files from a filesystem path at startup. The binary is policy-agnostic.
3. **Remote bundle** — fetch a policy bundle from an OPA bundle server or HTTP endpoint at startup.

The design goals that bear on this decision are:
- The binary should be portable: copy it to any machine and it runs.
- Policies should be editable without recompiling the binary.
- Different projects should be able to ship their own policies alongside their repository.
- The common case is a developer or agent using the server with their project's own policies.

## Decision

**Runtime directory**, configurable via `--policies <dir>` CLI flag or `GOV_LSP_POLICIES` environment variable. The binary defaults to `<binary-dir>/policies/` so that a distributed tarball containing `gov-lsp` + `policies/` works out of the box.

The engine layer accepts either a filesystem path (`engine.New(dir string)`) or an `fs.FS` (`engine.NewFromFS(fsys fs.FS)`), the latter primarily for testing with `testing/fstest.MapFS`.

## Consequences

**Easier:**
- Project teams commit their policies to the repository. Policies are versioned, reviewed, and auditable alongside code.
- Adding, modifying, or removing a policy requires no recompile — only a server restart (or hot-reload once W-0004 is implemented).
- CI pipelines can ship a `policies/` directory specific to their governance requirements.
- Different workspaces can use different policies by pointing `--policies` or `GOV_LSP_POLICIES` at different directories.
- The `engine.NewFromFS` path allows hermetic unit tests using `testing/fstest.MapFS` without touching real files.

**Harder:**
- The binary alone is not self-sufficient: the user must also provide a `policies/` directory. The Docker image bundles them together, but the raw binary download requires a separate step.
- Startup will fail with a clear error if the directory is missing or empty (`no .rego files found in <dir>`). This is intentional but may surprise users who run the binary without reading the docs.
- Policy files must be present before the server starts; there is no dynamic "add policy" mechanism at runtime (see W-0004 for hot-reload).

**Neutral:**
- Alternative considered: `go:embed policies/*.rego`. Rejected because it would require teams to fork the binary to add project-specific rules, defeating the purpose of a shared policy sidecar.
- Alternative considered: OPA bundle server (remote fetch). Rejected for the initial implementation: adds a network dependency at startup and requires an OPA bundle service to be running. Could be added as a third mode in a future slice.
- The environment variable override (`GOV_LSP_POLICIES`) was added alongside the flag to make MCP tool configurations cleaner — passing `env` to an MCP server is more natural than constructing `args` dynamically.
