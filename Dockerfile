# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM golang:1.24-alpine AS builder

RUN apk add --no-cache git ca-certificates

WORKDIR /src

# Cache module downloads separately from the build.
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the source.
COPY . .

# Build a fully static binary.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w -extldflags '-static'" \
    -o /gov-lsp ./cmd/gov-lsp

# ---- Runtime stage ----
FROM scratch

# Include CA certificates for any HTTPS calls the OPA SDK might make.
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the static binary and the policies.
COPY --from=builder /gov-lsp /gov-lsp
COPY --from=builder /src/policies /policies

# The server reads from stdin and writes to stdout.
ENTRYPOINT ["/gov-lsp", "--policies", "/policies"]
