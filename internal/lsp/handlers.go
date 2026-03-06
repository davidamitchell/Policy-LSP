// Package lsp implements a subset of the Language Server Protocol over JSON-RPC.
// Supported methods: initialize, textDocument/didOpen, textDocument/didChange.
package lsp

import (
	"context"
	"encoding/json"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/davidamitchell/policy-lsp/internal/engine"
)

// ---- JSON-RPC / LSP base types ----

// Request is an incoming LSP JSON-RPC message.
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Response is an outgoing LSP JSON-RPC message.
type Response struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Result  interface{} `json:"result,omitempty"`
	Error   *RPCError   `json:"error,omitempty"`
}

// RPCError represents a JSON-RPC error object.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Notification is an outgoing LSP notification (no ID).
type Notification struct {
	JSONRPC string      `json:"jsonrpc"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
}

// ---- LSP-specific types ----

// InitializeParams represents the params for the initialize request.
type InitializeParams struct {
	RootURI string `json:"rootUri"`
}

// InitializeResult is returned in response to initialize.
type InitializeResult struct {
	Capabilities ServerCapabilities `json:"capabilities"`
}

// ServerCapabilities describes what this server can do.
type ServerCapabilities struct {
	TextDocumentSync   int  `json:"textDocumentSync"`
	CodeActionProvider bool `json:"codeActionProvider"`
}

// TextDocumentItem holds the content of an opened document.
type TextDocumentItem struct {
	URI        string `json:"uri"`
	LanguageID string `json:"languageId"`
	Version    int    `json:"version"`
	Text       string `json:"text"`
}

// VersionedTextDocumentIdentifier identifies a versioned document.
type VersionedTextDocumentIdentifier struct {
	URI     string `json:"uri"`
	Version int    `json:"version"`
}

// TextDocumentIdentifier identifies a text document by URI.
type TextDocumentIdentifier struct {
	URI string `json:"uri"`
}

// TextDocumentContentChangeEvent represents a change to a text document.
type TextDocumentContentChangeEvent struct {
	Text string `json:"text"`
}

// DidOpenParams are the params for textDocument/didOpen.
type DidOpenParams struct {
	TextDocument TextDocumentItem `json:"textDocument"`
}

// DidChangeParams are the params for textDocument/didChange.
type DidChangeParams struct {
	TextDocument   VersionedTextDocumentIdentifier   `json:"textDocument"`
	ContentChanges []TextDocumentContentChangeEvent  `json:"contentChanges"`
}

// Diagnostic represents a single LSP diagnostic.
type Diagnostic struct {
	Range    Range       `json:"range"`
	Severity int         `json:"severity"` // 1=Error, 2=Warning, 3=Info, 4=Hint
	Code     string      `json:"code,omitempty"`
	Source   string      `json:"source"`
	Message  string      `json:"message"`
	Data     interface{} `json:"data,omitempty"`
}

// Range represents a range in a text document.
type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// Position is a zero-based line/character position.
type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// PublishDiagnosticsParams are the params for textDocument/publishDiagnostics.
type PublishDiagnosticsParams struct {
	URI         string       `json:"uri"`
	Diagnostics []Diagnostic `json:"diagnostics"`
}

// CodeActionContext carries the diagnostics that triggered the code action request.
type CodeActionContext struct {
	Diagnostics []Diagnostic `json:"diagnostics"`
}

// CodeActionParams are the params for textDocument/codeAction.
type CodeActionParams struct {
	TextDocument TextDocumentIdentifier `json:"textDocument"`
	Range        Range                  `json:"range"`
	Context      CodeActionContext       `json:"context"`
}

// CodeAction represents an action that can be taken to fix a diagnostic.
type CodeAction struct {
	Title       string         `json:"title"`
	Kind        string         `json:"kind,omitempty"`
	Diagnostics []Diagnostic   `json:"diagnostics,omitempty"`
	Edit        *WorkspaceEdit `json:"edit,omitempty"`
}

// WorkspaceEdit represents a set of workspace-level file changes.
type WorkspaceEdit struct {
	DocumentChanges []DocumentChange `json:"documentChanges,omitempty"`
}

// DocumentChange represents a file-level change operation within a WorkspaceEdit.
type DocumentChange struct {
	Kind   string `json:"kind"`
	OldURI string `json:"oldUri,omitempty"`
	NewURI string `json:"newUri,omitempty"`
}

// ---- Handler ----

// Publisher is a function that sends a notification to the client.
type Publisher func(notif Notification)

// Handler holds the server state and handles LSP requests.
type Handler struct {
	eng       *engine.Engine
	publish   Publisher
	debounce  map[string]*time.Timer
	debounceMu sync.Mutex
}

// NewHandler creates a Handler that uses the given Engine and Publisher.
func NewHandler(eng *engine.Engine, pub Publisher) *Handler {
	return &Handler{
		eng:      eng,
		publish:  pub,
		debounce: make(map[string]*time.Timer),
	}
}

// Handle dispatches an incoming request to the correct sub-handler.
func (h *Handler) Handle(ctx context.Context, req *Request) *Response {
	slog.Debug("lsp: received", "method", req.Method, "id", req.ID)
	switch req.Method {
	case "initialize":
		return h.handleInitialize(req)
	case "initialized":
		slog.Debug("lsp: initialized notification received")
		return nil // notification, no response needed
	case "textDocument/didOpen":
		h.handleDidOpen(ctx, req)
		return nil
	case "textDocument/didChange":
		h.handleDidChange(ctx, req)
		return nil
	case "textDocument/codeAction":
		return h.handleCodeAction(req)
	case "shutdown":
		slog.Info("lsp: shutdown received")
		return &Response{JSONRPC: "2.0", ID: req.ID, Result: nil}
	case "exit":
		slog.Info("lsp: exit received")
		return nil
	default:
		if req.ID != nil {
			slog.Debug("lsp: unknown method", "method", req.Method)
			return &Response{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &RPCError{Code: -32601, Message: "method not found"},
			}
		}
		slog.Debug("lsp: unknown notification (ignored)", "method", req.Method)
		return nil
	}
}

func (h *Handler) handleInitialize(req *Request) *Response {
	var params InitializeParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		slog.Debug("lsp: initialize params unreadable (ignored)", "err", err)
	} else {
		slog.Info("lsp: initialize", "rootUri", params.RootURI)
	}
	result := InitializeResult{
		Capabilities: ServerCapabilities{
			TextDocumentSync:   1, // Full sync
			CodeActionProvider: true,
		},
	}
	slog.Debug("lsp: initialize response sent", "textDocumentSync", result.Capabilities.TextDocumentSync, "codeActionProvider", result.Capabilities.CodeActionProvider)
	return &Response{JSONRPC: "2.0", ID: req.ID, Result: result}
}

func (h *Handler) handleDidOpen(ctx context.Context, req *Request) {
	var params DidOpenParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		slog.Warn("lsp: didOpen parse error", "err", err)
		return
	}
	slog.Debug("lsp: didOpen", "uri", params.TextDocument.URI, "languageId", params.TextDocument.LanguageID, "version", params.TextDocument.Version)
	h.evaluateAndPublish(ctx, params.TextDocument.URI, params.TextDocument.Text)
}

func (h *Handler) handleDidChange(ctx context.Context, req *Request) {
	var params DidChangeParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		slog.Warn("lsp: didChange parse error", "err", err)
		return
	}
	if len(params.ContentChanges) == 0 {
		slog.Debug("lsp: didChange has no content changes (ignored)", "uri", params.TextDocument.URI)
		return
	}
	text := params.ContentChanges[len(params.ContentChanges)-1].Text
	uri := params.TextDocument.URI
	slog.Debug("lsp: didChange", "uri", uri, "version", params.TextDocument.Version, "changes", len(params.ContentChanges))

	h.debounceMu.Lock()
	if t, ok := h.debounce[uri]; ok {
		t.Stop()
		slog.Debug("lsp: debounce reset", "uri", uri)
	}
	h.debounce[uri] = time.AfterFunc(200*time.Millisecond, func() {
		h.evaluateAndPublish(ctx, uri, text)
		h.debounceMu.Lock()
		delete(h.debounce, uri)
		h.debounceMu.Unlock()
	})
	h.debounceMu.Unlock()
}

// evaluateAndPublish runs policy evaluation and publishes diagnostics.
func (h *Handler) evaluateAndPublish(ctx context.Context, uri, text string) {
	filename := filenameFromURI(uri)
	ext := filepath.Ext(filename)
	slog.Debug("lsp: evaluating document", "uri", uri, "filename", filename, "ext", ext)

	in := engine.Input{
		Filename:     filename,
		Extension:    ext,
		Path:         uri,
		FileContents: text,
	}

	violations, err := h.eng.Evaluate(ctx, in)
	if err != nil {
		slog.Warn("lsp: evaluation error", "uri", uri, "err", err)
		return
	}

	diags := make([]Diagnostic, 0, len(violations))
	for _, v := range violations {
		d := violationToDiagnostic(v)
		diags = append(diags, d)
	}

	slog.Debug("lsp: publishing diagnostics", "uri", uri, "count", len(diags))
	h.publish(Notification{
		JSONRPC: "2.0",
		Method:  "textDocument/publishDiagnostics",
		Params: PublishDiagnosticsParams{
			URI:         uri,
			Diagnostics: diags,
		},
	})
}

// violationToDiagnostic maps a policy Violation to an LSP Diagnostic.
func violationToDiagnostic(v engine.Violation) Diagnostic {
	line := 0
	col := 0
	if v.Location != nil {
		if l, ok := v.Location["line"].(json.Number); ok {
			if n, err := l.Int64(); err == nil {
				line = int(n) - 1 // LSP is 0-based; Rego uses 1-based
			}
		} else if lf, ok := v.Location["line"].(float64); ok {
			line = int(lf) - 1
		}
		if c, ok := v.Location["column"].(json.Number); ok {
			if n, err := c.Int64(); err == nil {
				col = int(n) - 1
			}
		} else if cf, ok := v.Location["column"].(float64); ok {
			col = int(cf) - 1
		}
	}
	if line < 0 {
		line = 0
	}
	if col < 0 {
		col = 0
	}

	severity := 2 // Warning by default
	if v.Level == "error" {
		severity = 1
	} else if v.Level == "info" {
		severity = 3
	}

	d := Diagnostic{
		Range: Range{
			Start: Position{Line: line, Character: col},
			End:   Position{Line: line, Character: col},
		},
		Severity: severity,
		Code:     v.ID,
		Source:   "gov-lsp",
		Message:  v.Message,
	}

	if v.Fix != nil {
		d.Data = v.Fix
	}

	return d
}

// filenameFromURI extracts the base filename from a file URI.
func filenameFromURI(uri string) string {
	// Strip file:// scheme
	path := strings.TrimPrefix(uri, "file://")
	return filepath.Base(path)
}

func (h *Handler) handleCodeAction(req *Request) *Response {
	var params CodeActionParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		slog.Warn("lsp: codeAction parse error", "err", err)
		return &Response{JSONRPC: "2.0", ID: req.ID, Result: []CodeAction{}}
	}
	slog.Debug("lsp: codeAction", "uri", params.TextDocument.URI, "diagnostics", len(params.Context.Diagnostics))

	actions := make([]CodeAction, 0)
	for _, diag := range params.Context.Diagnostics {
		fix, ok := diag.Data.(map[string]interface{})
		if !ok {
			continue
		}
		fixType, _ := fix["type"].(string)
		fixValue, _ := fix["value"].(string)
		if fixType != "rename" || fixValue == "" {
			continue
		}

		oldURI := params.TextDocument.URI
		newURI := renameURIFilename(oldURI, fixValue)
		slog.Debug("lsp: code action: rename", "from", oldURI, "to", newURI)

		actions = append(actions, CodeAction{
			Title:       "Rename to " + fixValue,
			Kind:        "quickfix",
			Diagnostics: []Diagnostic{diag},
			Edit: &WorkspaceEdit{
				DocumentChanges: []DocumentChange{
					{Kind: "rename", OldURI: oldURI, NewURI: newURI},
				},
			},
		})
	}

	slog.Debug("lsp: codeAction response", "actions", len(actions))
	return &Response{JSONRPC: "2.0", ID: req.ID, Result: actions}
}

// renameURIFilename replaces the filename component of a file URI with newFilename.
func renameURIFilename(uri, newFilename string) string {
	lastSlash := strings.LastIndex(uri, "/")
	if lastSlash < 0 {
		return newFilename
	}
	return uri[:lastSlash+1] + newFilename
}
