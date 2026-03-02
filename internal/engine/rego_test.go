package engine_test

import (
	"context"
	"testing"
	"testing/fstest"

	"github.com/davidamitchell/policy-lsp/internal/engine"
)

// filenamesPolicy is the canonical governance.filenames Rego source used by
// hermetic tests to avoid coupling to the physical policies/ directory layout.
const filenamesPolicy = `package governance.filenames

import future.keywords.if
import future.keywords.contains

deny contains msg if {
	endswith(input.filename, ".md")
	name_root := trim_suffix(input.filename, ".md")
	not regex.match("^[A-Z0-9_]+$", name_root)
	msg := {
		"id": "markdown-naming-violation",
		"level": "error",
		"message": sprintf("Markdown file '%s' must be SCREAMING_SNAKE_CASE", [input.filename]),
		"location": {"line": 1, "column": 1},
		"fix": {
			"type": "rename",
			"value": sprintf("%s.md", [upper(replace(name_root, "-", "_"))]),
		},
	}
}
`

// contentPolicy is the canonical governance.content Rego source for hermetic tests.
const contentPolicy = `package governance.content

import future.keywords.if
import future.keywords.contains

deny contains msg if {
	input.extension == ".go"
	not endswith(input.filename, "_test.go")
	not file_starts_with_comment
	msg := {
		"id": "missing-package-comment",
		"level": "warning",
		"message": sprintf("Go file '%s' should begin with a package comment", [input.filename]),
		"location": {"line": 1, "column": 1},
	}
}

file_starts_with_comment if {
	regex.match("^\\s*//", input.file_contents)
}

file_starts_with_comment if {
	regex.match("^\\s*/\\*", input.file_contents)
}
`

// policyFS returns an in-memory FS containing both governance policies.
func policyFS() fstest.MapFS {
	return fstest.MapFS{
		"filenames.rego": &fstest.MapFile{Data: []byte(filenamesPolicy)},
		"content.rego":   &fstest.MapFile{Data: []byte(contentPolicy)},
	}
}

func TestEvaluate_LowercaseMarkdown_ReturnsViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "lower_case.md",
		Extension:    ".md",
		Path:         "/workspace/lower_case.md",
		FileContents: "# hello",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) == 0 {
		t.Fatal("expected at least one violation, got none")
	}

	v := violations[0]
	if v.ID != "markdown-naming-violation" {
		t.Errorf("violation ID = %q, want %q", v.ID, "markdown-naming-violation")
	}
	if v.Level != "error" {
		t.Errorf("violation level = %q, want %q", v.Level, "error")
	}
	if v.Fix == nil {
		t.Fatal("expected a fix, got nil")
	}
	if v.Fix["type"] != "rename" {
		t.Errorf("fix type = %v, want %q", v.Fix["type"], "rename")
	}
	if v.Fix["value"] != "LOWER_CASE.md" {
		t.Errorf("fix value = %v, want %q", v.Fix["value"], "LOWER_CASE.md")
	}
}

func TestEvaluate_ScreamingSnakeMarkdown_NoViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "UPPER_CASE.md",
		Extension:    ".md",
		Path:         "/workspace/UPPER_CASE.md",
		FileContents: "# hello",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) != 0 {
		t.Errorf("expected no violations, got %d: %+v", len(violations), violations)
	}
}

func TestEvaluate_NonMarkdownFile_NoViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	// A compliant Go file (with comment) should produce no violations.
	in := engine.Input{
		Filename:     "main.go",
		Extension:    ".go",
		Path:         "/workspace/main.go",
		FileContents: "// Package main does something.\npackage main",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) != 0 {
		t.Errorf("expected no violations for compliant .go file, got %d", len(violations))
	}
}

func TestEvaluate_DashInName_SuggestsUnderscore(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "my-doc.md",
		Extension:    ".md",
		Path:         "/workspace/my-doc.md",
		FileContents: "",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) == 0 {
		t.Fatal("expected violation for dash-named file")
	}
	if violations[0].Fix["value"] != "MY_DOC.md" {
		t.Errorf("fix value = %v, want %q", violations[0].Fix["value"], "MY_DOC.md")
	}
}

func TestNew_EmptyFS_ReturnsError(t *testing.T) {
	_, err := engine.New(fstest.MapFS{})
	if err == nil {
		t.Fatal("expected error for empty FS, got nil")
	}
}

func TestNewFromDir_MissingDir_ReturnsError(t *testing.T) {
	_, err := engine.NewFromDir("/nonexistent/policies")
	if err == nil {
		t.Fatal("expected error for missing directory, got nil")
	}
}

// ---- content policy tests (W-0007) ------------------------------------------

func TestEvaluate_GoFileWithComment_NoViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "server.go",
		Extension:    ".go",
		Path:         "/workspace/server.go",
		FileContents: "// Package main implements the server.\npackage main\n",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) != 0 {
		t.Errorf("expected no violations for Go file with comment, got %d: %+v", len(violations), violations)
	}
}

func TestEvaluate_GoFileWithoutComment_ReturnsViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "server.go",
		Extension:    ".go",
		Path:         "/workspace/server.go",
		FileContents: "package main\n\nfunc main() {}\n",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}

	var found bool
	for _, v := range violations {
		if v.ID == "missing-package-comment" {
			found = true
			if v.Level != "warning" {
				t.Errorf("level = %q, want %q", v.Level, "warning")
			}
		}
	}
	if !found {
		t.Fatalf("expected missing-package-comment violation, got: %+v", violations)
	}
}

func TestEvaluate_GoTestFile_NoViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	// Test files are exempt even without a package comment.
	in := engine.Input{
		Filename:     "server_test.go",
		Extension:    ".go",
		Path:         "/workspace/server_test.go",
		FileContents: "package main_test\n\nimport \"testing\"\n",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	for _, v := range violations {
		if v.ID == "missing-package-comment" {
			t.Errorf("unexpected missing-package-comment violation for test file")
		}
	}
}

func TestEvaluate_GoFileWithBlockComment_NoViolation(t *testing.T) {
	eng, err := engine.New(policyFS())
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "server.go",
		Extension:    ".go",
		Path:         "/workspace/server.go",
		FileContents: "/* Package main implements the server. */\npackage main\n",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	for _, v := range violations {
		if v.ID == "missing-package-comment" {
			t.Errorf("unexpected violation for Go file with block comment")
		}
	}
}
