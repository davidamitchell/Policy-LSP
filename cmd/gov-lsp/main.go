// gov-lsp is a governance Language Server that enforces project policies
// defined as Rego rules and reports violations as LSP Diagnostics.
//
// Usage (LSP server mode):
//
//	gov-lsp [--policies <dir>] [--log-level debug|info|warn|error]
//
// Usage (batch check mode):
//
//	gov-lsp check [--policies <dir>] [--format text|json] [path...]
//
// Usage (MCP server mode):
//
//	gov-lsp mcp [--policies <dir>]
//
// Usage (version):
//
//	gov-lsp --version
//
// In server mode the server reads JSON-RPC messages from stdin and writes
// responses to stdout.  In check mode it walks the given paths, evaluates each
// file against all loaded policies, prints violations to stdout, and exits 1 if
// any violations are found (0 if clean).  In MCP mode it runs a Model Context
// Protocol stdio server exposing gov_check_file and gov_check_workspace as tools.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	iofs "io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/davidamitchell/policy-lsp/internal/engine"
	"github.com/davidamitchell/policy-lsp/internal/lsp"
)

// Version is the current release version of gov-lsp.
const Version = "0.1.0"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "-version", "version":
			fmt.Println(Version)
			return
		case "check":
			os.Exit(checkMain(os.Args[2:]))
		case "mcp":
			mcpMain(os.Args[2:])
			return
		}
	}
	runServer()
}

// ---- check subcommand --------------------------------------------------------

// CheckResult holds a single policy violation produced by the check subcommand.
type CheckResult struct {
	File    string                 `json:"file"`
	ID      string                 `json:"id"`
	Level   string                 `json:"level"`
	Message string                 `json:"message"`
	Fix     map[string]interface{} `json:"fix,omitempty"`
}

// checkMain parses flags and executes the "check" subcommand.
func checkMain(args []string) int {
	checkFlags := flag.NewFlagSet("check", flag.ContinueOnError)
	policiesDir := checkFlags.String("policies", defaultPoliciesDir(), "directory containing .rego policy files")
	format := checkFlags.String("format", "text", "output format: text or json")
	logLevel := checkFlags.String("log-level", "debug", "log level: debug, info, warn, error")

	if err := checkFlags.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: %v\n", err)
		return 2
	}

	if env := os.Getenv("GOV_LSP_POLICIES"); env != "" {
		*policiesDir = env
	}

	// Configure structured logging to stderr for the check subcommand.
	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))
	slog.Debug("gov-lsp check: starting", "policies", *policiesDir, "format", *format, "log-level", *logLevel)

	paths := checkFlags.Args()
	if len(paths) == 0 {
		paths = []string{"."}
	}
	slog.Debug("gov-lsp check: paths", "paths", paths)

	eng, err := engine.NewFromDir(*policiesDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: loading policies: %v\n", err)
		return 1
	}

	count, err := runCheck(eng, paths, *format, os.Stdout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: %v\n", err)
		return 1
	}
	slog.Debug("gov-lsp check: complete", "violations", count)
	if count > 0 {
		return 1
	}
	return 0
}

// runCheck walks paths, evaluates each file against eng, and writes results to w.
// It returns the total number of violations found.
func runCheck(eng *engine.Engine, paths []string, format string, w io.Writer) (int, error) {
	ctx := context.Background()
	results := make([]CheckResult, 0)
	checked := 0

	for _, root := range paths {
		slog.Debug("gov-lsp check: walking", "root", root)
		if err := filepath.WalkDir(root, func(path string, d iofs.DirEntry, err error) error {
			if err != nil {
				return nil // skip unreadable entries
			}
			if d.IsDir() {
				// Skip hidden directories such as .git and .github.
				if strings.HasPrefix(filepath.Base(path), ".") && path != root {
					slog.Debug("gov-lsp check: skipping hidden dir", "path", path)
					return filepath.SkipDir
				}
				return nil
			}

			content, readErr := os.ReadFile(path)
			if readErr != nil {
				slog.Debug("gov-lsp check: skipping unreadable file", "path", path, "err", readErr)
				return nil // skip unreadable files
			}

			filename := filepath.Base(path)
			ext := filepath.Ext(filename)
			slog.Debug("gov-lsp check: evaluating file", "path", path, "filename", filename, "ext", ext)

			in := engine.Input{
				Filename:     filename,
				Extension:    ext,
				Path:         path,
				FileContents: string(content),
			}

			violations, evalErr := eng.Evaluate(ctx, in)
			if evalErr != nil {
				slog.Warn("gov-lsp check: evaluation error (skipped)", "path", path, "err", evalErr)
				return nil // log and continue; don't abort the walk
			}

			checked++
			if len(violations) > 0 {
				slog.Debug("gov-lsp check: violations found", "path", path, "count", len(violations))
			}
			for _, v := range violations {
				results = append(results, CheckResult{
					File:    path,
					ID:      v.ID,
					Level:   v.Level,
					Message: v.Message,
					Fix:     v.Fix,
				})
			}
			return nil
		}); err != nil {
			return len(results), fmt.Errorf("walking %s: %w", root, err)
		}
	}

	slog.Debug("gov-lsp check: walk complete", "files_checked", checked, "violations", len(results))

	switch format {
	case "json":
		data, err := json.MarshalIndent(results, "", "  ")
		if err != nil {
			return len(results), err
		}
		fmt.Fprintln(w, string(data))
	default: // text
		for _, r := range results {
			fmt.Fprintf(w, "%s: [%s] %s\n", r.File, r.ID, r.Message)
			if r.Fix != nil {
				fixType, _ := r.Fix["type"].(string)
				fixVal, _ := r.Fix["value"].(string)
				if fixType != "" && fixVal != "" {
					fmt.Fprintf(w, "  Fix (%s): %s\n", fixType, fixVal)
				}
			}
		}
		fmt.Fprintf(w, "\nChecked %d file(s). %d violation(s) found.\n", checked, len(results))
	}

	return len(results), nil
}

// ---- server mode -------------------------------------------------------------

// runServer starts the LSP server, reading JSON-RPC messages from stdin and
// writing responses and notifications to stdout.
func runServer() {
	policiesDir := flag.String("policies", defaultPoliciesDir(), "directory containing .rego policy files")
	logLevel := flag.String("log-level", "debug", "log level: debug, info, warn, error")
	flag.Parse()

	// Allow override via environment variable.
	if env := os.Getenv("GOV_LSP_POLICIES"); env != "" {
		*policiesDir = env
	}

	// Configure structured logging to stderr.
	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))
	slog.Info("gov-lsp server: starting", "policies", *policiesDir, "log-level", *logLevel)

	eng, err := engine.NewFromDir(*policiesDir)
	if err != nil {
		slog.Error("loading policies", "dir", *policiesDir, "err", err)
		os.Exit(1)
	}

	// Publisher writes LSP notifications to stdout.
	writer := bufio.NewWriter(os.Stdout)
	var writerMu sync.Mutex

	publish := func(notif lsp.Notification) {
		data, err := json.Marshal(notif)
		if err != nil {
			slog.Warn("gov-lsp server: failed to marshal notification", "method", notif.Method, "err", err)
			return
		}
		slog.Debug("gov-lsp server: sending notification", "method", notif.Method, "bytes", len(data))
		writerMu.Lock()
		defer writerMu.Unlock()
		writeMessage(writer, data)
	}

	handler := lsp.NewHandler(eng, publish)
	reader := bufio.NewReader(os.Stdin)
	ctx := context.Background()
	slog.Info("gov-lsp server: ready — listening on stdin")

	for {
		msg, err := readMessage(reader)
		if err != nil {
			if err == io.EOF {
				slog.Info("gov-lsp server: stdin closed — shutting down")
				return
			}
			slog.Warn("gov-lsp server: read error", "err", err)
			return
		}
		slog.Debug("gov-lsp server: received message", "bytes", len(msg))

		var req lsp.Request
		if err := json.Unmarshal(msg, &req); err != nil {
			slog.Warn("gov-lsp server: unmarshal error", "err", err)
			continue
		}
		slog.Debug("gov-lsp server: dispatching", "method", req.Method, "id", req.ID)

		resp := handler.Handle(ctx, &req)
		if resp != nil {
			data, err := json.Marshal(resp)
			if err != nil {
				slog.Warn("gov-lsp server: failed to marshal response", "method", req.Method, "err", err)
				continue
			}
			slog.Debug("gov-lsp server: sending response", "method", req.Method, "bytes", len(data))
			writerMu.Lock()
			writeMessage(writer, data)
			writerMu.Unlock()
		}
		// The LSP exit notification signals the server to terminate.
		if req.Method == "exit" {
			slog.Info("gov-lsp server: exit received — terminating")
			return
		}
	}
}

// defaultPoliciesDir returns the default policies directory, adjacent to the binary.
func defaultPoliciesDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "policies"
	}
	return filepath.Join(filepath.Dir(exe), "policies")
}

// readMessage reads one LSP message from r.
// Messages use the HTTP-like header format:
//
//	Content-Length: <n>\r\n
//	\r\n
//	<body>
func readMessage(r *bufio.Reader) ([]byte, error) {
	contentLength := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break // end of headers
		}
		if strings.HasPrefix(line, "Content-Length:") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "Content-Length:"))
			contentLength, err = strconv.Atoi(val)
			if err != nil {
				return nil, fmt.Errorf("invalid Content-Length: %w", err)
			}
		}
	}
	if contentLength < 0 {
		return nil, fmt.Errorf("missing Content-Length header")
	}
	body := make([]byte, contentLength)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	return body, nil
}

// writeMessage writes an LSP message with the appropriate header to w.
func writeMessage(w *bufio.Writer, data []byte) {
	fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(data))
	w.Write(data) //nolint:errcheck
	w.Flush()
}
