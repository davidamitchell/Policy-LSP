# Development Guide

This guide covers building from source, running tests, contributing changes, and managing the project backlog.

---

## Prerequisites

- Go 1.24+ (`go version` to check)
- `git` with submodule support
- `bash` (for smoke test and scripts)

Optional:
- Docker (for container builds and sidecar testing)
- OPA CLI (for interactive Rego development)

---

## Build

```bash
# Build binary using Make (preferred)
make build

# Or directly with go
go build -o gov-lsp ./cmd/gov-lsp

# Or install to $GOPATH/bin
go install ./cmd/gov-lsp

# Verify — shows both the server mode and check subcommand
./gov-lsp --help
```

### Available Make targets

```bash
make help          # print all available targets
make build         # compile gov-lsp binary
make test          # run all unit tests
make vet           # run go vet
make smoke         # build + run end-to-end smoke test
make check-policy  # batch policy check against the whole repo (self-governance demo)
make clean         # remove built binary
```

### Static binary (for distribution)

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags="-s -w" -o gov-lsp-linux-amd64 ./cmd/gov-lsp
```

---

## CLI modes

GOV-LSP has two operating modes in the same binary:

### Server mode (default)
```bash
# Start the LSP server — reads JSON-RPC from stdin, writes to stdout
gov-lsp [--policies <dir>]
```
Used by editor extensions and LSP clients.

### Check mode (batch)
```bash
# Evaluate all files under the given paths and print violations
gov-lsp check [--policies <dir>] [--format text|json] [path...]
```
Used for CI pipelines, agent scripts, and manual spot-checks. Exit code: `0` = clean, `1` = violations found.

```bash
# Example: check the whole repo
GOV_LSP_POLICIES=./policies ./gov-lsp check .

# JSON output (same schema as Diagnostic.data — machine-readable)
GOV_LSP_POLICIES=./policies ./gov-lsp check --format json ./docs
```

---

## Test

```bash
# Unit tests
go test ./...

# With race detector (matches CI)
go test -race -count=1 ./...

# Single package
go test ./internal/engine/...

# Verbose output
go test -v ./...
```

### Smoke test (integration)

The smoke test builds the binary, starts the server, sends a synthetic LSP session, and asserts the expected diagnostic is returned:

```bash
go build -o /tmp/gov-lsp ./cmd/gov-lsp
GOV_LSP_POLICIES=./policies bash scripts/smoke_test.sh /tmp/gov-lsp
```

---

## Code quality

```bash
# Format
gofmt -l -w .

# Vet
go vet ./...
```

Both are required to pass before a commit is merged. CI enforces this on every push.

---

## CI workflow

`.github/workflows/ci.yml` runs on every push and PR:

1. `go mod verify` — dependency integrity
2. `go build ./...` — compile check
3. `go vet ./...` — static analysis
4. `go test -race -count=1 ./...` — unit tests with race detector
5. Smoke test — end-to-end against a real built binary

---

## Project layout reference

```
cmd/gov-lsp/main.go        # Entry point: CLI flags, Content-Length framing, JSON-RPC loop
internal/
├── engine/
│   ├── rego.go            # OPA SDK wrapper: New(), NewFromFS(), Evaluate()
│   └── rego_test.go       # Policy unit tests (table-driven)
└── lsp/
    └── handlers.go        # LSP method dispatch + violation→diagnostic mapping
policies/                  # Rego files loaded at runtime
docs/                      # Human documentation
scripts/
└── smoke_test.sh          # End-to-end integration test
Dockerfile                 # Multi-stage → scratch static image
```

---

## Adding a new LSP method

1. Add a `case` to `Handle()` in `internal/lsp/handlers.go`.
2. Write unit tests using a mock `Publisher` — no real server process needed.
3. If the method changes capabilities, update `InitializeResult.Capabilities`.
4. If the decision involves a significant trade-off, write an ADR in `docs/adr/`.
5. Update `BACKLOG.md` (mark the slice done) and `PROGRESS.md`.

---

## Adding a new policy

See [`docs/policies.md`](policies.md) for the complete authoring guide.

Short version:

1. `policies/<name>.rego` — `package governance.<name>`, `deny` set rule
2. Tests in `internal/engine/rego_test.go`
3. `go test ./...` and smoke test pass
4. Update `BACKLOG.md` and `PROGRESS.md`

---

## Architecture Decision Records

Significant decisions are documented as ADRs in `docs/adr/`. Follow the MADR format:

```
docs/adr/NNNN-short-title.md
```

Zero-padded 4-digit ID, increment from the last entry. Update `docs/adr/README.md` after adding.

An ADR **must** be written for:
- A new external dependency or major version bump
- A change to the transport layer or OPA evaluation architecture
- Any protocol-level decision that would be expensive to reverse

---

## Managing the backlog

The backlog lives in `BACKLOG.md`. Use the `backlog-manager` skill (via the MCP tools) to add and manage items.

```
# From Claude Code or Copilot:
Add: <description of the outcome you want>
List
Next
Start W-XXXX
Complete W-XXXX
```

Each item needs:
- A clear, observable **Outcome** (not a task list)
- A **Context** section explaining why it matters
- `status: ready` (or `needing_refinement` if the outcome isn't sharp yet)

See [`docs/mcp-and-skills.md`](mcp-and-skills.md) for the full skills reference.

---

## Making a release

Releases are manual until W-0010 (release workflow) is implemented. To cut a release:

```bash
# Build for all targets
for GOOS in linux darwin; do
  for GOARCH in amd64 arm64; do
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH \
      go build -ldflags="-s -w" \
      -o "dist/gov-lsp-${GOOS}-${GOARCH}" ./cmd/gov-lsp
  done
done

# Tag and push
git tag v0.x.0
git push origin v0.x.0
```
