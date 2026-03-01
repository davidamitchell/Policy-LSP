// gov-lsp is a governance Language Server that enforces project policies
// defined as Rego rules and reports violations as LSP Diagnostics.
//
// Usage (LSP server mode):
//
//	gov-lsp [--policies <dir>]
//
// Usage (batch check mode):
//
//	gov-lsp check [--policies <dir>] [--format text|json] [path...]
//
// Usage (MCP server mode):
//
//	gov-lsp mcp [--policies <dir>]
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
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/davidamitchell/policy-lsp/internal/engine"
	"github.com/davidamitchell/policy-lsp/internal/lsp"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
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

	if err := checkFlags.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: %v\n", err)
		return 2
	}

	if env := os.Getenv("GOV_LSP_POLICIES"); env != "" {
		*policiesDir = env
	}

	paths := checkFlags.Args()
	if len(paths) == 0 {
		paths = []string{"."}
	}

	eng, err := engine.New(*policiesDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: loading policies: %v\n", err)
		return 1
	}

	count, err := runCheck(eng, paths, *format, os.Stdout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp check: %v\n", err)
		return 1
	}
	if count > 0 {
		return 1
	}
	return 0
}

// runCheck walks paths, evaluates each file against eng, and writes results to w.
// It returns the total number of violations found.
func runCheck(eng *engine.Engine, paths []string, format string, w io.Writer) (int, error) {
	ctx := context.Background()
	var results []CheckResult
	checked := 0

	for _, root := range paths {
		if err := filepath.WalkDir(root, func(path string, d iofs.DirEntry, err error) error {
			if err != nil {
				return nil // skip unreadable entries
			}
			if d.IsDir() {
				// Skip hidden directories such as .git and .github.
				if strings.HasPrefix(filepath.Base(path), ".") && path != root {
					return filepath.SkipDir
				}
				return nil
			}

			content, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil // skip unreadable files
			}

			filename := filepath.Base(path)
			ext := filepath.Ext(filename)

			in := engine.Input{
				Filename:     filename,
				Extension:    ext,
				Path:         path,
				FileContents: string(content),
			}

			violations, evalErr := eng.Evaluate(ctx, in)
			if evalErr != nil {
				return nil // log and continue; don't abort the walk
			}

			checked++
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
	flag.Parse()

	// Allow override via environment variable.
	if env := os.Getenv("GOV_LSP_POLICIES"); env != "" {
		*policiesDir = env
	}

	eng, err := engine.New(*policiesDir)
	if err != nil {
		log.Fatalf("loading policies from %s: %v", *policiesDir, err)
	}

	// Publisher writes LSP notifications to stdout.
	writer := bufio.NewWriter(os.Stdout)
	var writerMu sync.Mutex

	publish := func(notif lsp.Notification) {
		data, err := json.Marshal(notif)
		if err != nil {
			return
		}
		writerMu.Lock()
		defer writerMu.Unlock()
		writeMessage(writer, data)
	}

	handler := lsp.NewHandler(eng, publish)
	reader := bufio.NewReader(os.Stdin)
	ctx := context.Background()

	for {
		msg, err := readMessage(reader)
		if err != nil {
			if err == io.EOF {
				return
			}
			log.Printf("read error: %v", err)
			return
		}

		var req lsp.Request
		if err := json.Unmarshal(msg, &req); err != nil {
			log.Printf("unmarshal error: %v", err)
			continue
		}

		resp := handler.Handle(ctx, &req)
		if resp != nil {
			data, err := json.Marshal(resp)
			if err != nil {
				continue
			}
			writerMu.Lock()
			writeMessage(writer, data)
			writerMu.Unlock()
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
