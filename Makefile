# Makefile for GOV-LSP
# Run `make help` to see available targets.

BINARY     := gov-lsp
BUILD_DIR  := .
CMD        := ./cmd/gov-lsp
POLICIES   ?= ./policies

.PHONY: help build test vet smoke check-policy clean

## help: print this help message
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build:"
	@echo "  build          build the $(BINARY) binary in the repo root"
	@echo ""
	@echo "Quality:"
	@echo "  test           run all unit tests (go test ./...)"
	@echo "  vet            run go vet ./..."
	@echo "  smoke          build + run the end-to-end smoke test"
	@echo "  check-policy   run the batch policy check against the whole repo"
	@echo "                 (demonstrates self-governance — shows real violations)"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean          remove built binaries"
	@echo ""
	@echo "Variables:"
	@echo "  POLICIES=<dir> path to .rego policy files (default: ./policies)"

## build: compile the gov-lsp binary
build:
	go build -o $(BUILD_DIR)/$(BINARY) $(CMD)

## test: run the full Go test suite
test:
	go test ./... -count=1

## vet: run go vet
vet:
	go vet ./...

## smoke: build the binary and run the end-to-end smoke test
smoke: build
	GOV_LSP_POLICIES=$(POLICIES) ./scripts/smoke_test.sh ./$(BINARY)

## check-policy: run gov-lsp in batch check mode against the whole repo.
## Exit code 1 if any policy violations are found.
## Use POLICIES=<dir> to override the policy directory.
check-policy: build
	@echo "Running self-governance check (POLICIES=$(POLICIES))..."
	@GOV_LSP_POLICIES=$(POLICIES) ./$(BINARY) check . || \
		(echo "" && echo "Tip: violations above are expected in this repo (docs use lowercase names to"; \
		 echo "     demonstrate the policy in action). In a consumer repo these would be real errors."; \
		 exit 1)

## clean: remove the built binary
clean:
	rm -f $(BUILD_DIR)/$(BINARY)
