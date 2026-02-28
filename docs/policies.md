# Writing Policies

Policies are Rego files that the OPA SDK evaluates at runtime. No server recompile is needed to add, change, or remove a rule.

---

## Policy file location

Place policy files anywhere in the directory passed to `--policies` (or `GOV_LSP_POLICIES`). The engine does a recursive walk and loads every `*.rego` file it finds.

```
policies/
├── filenames.rego        # SCREAMING_SNAKE_CASE for .md files
├── content/
│   └── go_headers.rego   # copyright / package comment checks
└── secrets/
    └── no_api_keys.rego  # detect hardcoded credentials
```

---

## Input schema

Every policy evaluation receives a single `input` document with these fields:

| Field | Type | Description |
|---|---|---|
| `input.filename` | `string` | Base filename — `README.md` |
| `input.extension` | `string` | Extension including dot — `.md` |
| `input.path` | `string` | Full file URI — `file:///workspace/README.md` |
| `input.file_contents` | `string` | Complete text content of the file |

---

## Deny rule schema

Every policy must define a `deny` set-rule in the `governance.*` package namespace. Each element of the set is an object with these fields:

| Field | Required | Type | Description |
|---|---|---|---|
| `id` | yes | `string` | Stable identifier for the violation — used as `Diagnostic.code` |
| `message` | yes | `string` | Human-readable explanation shown in the editor |
| `level` | no | `"error"` \| `"warning"` \| `"info"` | Maps to LSP severity 1/2/3. Defaults to `"warning"`. |
| `location` | no | `{"line": int, "column": int}` | 1-based source position. Defaults to line 1, column 1. |
| `fix` | no | `{"type": string, "value": string}` | Carried in `Diagnostic.data` for CodeAction. `type` is `"rename"` \| `"insert"` \| `"delete"`. |

---

## Minimal policy

```rego
package governance.filenames

import future.keywords.if
import future.keywords.contains

deny contains msg if {
    endswith(input.filename, ".md")
    not regex.match(`^[A-Z0-9_]+$`, trim_suffix(input.filename, ".md"))
    msg := {
        "id":      "markdown-naming-violation",
        "level":   "error",
        "message": sprintf("'%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
    }
}
```

---

## Policy with fix suggestion

```rego
package governance.filenames

import future.keywords.if
import future.keywords.contains

deny contains msg if {
    endswith(input.filename, ".md")
    name_root := trim_suffix(input.filename, ".md")
    not regex.match(`^[A-Z0-9_]+$`, name_root)
    msg := {
        "id":      "markdown-naming-violation",
        "level":   "error",
        "message": sprintf("'%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
        "location": {"line": 1, "column": 1},
        "fix": {
            "type":  "rename",
            "value": sprintf("%s.md", [upper(replace(name_root, "-", "_"))]),
        },
    }
}
```

---

## Content-aware policy

```rego
package governance.go_headers

import future.keywords.if
import future.keywords.contains

deny contains msg if {
    input.extension == ".go"
    not startswith(input.file_contents, "package ")
    not startswith(input.file_contents, "//")
    msg := {
        "id":      "missing-package-comment",
        "level":   "warning",
        "message": "Go file should begin with a package comment or package declaration",
    }
}
```

---

## Testing a policy

Policy tests live in `internal/engine/rego_test.go` as standard Go tests. They use `engine.New()` (pointing at the real `policies/` directory) or `engine.NewFromFS()` (for a hermetic in-memory policy).

### Table-driven pattern

```go
func TestGoHeaders(t *testing.T) {
    eng, err := engine.New(policyDir(t))
    if err != nil {
        t.Fatalf("engine.New: %v", err)
    }

    cases := []struct {
        name     string
        filename string
        contents string
        wantID   string // empty = expect no violations
    }{
        {
            name:     "valid: starts with package",
            filename: "main.go",
            contents: "package main\n",
        },
        {
            name:     "valid: starts with comment",
            filename: "main.go",
            contents: "// Package main is the entry point.\npackage main\n",
        },
        {
            name:     "violation: empty file",
            filename: "main.go",
            contents: "",
            wantID:   "missing-package-comment",
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            in := engine.Input{
                Filename:     tc.filename,
                Extension:    ".go",
                Path:         "file:///workspace/" + tc.filename,
                FileContents: tc.contents,
            }
            violations, err := eng.Evaluate(context.Background(), in)
            if err != nil {
                t.Fatalf("Evaluate: %v", err)
            }
            if tc.wantID == "" {
                if len(violations) != 0 {
                    t.Errorf("expected no violations, got %d", len(violations))
                }
                return
            }
            if len(violations) == 0 {
                t.Fatal("expected violation, got none")
            }
            if violations[0].ID != tc.wantID {
                t.Errorf("violation.ID = %q, want %q", violations[0].ID, tc.wantID)
            }
        })
    }
}
```

### Using an in-memory policy (hermetic)

```go
func TestMyPolicy_Hermetic(t *testing.T) {
    fsys := fstest.MapFS{
        "my_rule.rego": {Data: []byte(`
            package governance.my_rule
            import future.keywords.if
            import future.keywords.contains
            deny contains msg if {
                input.extension == ".txt"
                msg := {"id": "no-txt", "message": "no .txt files allowed"}
            }
        `)},
    }
    eng, err := engine.NewFromFS(fsys)
    if err != nil {
        t.Fatalf("NewFromFS: %v", err)
    }
    // ...
}
```

---

## Checklist before committing a new policy

- [ ] Policy file is in `policies/` with `package governance.<name>`
- [ ] `deny` returns a set with at least `id` and `message`
- [ ] Go tests cover the compliant case (no violations) and the violating case
- [ ] `go test ./...` passes
- [ ] `scripts/smoke_test.sh` passes (for policies affecting `.md` files)
- [ ] `BACKLOG.md` updated if this closes a slice

---

## Iterating with the OPA CLI

The OPA CLI is the fastest way to check a policy without running the server:

```bash
# Evaluate the filenames policy against a test input
opa eval \
  -d policies/filenames.rego \
  -I \
  --input /dev/stdin \
  'data.governance.filenames.deny' <<'EOF'
{"filename": "lower_case.md", "extension": ".md", "path": "/ws/lower_case.md", "file_contents": "# hello"}
EOF
```

Expected output:
```json
{
  "result": [
    {
      "expressions": [
        {
          "value": [
            {
              "fix": {"type": "rename", "value": "LOWER_CASE.md"},
              "id": "markdown-naming-violation",
              ...
            }
          ]
        }
      ]
    }
  ]
}
```
