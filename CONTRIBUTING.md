# Contributing to IsolatedTester

## Development Setup

**Requirements:**
- macOS 14 (Sonoma) or later
- Swift 5.10+ (ships with Xcode 15.4+)
- Xcode or Swift toolchain installed

**Build:**
```bash
swift build
```

**Test:**
```bash
swift test
```

**Release build:**
```bash
swift build -c release
```

**Install locally:**
```bash
make install  # Copies binaries to ~/.local/bin/
```

## Architecture

```
Package Targets:
  CLI                    → `isolated` binary (depends on Kit + ArgumentParser)
  IsolatedTesterKit      → Core library (no external dependencies)
  IsolatedServerCore     → Shared server logic (depends on Kit)
  IsolatedMCPServer      → `isolated-mcp` binary (depends on ServerCore)
  IsolatedHTTPServer     → `isolated-http` binary (depends on ServerCore + SwiftNIO)
```

### Key patterns:
- `SessionManager` is an **actor** — all session state is concurrency-safe
- `TestSession` uses **NSLock** for internal mutable state
- Error types are per-module (`ServerError`, `SessionError`, `AgentError`, etc.)
- All models are `Codable + Sendable`
- Logging uses `ISTLogger` (wraps `os.Logger` + stderr console)
- Input validation lives in `RequestValidator` (ServerCore)

## Adding a New MCP Tool

1. Add the tool definition to `MCPToolHandlers.listTools()` with JSON schema
2. Add a handler case to `MCPToolHandlers.handleToolCall()`
3. Use `SessionManager` methods for the implementation
4. Update `docs/mcp-tools.md` with documentation
5. Add tests

## Adding a New HTTP Endpoint

1. Add route matching in `Router.handle()` (follow existing if-else pattern)
2. Add handler method to Router
3. Add request/response types to `Models.swift` if needed
4. Add validation to `RequestValidator` if the endpoint accepts user input
5. Update `docs/openapi.yaml` with the new endpoint
6. Add tests

## Code Style

We use SwiftLint. Run before submitting:
```bash
swiftlint lint
```

## Pull Requests

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes with tests
4. Ensure `swift build` and `swift test` pass
5. Submit a PR with a clear description

## Commit Messages

Use imperative mood: "Add feature" not "Added feature" or "Adds feature".

Keep the first line under 72 characters. Add details in the body if needed.
