# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public GitHub issue**
2. Email security details to the repository maintainers via GitHub's private vulnerability reporting feature
3. Include a description of the vulnerability, steps to reproduce, and potential impact
4. You will receive an acknowledgment within 48 hours
5. A fix will be developed and released within 7 days for critical issues

## Security Model

### Network Binding
- The HTTP server binds exclusively to `127.0.0.1` (localhost). It is **not** accessible from the network.
- The MCP server communicates over stdin/stdout with its parent process only.

### Authentication
- HTTP API supports Bearer token authentication via the `IST_TOKEN` environment variable
- When `IST_TOKEN` is set, all endpoints (except `GET /health` and `OPTIONS`) require a valid `Authorization: Bearer <token>` header
- MCP server relies on the parent process for access control (stdin/stdout channel)

### API Key Storage
- API keys for AI providers (Anthropic, OpenAI) are resolved in priority order: explicit parameter > environment variable > config file > macOS Keychain
- Keychain storage uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for maximum security
- API keys are never logged or included in error messages

### Input Validation
- All request payloads are validated for bounds, types, and path safety
- App paths are checked for existence, `.app` bundle format, and path traversal attempts
- Coordinate values are bounds-checked against display dimensions
- String inputs have maximum length limits to prevent memory exhaustion

### Session Isolation
- Each test session operates independently with its own display, app process, and input controller
- Sessions are automatically cleaned up after configurable idle timeout (default: 30 minutes)
- Maximum session age is enforced (default: 2 hours)

### Rate Limiting
- HTTP API supports configurable rate limiting per client IP
- Prevents resource exhaustion from excessive requests

### macOS Permissions
- Requires **Screen Recording** permission (for screenshots via ScreenCaptureKit)
- Requires **Accessibility** permission (for input synthesis via CGEvent)
- Permission status is checked at runtime and reported via the `/permissions` endpoint

## Known Limitations

### Private API Usage
IsolatedTester uses `CGVirtualDisplay` (a private CoreGraphics API) to create isolated virtual displays. This API:
- Is not documented or supported by Apple
- Could change or be removed in future macOS versions
- May not pass App Store review
- Has a graceful fallback to the main display when unavailable

### Sandbox Status
The app runs without App Sandbox (`com.apple.security.app-sandbox: false`) because it needs to:
- Launch and control arbitrary applications
- Synthesize input events system-wide
- Access ScreenCaptureKit for arbitrary windows

This is inherent to the tool's purpose as a UI testing framework.
