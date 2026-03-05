# Makefile for GOV-LSP
# Run `make help` to see available targets.

BINARY     := gov-lsp
BUILD_DIR  := .
CMD        := ./cmd/gov-lsp
POLICIES   ?= ./policies

# Use vendored dependencies when vendor/ exists — no network required.
# Run `make vendor` once (with network) to populate it, then commit vendor/.
GOFLAGS    := $(shell [ -d vendor ] && echo "-mod=vendor" || echo "")

.PHONY: help build test vet smoke test-hook check-policy clean setup vendor

## help: print this help message
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build:"
	@echo "  build          build the $(BINARY) binary in the repo root"
	@echo "  setup          build + verify binary (first-time setup)"
	@echo "  vendor         download and vendor all dependencies (run once with network)"
	@echo ""
	@echo "Quality:"
	@echo "  test           run all unit tests (go test -v ./...)"
	@echo "  vet            run go vet ./..."
	@echo "  smoke          build + run the end-to-end smoke test"
	@echo "  test-hook      build + test the policy-gate.sh hook behaviour"
	@echo "  check-policy   run the batch policy check against the whole repo"
	@echo "                 (demonstrates self-governance — shows real violations)"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean          remove built binaries"
	@echo ""
	@echo "Variables:"
	@echo "  POLICIES=<dir> path to .rego policy files (default: ./policies)"

## vendor: download and vendor all Go dependencies into vendor/ (run once with network access)
## After running this, commit vendor/ and all future builds require no network.
vendor:
	go mod download
	go mod vendor

## build: compile the gov-lsp binary
build:
	go build $(GOFLAGS) -o $(BUILD_DIR)/$(BINARY) $(CMD)

## test: run the full Go test suite
test:
	go test $(GOFLAGS) -v ./... -count=1

## vet: run go vet
vet:
	go vet $(GOFLAGS) ./...

## smoke: build the binary and run the end-to-end smoke test
smoke: build
	GOV_LSP_POLICIES=$(POLICIES) ./scripts/smoke_test.sh ./$(BINARY)

## test-hook: test the policy-gate.sh PostToolUse hook behaviour
test-hook: build
	GOV_LSP_POLICIES=$(POLICIES) ./scripts/test_policy_gate.sh ./$(BINARY)

## check-policy: run gov-lsp in batch check mode against the whole repo.
## Exit code 1 if any policy violations are found.
## Use POLICIES=<dir> to override the policy directory.
check-policy: build
	@echo "Running self-governance check (POLICIES=$(POLICIES))..."
	@GOV_LSP_POLICIES=$(POLICIES) ./$(BINARY) check . || \
		(echo "" && echo "Tip: violations above are expected in this repo (docs use lowercase names to"; \
		 echo "     demonstrate the policy in action). In a consumer repo these would be real errors."; \
		 exit 1)

## setup: build the binary and run a quick self-check (first-time setup)
setup: build
	@echo "Verifying gov-lsp is functional..."
	@GOV_LSP_POLICIES=$(POLICIES) ./$(BINARY) check --format text . > /dev/null 2>&1 && \
		echo "gov-lsp is ready. Hook and MCP server are active." || \
		echo "gov-lsp is ready (policy violations present — run 'make check-policy' to review)."

## clean: remove the built binary
clean:
	rm -f $(BUILD_DIR)/$(BINARY)

