# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the GOV-LSP project, following the [MADR format](https://adr.github.io/madr/).

## Index

| ID | Title | Status |
|---|---|---|
| [0001](0001-use-go-and-opa-sdk.md) | Use Go and OPA Go SDK as the primary implementation stack | accepted |
| [0002](0002-lsp-stdio-transport.md) | Use stdio as the primary LSP transport | accepted |
| [0003](0003-rego-deny-schema.md) | Rego deny rule schema | accepted |
| [0004](0004-policies-as-runtime-directory.md) | Policies as a runtime directory, not embedded in the binary | accepted |

## Adding a New ADR

1. Copy the template below into `docs/adr/NNNN-short-title.md` (zero-padded 4 digits).
2. Fill in all sections.
3. Add a row to the Index table above.
4. Status values: `proposed` → `accepted` → `superseded` / `deprecated`.

### Template

```md
# NNNN. Short Title

Date: YYYY-MM-DD
Status: proposed

## Context

What is the situation that forces this decision?

## Decision

What decision was made?

## Consequences

What becomes easier, harder, or different as a result?
```

An ADR **must** be written any time:
- A new external dependency is introduced or a major version is bumped.
- The transport layer or policy evaluation architecture changes significantly.
- A protocol-level decision is made that would be costly to reverse.
