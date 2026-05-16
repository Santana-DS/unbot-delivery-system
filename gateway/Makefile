# UnBot Gateway — Makefile
.PHONY: run build tidy lint test

# Download dependencies and tidy go.sum
tidy:
	go mod tidy

# Run locally (requires .env in project root)
run:
	go run ./cmd/gateway/...

# Compile to a single static binary (suitable for Linux cloud VM)
build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
	go build -ldflags="-s -w" -o bin/gateway ./cmd/gateway/...

# Run tests across all packages
test:
	go test ./... -v -race

# Install and run golangci-lint (requires golangci-lint in PATH)
lint:
	golangci-lint run ./...
