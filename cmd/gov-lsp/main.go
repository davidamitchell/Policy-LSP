// gov-lsp is a governance Language Server that enforces project policies
// defined as Rego rules and reports violations as LSP Diagnostics.
//
// Usage:
//
//	gov-lsp [--policies <dir>]
//
// The server reads JSON-RPC messages from stdin and writes responses to stdout.
// Diagnostic notifications are published to the client via
// textDocument/publishDiagnostics.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
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
	// Determine default policy directory relative to the binary.
	exe, err := os.Executable()
	if err != nil {
		exe = "."
	}
	defaultPolicies := filepath.Join(filepath.Dir(exe), "policies")

	policiesDir := flag.String("policies", defaultPolicies, "directory containing .rego policy files")
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
