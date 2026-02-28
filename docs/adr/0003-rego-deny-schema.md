# 0003. Rego Deny Rule Schema

Date: 2026-02-28
Status: accepted

## Context

The OPA SDK evaluates policies and returns results as untyped `interface{}` values at the Go boundary. The server needs a stable, documented contract for what a policy's `deny` rule must return so that:

1. Policy authors know exactly what fields to include.
2. The engine layer (`internal/engine/rego.go`) knows what to expect when deserialising the result.
3. The LSP handler (`internal/lsp/handlers.go`) knows where to find severity, position, and fix data.

The LSP `Diagnostic` type has well-defined fields (`range`, `severity`, `code`, `message`, `data`). The schema needs to map cleanly from Rego object → `Violation` struct → `Diagnostic`.

## Decision

Every element of a `deny` set must be a Rego object. Required fields:

| Field | Rego type | Purpose |
|---|---|---|
| `id` | `string` | Maps to `Diagnostic.code`. Stable across file changes; clients use it to identify violation type. |
| `message` | `string` | Maps to `Diagnostic.message`. Human-readable. |

Optional fields:

| Field | Rego type | Default | Purpose |
|---|---|---|---|
| `level` | `"error" \| "warning" \| "info"` | `"warning"` | Maps to `Diagnostic.severity` (1/2/3). |
| `location` | `{"line": number, "column": number}` | `{line: 1, column: 1}` | 1-based source position. Converted to 0-based in `handlers.go`. |
| `fix` | `{"type": string, "value": string}` | omitted | Carried in `Diagnostic.data`. `type` is `"rename" \| "insert" \| "delete"`. Used by CodeAction. |

The `deny` rule must be a **set** (not an array, not a single object). OPA set semantics deduplicate violations automatically.

All policies must use the `governance.*` package namespace and use `import future.keywords.if` + `import future.keywords.contains` for idiomatic v1-forward Rego.

## Consequences

**Easier:**
- Policy authors have a minimal required surface: `id` + `message` is enough for a valid violation. Additional fields are additive and optional.
- The `fix` field provides end-to-end data flow without requiring a separate CodeAction request: the fix payload arrives in the same `publishDiagnostics` notification, embedded in `Diagnostic.data`. The CodeAction handler (W-0003) only needs to read it back.
- Set semantics mean a policy cannot accidentally emit duplicate violations for the same condition.
- The schema is testable: a test that checks `violations[0].ID == "my-id"` is a complete contract test for the required fields.

**Harder:**
- The `level` → `severity` mapping is a lossy translation: Rego has three levels, LSP has four severities (Error, Warning, Information, Hint). `"info"` maps to Information (3); Hint (4) is not exposed. Any policy wanting Hint severity cannot express it currently.
- The `location` field is 1-based (Rego convention) but LSP requires 0-based. The conversion must happen exactly once, in `violationToDiagnostic()` in `handlers.go`, never in the engine or the policy.
- The `fix.type` enumeration (`"rename" \| "insert" \| "delete"`) is informal. The CodeAction handler is responsible for interpreting it; there is no schema validation at the OPA layer.

**Neutral:**
- Alternative considered: JSON Schema validation of the `deny` output inside the engine. Rejected because it adds a dependency and latency to the hot path. The contract is enforced by Go tests instead.
- Alternative considered: using OPA annotations (metadata blocks) to declare policy intent. Deferred — annotations are useful for policy documentation tooling but not required for the current evaluation loop.
