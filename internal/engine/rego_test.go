package engine_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/davidamitchell/policy-lsp/internal/engine"
)

// policyDir returns the absolute path to the project-level policies/ directory.
func policyDir(t *testing.T) string {
	t.Helper()
	// Walk up from the test file location to find the policies directory.
	dir, err := filepath.Abs("../../policies")
	if err != nil {
		t.Fatalf("resolving policies dir: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("policies dir not found at %s: %v", dir, err)
	}
	return dir
}

func TestEvaluate_LowercaseMarkdown_ReturnsViolation(t *testing.T) {
	eng, err := engine.New(policyDir(t))
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
	eng, err := engine.New(policyDir(t))
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
	eng, err := engine.New(policyDir(t))
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	in := engine.Input{
		Filename:     "main.go",
		Extension:    ".go",
		Path:         "/workspace/main.go",
		FileContents: "package main",
	}
	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(violations) != 0 {
		t.Errorf("expected no violations for .go file, got %d", len(violations))
	}
}

func TestEvaluate_DashInName_SuggestsUnderscore(t *testing.T) {
	eng, err := engine.New(policyDir(t))
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

func TestNew_MissingDir_ReturnsError(t *testing.T) {
	_, err := engine.New("/nonexistent/policies")
	if err == nil {
		t.Fatal("expected error for missing directory, got nil")
	}
}
