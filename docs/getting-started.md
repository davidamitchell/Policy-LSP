# Getting Started

This guide covers everything needed to build, run, and verify GOV-LSP from scratch.

---

## Prerequisites

- **Go 1.24+** — `go version` must report `go1.24` or later
- **Git** — for cloning and submodule management
- **bash** — for the smoke test

Optional:
- **Docker** — for the container build
- **OPA CLI** (`brew install opa` / `go install github.com/open-policy-agent/opa@latest`) — useful for iterating on Rego rules

---

## Clone and build

```bash
git clone https://github.com/davidamitchell/Policy-LSP.git
cd Policy-LSP

# Build the binary
go build -o gov-lsp ./cmd/gov-lsp

# Verify it starts
GOV_LSP_POLICIES=./policies ./gov-lsp --help
```

---

## Verify with the smoke test

The smoke test pipes a synthetic LSP session through the binary and asserts that the expected diagnostic is returned:

```bash
GOV_LSP_POLICIES=./policies bash scripts/smoke_test.sh ./gov-lsp
```

Expected output:

```
=== Server output ===
Content-Length: 79

{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1,...}}}
Content-Length: ...

{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspace/lower_case.md","diagnostics":[...]}}
...
=====================
PASS: smoke test succeeded - LSP returned expected Diagnostic with SCREAMING_SNAKE_CASE fix
```

---

## Run the unit tests

```bash
go test ./...
```

All tests are hermetic — no network access, no file I/O outside the test.

```bash
# With race detector (CI default)
go test -race -count=1 ./...
```

---

## Build with Docker

```bash
docker build -t gov-lsp:local .

# Run as a sidecar (piping stdio)
docker run --rm -i \
  -v /your/policies:/policies:ro \
  gov-lsp:local
```

The image is built on `scratch` with `CGO_ENABLED=0`, producing a ~20 MB static binary image.

---

## Your first policy

1. Create `policies/my_first_rule.rego`:

   ```rego
   package governance.my_first_rule

   import future.keywords.if
   import future.keywords.contains

   # Flag any .go file that is empty
   deny contains msg if {
       input.extension == ".go"
       input.file_contents == ""
       msg := {
           "id":      "empty-go-file",
           "level":   "warning",
           "message": sprintf("'%s' is empty", [input.filename]),
       }
   }
   ```

2. Restart `gov-lsp` (or wait for hot-reload once W-0004 is implemented).

3. Open an empty `.go` file in your editor — the warning appears inline.

4. Add a Go test in `internal/engine/rego_test.go`:

   ```go
   func TestEvaluate_EmptyGoFile_ReturnsViolation(t *testing.T) {
       eng, err := engine.New(policyDir(t))
       // ...
   }
   ```

See [`docs/policies.md`](policies.md) for the complete policy authoring guide.

---

## Next steps

- Connect to your editor: [`docs/integrations.md`](integrations.md)
- Write and test policies: [`docs/policies.md`](policies.md)
- Contribute to the server: [`docs/development.md`](development.md)
