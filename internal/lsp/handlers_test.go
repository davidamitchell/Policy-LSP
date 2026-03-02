// Package lsp_test contains integration tests for the LSP handler.
// Tests use an in-memory fstest.MapFS policy engine to remain hermetic.
package lsp_test

import (
	"context"
	"encoding/json"
	"testing"
	"testing/fstest"

	"github.com/davidamitchell/policy-lsp/internal/engine"
	"github.com/davidamitchell/policy-lsp/internal/lsp"
)

// filenamePolicy is an inline copy of the governance.filenames rule used to
// keep handler tests fully hermetic (no dependency on the policies/ directory).
const filenamePolicy = `package governance.filenames

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

// testHandler returns a Handler with an in-memory engine and a recorder Publisher.
func testHandler(t *testing.T) (*lsp.Handler, *[]lsp.Notification) {
	t.Helper()
	policies := fstest.MapFS{
		"filenames.rego": &fstest.MapFile{Data: []byte(filenamePolicy)},
	}
	eng, err := engine.New(policies)
	if err != nil {
		t.Fatalf("engine.New: %v", err)
	}

	var published []lsp.Notification
	h := lsp.NewHandler(eng, func(n lsp.Notification) {
		published = append(published, n)
	})
	return h, &published
}

func TestHandle_Initialize_ReturnsCapabilities(t *testing.T) {
	h, _ := testHandler(t)

	req := &lsp.Request{
		JSONRPC: "2.0",
		ID:      float64(1),
		Method:  "initialize",
		Params:  json.RawMessage(`{"rootUri":"file:///workspace"}`),
	}

	resp := h.Handle(context.Background(), req)
	if resp == nil {
		t.Fatal("expected response, got nil")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error: %+v", resp.Error)
	}

	result, ok := resp.Result.(lsp.InitializeResult)
	if !ok {
		t.Fatalf("result type = %T, want lsp.InitializeResult", resp.Result)
	}
	if result.Capabilities.TextDocumentSync != 1 {
		t.Errorf("TextDocumentSync = %d, want 1", result.Capabilities.TextDocumentSync)
	}
	if !result.Capabilities.CodeActionProvider {
		t.Error("expected CodeActionProvider = true")
	}
}

func TestHandle_DidOpen_ViolatingFile_PublishesDiagnostics(t *testing.T) {
	h, published := testHandler(t)

	req := &lsp.Request{
		JSONRPC: "2.0",
		Method:  "textDocument/didOpen",
		Params: json.RawMessage(`{
			"textDocument": {
				"uri": "file:///workspace/lower_case.md",
				"languageId": "markdown",
				"version": 1,
				"text": "# hello"
			}
		}`),
	}

	h.Handle(context.Background(), req)

	if len(*published) != 1 {
		t.Fatalf("published %d notifications, want 1", len(*published))
	}
	if (*published)[0].Method != "textDocument/publishDiagnostics" {
		t.Errorf("method = %q, want textDocument/publishDiagnostics", (*published)[0].Method)
	}

	params, ok := (*published)[0].Params.(lsp.PublishDiagnosticsParams)
	if !ok {
		t.Fatalf("params type = %T, want lsp.PublishDiagnosticsParams", (*published)[0].Params)
	}
	if len(params.Diagnostics) == 0 {
		t.Fatal("expected diagnostics, got none")
	}
	diag := params.Diagnostics[0]
	if diag.Code != "markdown-naming-violation" {
		t.Errorf("code = %q, want markdown-naming-violation", diag.Code)
	}
	if diag.Data == nil {
		t.Error("expected fix data in diagnostic, got nil")
	}
}

func TestHandle_DidOpen_CompliantFile_PublishesEmptyDiagnostics(t *testing.T) {
	h, published := testHandler(t)

	req := &lsp.Request{
		JSONRPC: "2.0",
		Method:  "textDocument/didOpen",
		Params: json.RawMessage(`{
			"textDocument": {
				"uri": "file:///workspace/UPPER_CASE.md",
				"languageId": "markdown",
				"version": 1,
				"text": "# valid"
			}
		}`),
	}

	h.Handle(context.Background(), req)

	if len(*published) != 1 {
		t.Fatalf("published %d notifications, want 1", len(*published))
	}
	params, ok := (*published)[0].Params.(lsp.PublishDiagnosticsParams)
	if !ok {
		t.Fatalf("params type = %T", (*published)[0].Params)
	}
	if len(params.Diagnostics) != 0 {
		t.Errorf("expected empty diagnostics for compliant file, got %d", len(params.Diagnostics))
	}
}

func TestHandle_CodeAction_ReturnsRenameEdit(t *testing.T) {
	h, _ := testHandler(t)

	// Construct a codeAction request with a markdown-naming-violation diagnostic
	// that carries a rename fix in the data field.
	req := &lsp.Request{
		JSONRPC: "2.0",
		ID:      float64(2),
		Method:  "textDocument/codeAction",
		Params: json.RawMessage(`{
			"textDocument": {"uri": "file:///workspace/lower_case.md"},
			"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
			"context": {
				"diagnostics": [{
					"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
					"severity": 1,
					"code": "markdown-naming-violation",
					"source": "gov-lsp",
					"message": "Markdown file 'lower_case.md' must be SCREAMING_SNAKE_CASE",
					"data": {"type": "rename", "value": "LOWER_CASE.md"}
				}]
			}
		}`),
	}

	resp := h.Handle(context.Background(), req)
	if resp == nil {
		t.Fatal("expected response, got nil")
	}
	if resp.Error != nil {
		t.Fatalf("unexpected error: %+v", resp.Error)
	}

	actions, ok := resp.Result.([]lsp.CodeAction)
	if !ok {
		t.Fatalf("result type = %T, want []lsp.CodeAction", resp.Result)
	}
	if len(actions) == 0 {
		t.Fatal("expected code actions, got none")
	}

	action := actions[0]
	if action.Kind != "quickfix" {
		t.Errorf("kind = %q, want quickfix", action.Kind)
	}
	if action.Edit == nil {
		t.Fatal("expected edit, got nil")
	}
	if len(action.Edit.DocumentChanges) == 0 {
		t.Fatal("expected document changes, got none")
	}
	change := action.Edit.DocumentChanges[0]
	if change.Kind != "rename" {
		t.Errorf("change kind = %q, want rename", change.Kind)
	}
	if change.OldURI != "file:///workspace/lower_case.md" {
		t.Errorf("oldUri = %q, want file:///workspace/lower_case.md", change.OldURI)
	}
	if change.NewURI != "file:///workspace/LOWER_CASE.md" {
		t.Errorf("newUri = %q, want file:///workspace/LOWER_CASE.md", change.NewURI)
	}
}

func TestHandle_CodeAction_NoDiagnostics_ReturnsEmpty(t *testing.T) {
	h, _ := testHandler(t)

	req := &lsp.Request{
		JSONRPC: "2.0",
		ID:      float64(3),
		Method:  "textDocument/codeAction",
		Params: json.RawMessage(`{
			"textDocument": {"uri": "file:///workspace/VALID.md"},
			"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
			"context": {"diagnostics": []}
		}`),
	}

	resp := h.Handle(context.Background(), req)
	if resp == nil {
		t.Fatal("expected response, got nil")
	}
	actions, ok := resp.Result.([]lsp.CodeAction)
	if !ok {
		t.Fatalf("result type = %T, want []lsp.CodeAction", resp.Result)
	}
	if len(actions) != 0 {
		t.Errorf("expected empty actions, got %d", len(actions))
	}
}

func TestHandle_UnknownMethod_ReturnsError(t *testing.T) {
	h, _ := testHandler(t)

	req := &lsp.Request{
		JSONRPC: "2.0",
		ID:      float64(99),
		Method:  "textDocument/unknownMethod",
	}

	resp := h.Handle(context.Background(), req)
	if resp == nil {
		t.Fatal("expected response, got nil")
	}
	if resp.Error == nil {
		t.Fatal("expected error response, got nil error")
	}
	if resp.Error.Code != -32601 {
		t.Errorf("error code = %d, want -32601", resp.Error.Code)
	}
}

func TestHandle_CodeAction_URIWithoutDirectory_ReturnsRename(t *testing.T) {
	h, _ := testHandler(t)

	// URI with no directory component — renameURIFilename should still work.
	req := &lsp.Request{
		JSONRPC: "2.0",
		ID:      float64(4),
		Method:  "textDocument/codeAction",
		Params: json.RawMessage(`{
			"textDocument": {"uri": "lower_case.md"},
			"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
			"context": {
				"diagnostics": [{
					"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
					"severity": 1,
					"code": "markdown-naming-violation",
					"source": "gov-lsp",
					"message": "Markdown file 'lower_case.md' must be SCREAMING_SNAKE_CASE",
					"data": {"type": "rename", "value": "LOWER_CASE.md"}
				}]
			}
		}`),
	}

	resp := h.Handle(context.Background(), req)
	if resp == nil {
		t.Fatal("expected response, got nil")
	}
	actions, ok := resp.Result.([]lsp.CodeAction)
	if !ok {
		t.Fatalf("result type = %T, want []lsp.CodeAction", resp.Result)
	}
	if len(actions) == 0 {
		t.Fatal("expected code actions, got none")
	}
	// URI with no slash: renameURIFilename returns just the new filename.
	change := actions[0].Edit.DocumentChanges[0]
	if change.NewURI != "LOWER_CASE.md" {
		t.Errorf("newUri = %q, want LOWER_CASE.md", change.NewURI)
	}
}

func TestHandle_Notification_ReturnsNil(t *testing.T) {
	h, _ := testHandler(t)

	// Notifications have no ID and must not receive a response.
	req := &lsp.Request{
		JSONRPC: "2.0",
		Method:  "initialized",
		// ID is nil (zero value)
	}

	resp := h.Handle(context.Background(), req)
	if resp != nil {
		t.Errorf("expected nil response for notification, got %+v", resp)
	}
}
