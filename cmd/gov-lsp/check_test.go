package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/davidamitchell/policy-lsp/internal/engine"
)

// policyEngine builds an engine from an in-memory Rego policy for testing.
func policyEngine(t *testing.T) *engine.Engine {
	t.Helper()
	// Inline the same policy as policies/filenames.rego to keep tests hermetic.
	policies := fstest.MapFS{
		"filenames.rego": &fstest.MapFile{Data: []byte(`package governance.filenames

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
`)},
	}

	eng, err := engine.New(policies)
	if err != nil {
		t.Fatalf("policyEngine: %v", err)
	}
	return eng
}

// writeFile creates a file at dir/name with content. Fails the test on error.
func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("writeFile %s: %v", path, err)
	}
	return path
}

func TestRunCheck_ViolatingFile_ReturnsCount(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "lower_case.md", "# hello")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != 1 {
		t.Errorf("count = %d, want 1\nOutput:\n%s", count, buf.String())
	}
	if !strings.Contains(buf.String(), "markdown-naming-violation") {
		t.Errorf("expected 'markdown-naming-violation' in output:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "LOWER_CASE.md") {
		t.Errorf("expected fix value 'LOWER_CASE.md' in output:\n%s", buf.String())
	}
}

func TestRunCheck_CompliantFile_ReturnsZero(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "UPPER_CASE.md", "# valid")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != 0 {
		t.Errorf("count = %d, want 0\nOutput:\n%s", count, buf.String())
	}
}

func TestRunCheck_NonMarkdownFile_NoViolation(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "main.go", "package main")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != 0 {
		t.Errorf("count = %d, want 0 for .go file\nOutput:\n%s", count, buf.String())
	}
}

func TestRunCheck_MultipleFiles_CountsAll(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "lower_case.md", "# hello")
	writeFile(t, dir, "my-doc.md", "# my doc")
	writeFile(t, dir, "VALID.md", "# valid")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != 2 {
		t.Errorf("count = %d, want 2\nOutput:\n%s", count, buf.String())
	}
}

func TestRunCheck_DashName_SuggestsUnderscore(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "my-doc.md", "")

	eng := policyEngine(t)
	var buf bytes.Buffer
	_, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if !strings.Contains(buf.String(), "MY_DOC.md") {
		t.Errorf("expected fix 'MY_DOC.md' in output:\n%s", buf.String())
	}
}

func TestRunCheck_JSONFormat_ValidJSON(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "lower_case.md", "# hello")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "json", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count == 0 {
		t.Fatal("expected violations, got 0")
	}

	var results []CheckResult
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &results); err != nil {
		t.Fatalf("JSON output is not valid: %v\nOutput:\n%s", err, buf.String())
	}
	if len(results) != count {
		t.Errorf("JSON has %d items, expected %d", len(results), count)
	}
	if results[0].Fix == nil {
		t.Error("expected fix in JSON result, got nil")
	}
}

func TestRunCheck_FilenamePolicy_DetectsViolations(t *testing.T) {
	// Hermetic falsifiability test: a known set of violating and compliant files
	// is written to a temp dir. The test fails if the engine returns a count
	// other than the exact number of violating files supplied.
	dir := t.TempDir()
	// Three files that must trigger a violation.
	writeFile(t, dir, "getting-started.md", "# getting started")
	writeFile(t, dir, "policies.md", "# policies")
	writeFile(t, dir, "integrations.md", "# integrations")
	// Two files that must NOT trigger a violation.
	writeFile(t, dir, "README.md", "# readme")
	writeFile(t, dir, "CHANGELOG.md", "# changelog")

	const wantViolations = 3

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != wantViolations {
		t.Errorf("violation count = %d, want %d\nOutput:\n%s", count, wantViolations, buf.String())
	}
}

func TestRunCheck_SkipsHiddenDirs(t *testing.T) {
	dir := t.TempDir()
	// Hidden directory should be skipped.
	hiddenDir := filepath.Join(dir, ".hidden")
	if err := os.Mkdir(hiddenDir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	writeFile(t, hiddenDir, "violating.md", "# should be skipped")
	writeFile(t, dir, "VALID.md", "# valid")

	eng := policyEngine(t)
	var buf bytes.Buffer
	count, err := runCheck(eng, []string{dir}, "text", &buf)
	if err != nil {
		t.Fatalf("runCheck: %v", err)
	}
	if count != 0 {
		t.Errorf("count = %d, want 0 (hidden dir should be skipped)\nOutput:\n%s", count, buf.String())
	}
}
