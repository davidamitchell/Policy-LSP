// Package engine wraps the OPA SDK to evaluate Rego policies against file metadata.
package engine

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/open-policy-agent/opa/rego"
)

// Input is the data fed into every Rego evaluation.
type Input struct {
	Filename     string `json:"filename"`
	Extension    string `json:"extension"`
	Path         string `json:"path"`
	FileContents string `json:"file_contents"`
}

// Violation is a single deny result returned from a policy.
type Violation struct {
	ID       string                 `json:"id"`
	Level    string                 `json:"level"`
	Message  string                 `json:"message"`
	Location map[string]interface{} `json:"location,omitempty"`
	Fix      map[string]interface{} `json:"fix,omitempty"`
}

// Engine evaluates a set of Rego policies loaded from a directory.
type Engine struct {
	query rego.PreparedEvalQuery
}

// New creates an Engine by loading all .rego files from policyDir.
func New(policyDir string) (*Engine, error) {
	modules := map[string]string{}

	if err := loadDir(policyDir, modules); err != nil {
		return nil, fmt.Errorf("loading policies from %s: %w", policyDir, err)
	}

	if len(modules) == 0 {
		return nil, fmt.Errorf("no .rego files found in %s", policyDir)
	}

	opts := []func(*rego.Rego){
		rego.Query("data.governance[_].deny"),
	}
	for name, src := range modules {
		opts = append(opts, rego.Module(name, src))
	}

	pq, err := rego.New(opts...).PrepareForEval(context.Background())
	if err != nil {
		return nil, fmt.Errorf("preparing query: %w", err)
	}

	return &Engine{query: pq}, nil
}

// NewFromFS creates an Engine by loading all .rego files from an fs.FS.
func NewFromFS(fsys fs.FS) (*Engine, error) {
	modules := map[string]string{}

	if err := fs.WalkDir(fsys, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".rego") {
			return nil
		}
		src, err := fs.ReadFile(fsys, path)
		if err != nil {
			return err
		}
		modules[filepath.Base(path)] = string(src)
		return nil
	}); err != nil {
		return nil, fmt.Errorf("loading policies from FS: %w", err)
	}

	if len(modules) == 0 {
		return nil, fmt.Errorf("no .rego files found")
	}

	opts := []func(*rego.Rego){
		rego.Query("data.governance[_].deny"),
	}
	for name, src := range modules {
		opts = append(opts, rego.Module(name, src))
	}

	pq, err := rego.New(opts...).PrepareForEval(context.Background())
	if err != nil {
		return nil, fmt.Errorf("preparing query: %w", err)
	}

	return &Engine{query: pq}, nil
}

// Evaluate runs all loaded policies against the given input and returns the
// aggregated list of violations.
func (e *Engine) Evaluate(ctx context.Context, in Input) ([]Violation, error) {
	inputMap := map[string]interface{}{
		"filename":      in.Filename,
		"extension":     in.Extension,
		"path":          in.Path,
		"file_contents": in.FileContents,
	}

	rs, err := e.query.Eval(ctx, rego.EvalInput(inputMap))
	if err != nil {
		return nil, fmt.Errorf("evaluating policies: %w", err)
	}

	var violations []Violation
	for _, result := range rs {
		for _, expr := range result.Expressions {
			set, ok := expr.Value.([]interface{})
			if !ok {
				continue
			}
			for _, item := range set {
				v, err := toViolation(item)
				if err != nil {
					continue
				}
				violations = append(violations, v)
			}
		}
	}
	return violations, nil
}

// toViolation converts the raw Rego result value into a Violation struct.
func toViolation(raw interface{}) (Violation, error) {
	m, ok := raw.(map[string]interface{})
	if !ok {
		return Violation{}, fmt.Errorf("unexpected type %T", raw)
	}
	v := Violation{
		ID:      stringField(m, "id"),
		Level:   stringField(m, "level"),
		Message: stringField(m, "message"),
	}
	if loc, ok := m["location"].(map[string]interface{}); ok {
		v.Location = loc
	}
	if fix, ok := m["fix"].(map[string]interface{}); ok {
		v.Fix = fix
	}
	return v, nil
}

func stringField(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

// loadDir reads all .rego files from dir into modules.
func loadDir(dir string, modules map[string]string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".rego") {
			return nil
		}
		src, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		modules[filepath.Base(path)] = string(src)
		return nil
	})
}
