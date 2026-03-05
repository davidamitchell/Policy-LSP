// e2e_test.go exercises the compiled gov-lsp binary end-to-end over stdin/stdout.
//
// These tests are the "top of the testing pyramid": they start the actual binary,
// speak the LSP Content-Length+JSON-RPC protocol, and assert every response.
// They prove the server works exactly as an editor client would see it — not
// just that individual functions return the right values in isolation.
//
// TestMain builds the binary once into a temp directory. All e2e tests in this
// file spawn that binary and communicate via pipes.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// testBinaryPath is populated by TestMain and used by all e2e tests.
var testBinaryPath string

// TestMain builds the gov-lsp binary once and runs all tests in the package.
// Unit tests (check_test.go) continue to work because they call Go functions
// directly and do not need the binary variable.
func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "gov-lsp-e2e-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: create temp dir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmp)

	name := "gov-lsp"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	testBinaryPath = filepath.Join(tmp, name)

	// Build the binary from the current package. go test sets the working
	// directory to the package directory (cmd/gov-lsp), so "." is correct.
	build := exec.Command("go", "build", "-o", testBinaryPath, ".")
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: build failed: %v\n%s\n", err, out)
		os.Exit(1)
	}

	os.Exit(m.Run())
}

// lspSession manages a running gov-lsp process.
type lspSession struct {
	t      *testing.T
	stdin  io.WriteCloser
	stdout *bufio.Reader
	proc   *exec.Cmd
}

// newLSPSession starts a gov-lsp binary and returns a session handle.
// The process is killed automatically when the test ends.
func newLSPSession(t *testing.T) *lspSession {
	t.Helper()

	policiesDir, err := filepath.Abs("../../policies")
	if err != nil {
		t.Fatalf("resolve policies dir: %v", err)
	}

	cmd := exec.Command(testBinaryPath, "--policies", policiesDir, "--log-level", "error")
	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	// Discard server stderr to keep test output clean; the server emits nothing
	// at the default "error" log level during normal operation.
	cmd.Stderr = nil

	if err := cmd.Start(); err != nil {
		t.Fatalf("start server: %v", err)
	}

	sess := &lspSession{
		t:      t,
		stdin:  stdinPipe,
		stdout: bufio.NewReader(stdoutPipe),
		proc:   cmd,
	}
	t.Cleanup(func() {
		stdinPipe.Close()
		if cmd.Process != nil {
			cmd.Process.Kill() //nolint:errcheck // best-effort cleanup
		}
		cmd.Wait() //nolint:errcheck // best-effort cleanup
	})
	return sess
}

// sendMsg marshals msg and writes it to the server as a Content-Length framed message.
func (s *lspSession) sendMsg(msg interface{}) {
	s.t.Helper()
	body, err := json.Marshal(msg)
	if err != nil {
		s.t.Fatalf("marshal LSP message: %v", err)
	}
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))
	if _, err := io.WriteString(s.stdin, header); err != nil {
		s.t.Fatalf("write header: %v", err)
	}
	if _, err := s.stdin.Write(body); err != nil {
		s.t.Fatalf("write body: %v", err)
	}
}

// recvMsg reads one LSP message from the server, failing the test on timeout.
func (s *lspSession) recvMsg(timeout time.Duration) map[string]interface{} {
	s.t.Helper()

	type result struct {
		msg map[string]interface{}
		err error
	}
	ch := make(chan result, 1)

	go func() {
		// Read headers.
		contentLength := -1
		for {
			line, err := s.stdout.ReadString('\n')
			if err != nil {
				ch <- result{err: err}
				return
			}
			line = strings.TrimRight(line, "\r\n")
			if line == "" {
				break // end of headers
			}
			if strings.HasPrefix(line, "Content-Length:") {
				val := strings.TrimSpace(strings.TrimPrefix(line, "Content-Length:"))
				if n, err := strconv.Atoi(val); err == nil {
					contentLength = n
				}
			}
		}
		if contentLength < 0 {
			ch <- result{err: fmt.Errorf("missing Content-Length header")}
			return
		}

		// Read body.
		body := make([]byte, contentLength)
		if _, err := io.ReadFull(s.stdout, body); err != nil {
			ch <- result{err: err}
			return
		}

		var msg map[string]interface{}
		if err := json.Unmarshal(body, &msg); err != nil {
			ch <- result{err: fmt.Errorf("unmarshal: %w (body: %s)", err, body)}
			return
		}
		ch <- result{msg: msg}
	}()

	select {
	case r := <-ch:
		if r.err != nil {
			s.t.Fatalf("recvMsg: %v", r.err)
		}
		return r.msg
	case <-time.After(timeout):
		s.t.Fatalf("recvMsg: timed out after %v", timeout)
		return nil
	}
}

// recvUntil reads messages until pred returns true, returning the matching message.
// It drops server-sent notifications (e.g. publishDiagnostics) until the target is found.
func (s *lspSession) recvUntil(timeout time.Duration, pred func(map[string]interface{}) bool) map[string]interface{} {
	s.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		msg := s.recvMsg(remaining)
		if pred(msg) {
			return msg
		}
	}
	s.t.Fatalf("recvUntil: no matching message received within %v", timeout)
	return nil
}

// isMethod returns true when msg carries the given method.
func isMethod(method string) func(map[string]interface{}) bool {
	return func(msg map[string]interface{}) bool {
		return msg["method"] == method
	}
}

// hasID returns true when msg carries a response ID (i.e. it is a response, not a notification).
func hasID(id float64) func(map[string]interface{}) bool {
	return func(msg map[string]interface{}) bool {
		v, ok := msg["id"]
		if !ok {
			return false
		}
		n, ok := v.(float64)
		return ok && n == id
	}
}

// ---- End-to-end tests --------------------------------------------------------

// TestE2E_InitializeHandshake verifies that the server responds to initialize with
// correct capabilities and that the initialized notification receives no reply.
func TestE2E_InitializeHandshake(t *testing.T) {
	sess := newLSPSession(t)

	// Send initialize request.
	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params":  map[string]interface{}{"processId": nil, "rootUri": "file:///workspace", "capabilities": map[string]interface{}{}},
	})

	resp := sess.recvMsg(5 * time.Second)

	// Must be a response (has id=1).
	if resp["id"] != float64(1) {
		t.Fatalf("expected response id=1, got %v", resp["id"])
	}
	result, ok := resp["result"].(map[string]interface{})
	if !ok {
		t.Fatalf("initialize result type = %T, want map", resp["result"])
	}
	caps, ok := result["capabilities"].(map[string]interface{})
	if !ok {
		t.Fatalf("capabilities type = %T, want map", result["capabilities"])
	}
	if caps["textDocumentSync"] != float64(1) {
		t.Errorf("textDocumentSync = %v, want 1", caps["textDocumentSync"])
	}
	if caps["codeActionProvider"] != true {
		t.Errorf("codeActionProvider = %v, want true", caps["codeActionProvider"])
	}

	// Send initialized notification — must NOT receive a response.
	// We send it and then immediately send a shutdown to flush any pending output.
	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "method": "initialized", "params": map[string]interface{}{}})
	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": nil})

	// The next message MUST be the shutdown response (id=99), not a response to initialized.
	shutdownResp := sess.recvMsg(5 * time.Second)
	if shutdownResp["id"] != float64(99) {
		t.Errorf("expected shutdown response id=99, got %v — server may have responded to initialized notification", shutdownResp["id"])
	}
}

// TestE2E_DidOpen_ViolatingFile verifies the full diagnostics pipeline:
// open a lowercase .md file → receive publishDiagnostics with the expected violation.
func TestE2E_DidOpen_ViolatingFile(t *testing.T) {
	sess := newLSPSession(t)
	handshake(t, sess)

	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "textDocument/didOpen",
		"params": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"uri":        "file:///workspace/lower_case.md",
				"languageId": "markdown",
				"version":    1,
				"text":       "# hello\n",
			},
		},
	})

	notif := sess.recvUntil(5*time.Second, isMethod("textDocument/publishDiagnostics"))

	params, ok := notif["params"].(map[string]interface{})
	if !ok {
		t.Fatalf("params type = %T", notif["params"])
	}
	if params["uri"] != "file:///workspace/lower_case.md" {
		t.Errorf("uri = %v, want file:///workspace/lower_case.md", params["uri"])
	}
	diags, ok := params["diagnostics"].([]interface{})
	if !ok || len(diags) == 0 {
		t.Fatalf("expected at least one diagnostic, got %v", params["diagnostics"])
	}

	diag, ok := diags[0].(map[string]interface{})
	if !ok {
		t.Fatalf("diagnostic type = %T", diags[0])
	}
	if diag["code"] != "markdown-naming-violation" {
		t.Errorf("code = %v, want markdown-naming-violation", diag["code"])
	}
	if diag["severity"] != float64(1) {
		t.Errorf("severity = %v, want 1 (error)", diag["severity"])
	}
	if diag["source"] != "gov-lsp" {
		t.Errorf("source = %v, want gov-lsp", diag["source"])
	}
	// Fix data must be embedded in the diagnostic.
	data, ok := diag["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("diagnostic.data type = %T, want map", diag["data"])
	}
	if data["type"] != "rename" {
		t.Errorf("fix type = %v, want rename", data["type"])
	}
	if data["value"] != "LOWER_CASE.md" {
		t.Errorf("fix value = %v, want LOWER_CASE.md", data["value"])
	}
}

// TestE2E_DidOpen_CompliantFile verifies that a SCREAMING_SNAKE_CASE .md file
// triggers publishDiagnostics with an empty array (no false positives).
func TestE2E_DidOpen_CompliantFile(t *testing.T) {
	sess := newLSPSession(t)
	handshake(t, sess)

	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "textDocument/didOpen",
		"params": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"uri":        "file:///workspace/UPPER_CASE.md",
				"languageId": "markdown",
				"version":    1,
				"text":       "# valid\n",
			},
		},
	})

	notif := sess.recvUntil(5*time.Second, isMethod("textDocument/publishDiagnostics"))
	params, ok := notif["params"].(map[string]interface{})
	if !ok {
		t.Fatalf("params type = %T", notif["params"])
	}
	diags, ok := params["diagnostics"].([]interface{})
	if !ok {
		t.Fatalf("diagnostics type = %T", params["diagnostics"])
	}
	if len(diags) != 0 {
		t.Errorf("expected empty diagnostics for compliant file, got %d", len(diags))
	}
}

// TestE2E_CodeAction_RenameRoundTrip is the key end-to-end proof for W-0003:
// open a violating file, capture the diagnostic the server emits, send that
// diagnostic back in a codeAction request, and assert the server returns a
// WorkspaceEdit rename to the correct target filename.
func TestE2E_CodeAction_RenameRoundTrip(t *testing.T) {
	sess := newLSPSession(t)
	handshake(t, sess)

	const fileURI = "file:///workspace/lower_case.md"

	// 1. Open the violating file.
	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "textDocument/didOpen",
		"params": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"uri": fileURI, "languageId": "markdown", "version": 1,
				"text": "# hello\n",
			},
		},
	})

	// 2. Wait for the publishDiagnostics notification.
	notif := sess.recvUntil(5*time.Second, isMethod("textDocument/publishDiagnostics"))
	params := notif["params"].(map[string]interface{})
	diags := params["diagnostics"].([]interface{})
	if len(diags) == 0 {
		t.Fatal("expected diagnostics, got none")
	}
	// Use the raw diagnostic from the server in the codeAction request.
	serverDiag := diags[0]

	// 3. Send codeAction request carrying the server-emitted diagnostic.
	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      10,
		"method":  "textDocument/codeAction",
		"params": map[string]interface{}{
			"textDocument": map[string]interface{}{"uri": fileURI},
			"range": map[string]interface{}{
				"start": map[string]interface{}{"line": 0, "character": 0},
				"end":   map[string]interface{}{"line": 0, "character": 0},
			},
			"context": map[string]interface{}{
				"diagnostics": []interface{}{serverDiag},
			},
		},
	})

	// 4. Receive the codeAction response.
	resp := sess.recvUntil(5*time.Second, hasID(10))
	if resp["error"] != nil {
		t.Fatalf("codeAction returned error: %v", resp["error"])
	}

	actions, ok := resp["result"].([]interface{})
	if !ok || len(actions) == 0 {
		t.Fatalf("expected code actions, got %v", resp["result"])
	}

	action, ok := actions[0].(map[string]interface{})
	if !ok {
		t.Fatalf("action type = %T", actions[0])
	}
	if action["kind"] != "quickfix" {
		t.Errorf("kind = %v, want quickfix", action["kind"])
	}

	edit, ok := action["edit"].(map[string]interface{})
	if !ok {
		t.Fatalf("edit type = %T", action["edit"])
	}
	changes, ok := edit["documentChanges"].([]interface{})
	if !ok || len(changes) == 0 {
		t.Fatalf("expected documentChanges, got %v", edit)
	}

	change, ok := changes[0].(map[string]interface{})
	if !ok {
		t.Fatalf("change type = %T", changes[0])
	}
	if change["kind"] != "rename" {
		t.Errorf("change kind = %v, want rename", change["kind"])
	}
	if change["oldUri"] != fileURI {
		t.Errorf("oldUri = %v, want %v", change["oldUri"], fileURI)
	}
	if change["newUri"] != "file:///workspace/LOWER_CASE.md" {
		t.Errorf("newUri = %v, want file:///workspace/LOWER_CASE.md", change["newUri"])
	}
}

// TestE2E_Shutdown verifies the shutdown + exit handshake.
func TestE2E_Shutdown(t *testing.T) {
	sess := newLSPSession(t)
	handshake(t, sess)

	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": nil})
	resp := sess.recvMsg(5 * time.Second)
	if resp["id"] != float64(99) {
		t.Errorf("shutdown response id = %v, want 99", resp["id"])
	}
	if resp["result"] != nil {
		t.Errorf("shutdown result = %v, want null", resp["result"])
	}

	// exit is a notification — server exits, no response expected.
	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "method": "exit", "params": nil})

	// Process should exit cleanly within 2s.
	done := make(chan error, 1)
	go func() { done <- sess.proc.Wait() }()
	select {
	case <-done:
		// exited, any exit code is acceptable (SIGKILL from cleanup vs clean exit)
	case <-time.After(2 * time.Second):
		t.Error("server did not exit within 2s after exit notification")
	}
}

// TestE2E_UnknownMethod verifies that unknown methods with an ID return a -32601 error.
func TestE2E_UnknownMethod(t *testing.T) {
	sess := newLSPSession(t)
	handshake(t, sess)

	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      5,
		"method":  "textDocument/unknownMethod",
		"params":  nil,
	})

	resp := sess.recvMsg(5 * time.Second)
	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected error response, got result: %v", resp["result"])
	}
	if errObj["code"] != float64(-32601) {
		t.Errorf("error code = %v, want -32601", errObj["code"])
	}
}

// newLSPSessionWithTraceFile starts gov-lsp with the --trace-file flag and
// returns both the session handle and the path to the trace file.
// The trace file is removed automatically when the test ends.
func newLSPSessionWithTraceFile(t *testing.T) (*lspSession, string) {
	t.Helper()

	policiesDir, err := filepath.Abs("../../policies")
	if err != nil {
		t.Fatalf("resolve policies dir: %v", err)
	}

	tf, err := os.CreateTemp("", "gov-lsp-trace-*")
	if err != nil {
		t.Fatalf("create trace file: %v", err)
	}
	tracePath := tf.Name()
	tf.Close() //nolint:errcheck
	t.Cleanup(func() { os.Remove(tracePath) }) //nolint:errcheck

	cmd := exec.Command(testBinaryPath,
		"--policies", policiesDir,
		"--log-level", "error",
		"--trace-file", tracePath,
	)
	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	cmd.Stderr = nil

	if err := cmd.Start(); err != nil {
		t.Fatalf("start server: %v", err)
	}

	sess := &lspSession{
		t:      t,
		stdin:  stdinPipe,
		stdout: bufio.NewReader(stdoutPipe),
		proc:   cmd,
	}
	t.Cleanup(func() {
		stdinPipe.Close()
		if cmd.Process != nil {
			cmd.Process.Kill() //nolint:errcheck
		}
		cmd.Wait() //nolint:errcheck
	})
	return sess, tracePath
}

// TestE2E_TraceFile verifies that --trace-file mirrors LSP output to a file.
// This is the foundation for the headless-agent integration test: the trace
// file lets the CI script assert that publishDiagnostics was emitted during an
// agent session without relying solely on filesystem outcome.
func TestE2E_TraceFile(t *testing.T) {
	sess, tracePath := newLSPSessionWithTraceFile(t)
	handshake(t, sess)

	// Open a violating file — gov-lsp must emit publishDiagnostics.
	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "textDocument/didOpen",
		"params": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"uri":        "file:///workspace/my-notes.md",
				"languageId": "markdown",
				"version":    1,
				"text":       "# notes\n",
			},
		},
	})

	// Wait for the publishDiagnostics notification.
	_ = sess.recvUntil(5*time.Second, isMethod("textDocument/publishDiagnostics"))

	// Flush by sending shutdown and waiting for the response.  writeMessage
	// calls bufio.Writer.Flush() after every message, so all LSP output —
	// including the publishDiagnostics above — is durably in the trace file
	// before we receive the shutdown response.  No sleep is required.
	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": nil})
	_ = sess.recvUntil(5*time.Second, hasID(99))

	traceBytes, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatalf("read trace file: %v", err)
	}
	trace := string(traceBytes)

	if !strings.Contains(trace, `"textDocument/publishDiagnostics"`) {
		t.Errorf("trace file does not contain publishDiagnostics; trace:\n%s", trace)
	}
	if !strings.Contains(trace, `"markdown-naming-violation"`) {
		t.Errorf("trace file does not contain markdown-naming-violation; trace:\n%s", trace)
	}
}


func handshake(t *testing.T, sess *lspSession) {
	t.Helper()
	sess.sendMsg(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      0,
		"method":  "initialize",
		"params":  map[string]interface{}{"processId": nil, "rootUri": "file:///workspace", "capabilities": map[string]interface{}{}},
	})
	_ = sess.recvUntil(5*time.Second, hasID(0)) // consume the initialize response
	sess.sendMsg(map[string]interface{}{"jsonrpc": "2.0", "method": "initialized", "params": map[string]interface{}{}})
}
