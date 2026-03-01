// mcp.go implements the "gov-lsp mcp" subcommand: a Model Context Protocol
// stdio server that exposes policy checking as MCP tools.
//
// Transport: newline-delimited JSON-RPC 2.0 (one JSON object per line).
// Protocol version: 2024-11-05
//
// Exposed tools:
//
//	gov_check_file      – evaluate a single file against all loaded policies
//	gov_check_workspace – evaluate every file under a directory recursively
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	iofs "io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/davidamitchell/policy-lsp/internal/engine"
)

// mcpMain parses flags and runs the MCP stdio server.
func mcpMain(args []string) {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	policiesDir := fs.String("policies", defaultPoliciesDir(), "directory containing .rego policy files")

	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp mcp: %v\n", err)
		os.Exit(2)
	}

	if env := os.Getenv("GOV_LSP_POLICIES"); env != "" {
		*policiesDir = env
	}

	eng, err := engine.New(*policiesDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gov-lsp mcp: loading policies: %v\n", err)
		os.Exit(1)
	}

	runMCPServer(eng)
}

// ---- JSON-RPC types ----------------------------------------------------------

// mcpMsg is the minimal shape of every incoming MCP message.
type mcpMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// mcpResp is a JSON-RPC 2.0 response.
type mcpResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *mcpRPCError    `json:"error,omitempty"`
}

// mcpRPCError is the JSON-RPC error object.
type mcpRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// mcpToolContent is one content item inside a tool result.
type mcpToolContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// mcpToolResult is the MCP tool call result shape.
type mcpToolResult struct {
	Content []mcpToolContent `json:"content"`
	IsError bool             `json:"isError"`
}

// ---- server loop -------------------------------------------------------------

// runMCPServer reads newline-delimited JSON from stdin and writes responses
// to stdout until EOF.
func runMCPServer(eng *engine.Engine) {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)
	enc := json.NewEncoder(os.Stdout)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var msg mcpMsg
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			fmt.Fprintf(os.Stderr, "gov-lsp mcp: parse error: %v\n", err)
			continue
		}

		resp := dispatchMCP(eng, &msg)
		if resp == nil {
			continue // notification — no response
		}
		if err := enc.Encode(resp); err != nil {
			fmt.Fprintf(os.Stderr, "gov-lsp mcp: write error: %v\n", err)
		}
	}
}

// dispatchMCP routes an MCP message to the appropriate handler.
func dispatchMCP(eng *engine.Engine, msg *mcpMsg) *mcpResp {
	switch msg.Method {
	case "initialize":
		return &mcpResp{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result: map[string]interface{}{
				"protocolVersion": "2024-11-05",
				"capabilities":    map[string]interface{}{"tools": map[string]interface{}{}},
				"serverInfo":      map[string]interface{}{"name": "gov-lsp", "version": "0.1.0"},
			},
		}

	case "notifications/initialized", "initialized":
		return nil // notification — no response

	case "tools/list":
		return &mcpResp{
			JSONRPC: "2.0",
			ID:      msg.ID,
			Result:  map[string]interface{}{"tools": mcpToolDefinitions()},
		}

	case "tools/call":
		return handleMCPToolCall(eng, msg)

	case "shutdown":
		return &mcpResp{JSONRPC: "2.0", ID: msg.ID, Result: nil}

	case "exit":
		os.Exit(0)
		return nil

	default:
		if msg.ID != nil {
			return mcpErrorResp(msg.ID, -32601, "method not found: "+msg.Method)
		}
		return nil
	}
}

// mcpToolDefinitions returns the list of tool descriptors advertised to clients.
func mcpToolDefinitions() []interface{} {
	return []interface{}{
		map[string]interface{}{
			"name":        "gov_check_file",
			"description": "Check a single file against governance policies defined in Rego. Returns violations with ids, messages, levels, and optional fix suggestions.",
			"inputSchema": map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"path": map[string]interface{}{
						"type":        "string",
						"description": "Path to the file to check (absolute or relative to the workspace root)",
					},
				},
				"required": []string{"path"},
			},
		},
		map[string]interface{}{
			"name":        "gov_check_workspace",
			"description": "Check all files in a directory recursively against governance policies. Returns a summary and all violations found.",
			"inputSchema": map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"path": map[string]interface{}{
						"type":        "string",
						"description": "Workspace root directory to check (absolute or relative)",
					},
				},
				"required": []string{"path"},
			},
		},
	}
}

// ---- tool call handlers ------------------------------------------------------

// handleMCPToolCall dispatches a tools/call request to the correct tool handler.
func handleMCPToolCall(eng *engine.Engine, msg *mcpMsg) *mcpResp {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(msg.Params, &p); err != nil {
		return mcpErrorResp(msg.ID, -32600, "invalid params: "+err.Error())
	}

	switch p.Name {
	case "gov_check_file":
		var args struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(p.Arguments, &args); err != nil {
			return mcpErrorResp(msg.ID, -32600, "invalid arguments: "+err.Error())
		}
		return mcpCheckFile(eng, msg.ID, args.Path)

	case "gov_check_workspace":
		var args struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal(p.Arguments, &args); err != nil {
			return mcpErrorResp(msg.ID, -32600, "invalid arguments: "+err.Error())
		}
		return mcpCheckWorkspace(eng, msg.ID, args.Path)

	default:
		return mcpErrorResp(msg.ID, -32601, "unknown tool: "+p.Name)
	}
}

// mcpCheckFile evaluates a single file and returns a tool result.
func mcpCheckFile(eng *engine.Engine, id json.RawMessage, path string) *mcpResp {
	data, err := os.ReadFile(path)
	if err != nil {
		return mcpErrorResp(id, -32000, "cannot read file: "+err.Error())
	}

	in := engine.Input{
		Filename:     filepath.Base(path),
		Extension:    filepath.Ext(path),
		Path:         path,
		FileContents: string(data),
	}

	violations, err := eng.Evaluate(context.Background(), in)
	if err != nil {
		return mcpErrorResp(id, -32000, "evaluation error: "+err.Error())
	}

	text := formatMCPViolations(path, violations)
	return mcpToolResp(id, text, len(violations) > 0)
}

// mcpCheckWorkspace walks a directory and evaluates every file.
func mcpCheckWorkspace(eng *engine.Engine, id json.RawMessage, root string) *mcpResp {
	ctx := context.Background()
	type result struct {
		path    string
		level   string
		message string
	}
	var results []result

	walkErr := filepath.WalkDir(root, func(path string, d iofs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		// Skip hidden directories (.git, .github, etc.)
		if d.IsDir() && strings.HasPrefix(d.Name(), ".") && path != root {
			return filepath.SkipDir
		}
		if d.IsDir() {
			return nil
		}

		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}

		in := engine.Input{
			Filename:     filepath.Base(path),
			Extension:    filepath.Ext(path),
			Path:         path,
			FileContents: string(data),
		}

		violations, evalErr := eng.Evaluate(ctx, in)
		if evalErr != nil {
			return nil
		}

		for _, v := range violations {
			level := v.Level
			if level == "" {
				level = "error"
			}
			results = append(results, result{path: path, level: level, message: v.Message})
		}
		return nil
	})

	if walkErr != nil {
		return mcpErrorResp(id, -32000, "walk error: "+walkErr.Error())
	}

	var sb strings.Builder
	errCount := 0
	for _, r := range results {
		if r.level == "error" {
			errCount++
		}
		fmt.Fprintf(&sb, "[%s] %s: %s\n", strings.ToUpper(r.level), r.path, r.message)
	}

	var text string
	if len(results) == 0 {
		text = fmt.Sprintf("No policy violations found in %s", root)
	} else {
		text = fmt.Sprintf("%d violation(s) (%d error(s)) in %s:\n\n%s",
			len(results), errCount, root, sb.String())
	}

	return mcpToolResp(id, text, errCount > 0)
}

// ---- helpers -----------------------------------------------------------------

// formatMCPViolations produces a human-readable violation summary.
func formatMCPViolations(path string, violations []engine.Violation) string {
	if len(violations) == 0 {
		return fmt.Sprintf("No violations in %s", path)
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%d violation(s) in %s:\n", len(violations), path)
	for _, v := range violations {
		level := v.Level
		if level == "" {
			level = "error"
		}
		fmt.Fprintf(&sb, "  [%s] %s (id: %s)\n", strings.ToUpper(level), v.Message, v.ID)
		if v.Fix != nil {
			fixType, _ := v.Fix["type"].(string)
			fixVal, _ := v.Fix["value"].(string)
			if fixType != "" && fixVal != "" {
				fmt.Fprintf(&sb, "    Fix (%s): %s\n", fixType, fixVal)
			}
		}
	}
	return sb.String()
}

// mcpToolResp wraps text output in a standard MCP tool result response.
func mcpToolResp(id json.RawMessage, text string, isError bool) *mcpResp {
	return &mcpResp{
		JSONRPC: "2.0",
		ID:      id,
		Result: mcpToolResult{
			Content: []mcpToolContent{{Type: "text", Text: text}},
			IsError: isError,
		},
	}
}

// mcpErrorResp returns a JSON-RPC error response.
func mcpErrorResp(id json.RawMessage, code int, msg string) *mcpResp {
	return &mcpResp{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &mcpRPCError{Code: code, Message: msg},
	}
}
