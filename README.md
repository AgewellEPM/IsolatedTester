# IsolatedTester

[![CI](https://github.com/AgewellEPM/IsolatedTester/actions/workflows/ci.yml/badge.svg)](https://github.com/AgewellEPM/IsolatedTester/actions/workflows/ci.yml)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

AI-powered isolated app testing for macOS. Launch any `.app` on a virtual display, control it with vision-based AI, and verify behavior — without taking over your screen.

## Quick Install (Claude Code Plugin)

```bash
git clone https://github.com/AgewellEPM/IsolatedTester.git && cd IsolatedTester && ./install.sh
```

This builds from source, installs binaries to `~/.local/bin/`, and configures the MCP server in Claude Code automatically. Then grant **Screen Recording** and **Accessibility** permissions in System Settings.

### Update

```bash
cd IsolatedTester && git pull && ./install.sh
```

### Uninstall

```bash
cd IsolatedTester && ./uninstall.sh
```

### Slash Commands

Once installed, these slash commands are available in Claude Code:

| Command | Description |
|---------|-------------|
| `/test-app <path> <objective>` | Launch and test a macOS app in an isolated virtual display |
| `/test-screenshot [session-id]` | Capture a screenshot from a running session |
| `/test-elements [session-id]` | Inspect accessibility elements of a running session |
| `/test-cleanup` | Stop all active test sessions |

### Verify Setup

Ask Claude Code to call the `setup_status` tool — it reports version, permissions, virtual display availability, and active sessions.

## What It Does

IsolatedTester creates invisible virtual displays using private CoreGraphics APIs, launches your app there, and lets an AI agent (Claude, GPT-4, or Claude Code CLI) drive the UI through a screenshot → reason → act loop. Your physical screen is never touched.

```
┌──────────────────────────────────────────────────────┐
│  You (CLI / HTTP / MCP)                              │
│    ↓                                                 │
│  SessionManager (actor)                              │
│    ↓                                                 │
│  TestSession                                         │
│    ├── VirtualDisplayManager  → invisible display    │
│    ├── AppLauncher            → launch .app on it    │
│    ├── InputController        → CGEvent synthesis    │
│    ├── ScreenCapture          → ScreenCaptureKit     │
│    └── AITestAgent            → vision → action loop │
│         ├── Anthropic API                            │
│         ├── OpenAI API                               │
│         └── Claude Code CLI                          │
└──────────────────────────────────────────────────────┘
```

## Advanced Installation

### Build from Source (Manual)

```bash
git clone https://github.com/AgewellEPM/IsolatedTester.git
cd IsolatedTester
swift build -c release
cp .build/release/isolated .build/release/isolated-mcp .build/release/isolated-http ~/.local/bin/
```

### Grant Permissions

IsolatedTester requires two macOS permissions:
- **Screen Recording** — for capturing screenshots via ScreenCaptureKit
- **Accessibility** — for synthesizing mouse/keyboard input via CGEvent

Check status: `isolated displays` (will prompt if needed)

### Usage

#### CLI

```bash
# List available displays
isolated displays

# Launch an app on a virtual display
isolated launch /Applications/Calculator.app

# Run an AI test
isolated test /Applications/Calculator.app \
  --objective "Calculate 5 + 3 and verify the result is 8" \
  --provider anthropic \
  --api-key $ANTHROPIC_API_KEY

# Take a screenshot
isolated screenshot --display 1
```

#### HTTP Server

```bash
# Start the server (default port 7100)
IST_TOKEN=my-secret-token isolated-http

# Create a session
curl -X POST http://localhost:7100/sessions \
  -H "Authorization: Bearer my-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"appPath": "/Applications/Calculator.app"}'

# Take a screenshot
curl -X POST http://localhost:7100/sessions/{id}/screenshot \
  -H "Authorization: Bearer my-secret-token"

# Run an AI test
curl -X POST http://localhost:7100/sessions/{id}/test \
  -H "Authorization: Bearer my-secret-token" \
  -H "Content-Type: application/json" \
  -d '{
    "objective": "Calculate 5 + 3 and verify the result is 8",
    "provider": "anthropic",
    "apiKey": "sk-ant-..."
  }'
```

See [docs/openapi.yaml](docs/openapi.yaml) for the full API specification.

#### MCP Server (Claude Code / Editor Integration)

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "isolated-tester": {
      "command": "/path/to/isolated-mcp",
      "args": []
    }
  }
}
```

Then in Claude Code:
> "Launch Calculator.app, click the 5 button, then +, then 3, then =, and screenshot to verify the result is 8"

Claude Code will use the MCP tools (`create_session`, `click`, `screenshot`, etc.) to execute the test autonomously.

See [docs/mcp-tools.md](docs/mcp-tools.md) for all available MCP tools.

## Configuration

Create `.isolatedtester.yml` in your project directory or `~/.isolatedtester.yml`:

```yaml
provider: anthropic
model: claude-sonnet-4-20250514
max_steps: 25
action_delay: 0.5

display:
  width: 1920
  height: 1080
  ppi: 144

retry:
  max_retries: 3
  backoff_multiplier: 2.0

timeouts:
  api_call: 60
  app_launch: 10
  session_total: 600
```

### API Key Resolution

Keys are resolved in priority order:
1. Explicit `--api-key` flag or request parameter
2. Environment variable (`ANTHROPIC_API_KEY` or `OPENAI_API_KEY`)
3. Config file (`.isolatedtester.yml`)
4. macOS Keychain (`com.isolatedtester.apikeys`)

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `IST_PORT` | HTTP server port | `7100` |
| `IST_TOKEN` | Bearer token for HTTP auth | (none, auth disabled) |
| `IST_CORS_ORIGINS` | Allowed CORS origins (comma-separated) | `http://localhost:*,http://127.0.0.1:*` |
| `IST_RATE_LIMIT` | Max requests per second per client | `10` |
| `IST_RATE_BURST` | Rate limit burst size | `100` |
| `IST_SESSION_IDLE_TIMEOUT` | Idle session timeout in seconds | `1800` (30 min) |
| `IST_SESSION_MAX_AGE` | Maximum session age in seconds | `7200` (2 hr) |
| `IST_LOG_FORMAT` | Log format: `text` or `json` | `text` |
| `IST_ENV` | Config profile (loads `.isolatedtester.{env}.yml`) | (none) |
| `ANTHROPIC_API_KEY` | Anthropic API key | (none) |
| `OPENAI_API_KEY` | OpenAI API key | (none) |

## Architecture

```
Package Targets:
  CLI                    → isolated binary (ArgumentParser)
  IsolatedTesterKit      → Core library (no dependencies)
  IsolatedServerCore     → Shared server logic (depends on Kit)
  IsolatedMCPServer      → MCP binary (depends on ServerCore)
  IsolatedHTTPServer     → HTTP binary (depends on ServerCore + SwiftNIO)
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `SessionManager` | `ServerCore/` | Actor managing concurrent test sessions |
| `TestSession` | `Kit/Session/` | Orchestrates display + app + input + capture |
| `AITestAgent` | `Kit/Agent/` | Vision-based AI test loop |
| `VirtualDisplayManager` | `Kit/Display/` | CGVirtualDisplay (private API) wrapper |
| `InputController` | `Kit/Input/` | CGEvent-based mouse/keyboard synthesis |
| `ScreenCapture` | `Kit/Capture/` | ScreenCaptureKit screenshot capture |
| `RequestValidator` | `ServerCore/` | Input validation for all request types |
| `CircuitBreaker` | `Kit/Resilience/` | Fault tolerance for AI provider calls |
| `AXIntrospector` | `Kit/Accessibility/` | macOS accessibility tree introspection |
| `RateLimiter` | `HTTPServer/` | Token bucket rate limiting |

## macOS Compatibility

| macOS Version | Status |
|---------------|--------|
| macOS 15 (Sequoia) | Fully supported |
| macOS 14 (Sonoma) | Fully supported |
| macOS 13 (Ventura) | Supported (CGVirtualDisplay may be unavailable) |
| macOS 12 and earlier | Not supported |

## Security

See [SECURITY.md](SECURITY.md) for the full security policy.

**Key points:**
- HTTP server binds to `127.0.0.1` only (not network-accessible)
- Bearer token authentication for HTTP API
- Input validation on all request parameters
- Rate limiting to prevent abuse
- Session timeouts to prevent resource leaks
- API keys stored securely in macOS Keychain

## Privacy Policy

See [PRIVACY.md](PRIVACY.md) for the full privacy policy.

**Key points:**
- Local-first: all captures and reports are owner-private files on your machine
- No telemetry, no analytics, no developer-operated servers — we never see your data
- Only `run_test` sends session screenshots to the AI provider **you** configure, with **your** API key
- Captures come only from apps/VMs you explicitly launch in isolated sessions — never your real desktop
- You control retention; delete local data directories or run `./uninstall.sh` at any time

## Local capture, control and recording verification

Permission preflight (`setup_status`) does not prove that capture works. Verify a
fresh installed `isolated-mcp` process with `session_frame` and observable input
results. Native sessions use a virtual display or an off-screen window in the
same macOS login; this is visual isolation, not a VM or a security sandbox.

ScreenCaptureKit callbacks have cancellation-aware deadlines. If window content
discovery or image capture stalls, the session switches to bounded native
`screencapture -l WINDOW_ID` capture of the target PID's window. Screen Recording
permission is still required; this fallback never captures the whole desktop.
The first stalled request can take about ten seconds before fallback. Subsequent
window captures reuse the working backend. Display-only capture reports its own
timeout rather than widening the target.

`session_frame` images and `click`/drag coordinates are relative to the app's
largest normal window, including sessions with virtual displays. Accessibility
`click_element` coordinates remain global. Use TinkyVision's local
`vision_find_text(inPath: session_frame.path)` to read that exact frame; a physical
TinkyStream snapshot is a separate observation and is not the isolated app frame.
Single left clicks first try the target application's accessibility action at the
grounded point, then use process-targeted mouse events for controls without one.
The action receipt records the chosen path. An event dispatch acknowledgement
does not establish that a canvas, game or VM accepted the input; observe its next
frame. Those targets require their own live input validation.

The existing recording loop captures at approximately 1 FPS into a 300-frame
ring. `stop_session` finalizes `~/.isolated-tester/sessions/ID/session.mp4` and its
metadata/receipts. The MP4 uses 6 FPS **playback**, so it is a timelapse. Pausing
recording retains the ring; resuming continues it. Inspect fresh frames, the
evidence chain and a decoded MP4 before reporting success.

With Calculator closed, no other guest/test active, granted macOS permissions,
installed TinkyVision helpers, Python 3, Node and ffmpeg available:

```sh
python3 scripts/verify_offline.py --out /private/tmp/isolated-offline-check
```

The script starts one disposable Calculator session using the installed MCP,
checks typed arithmetic and screenshot-based clicking with local OCR, exercises
pause/resume, verifies the receipt chain, decodes the finalized video, then checks
app/display cleanup. It denies IP networking to its two MCP servers and inherited
helpers while allowing local macOS IPC. It does not disable the host's network or
sandbox apps launched by LaunchServices. Raw evidence stays in the chosen private
output directory. `--diagnose-with-network` is diagnostic and is not offline proof.

Existing editor MCP connections keep the old binary loaded until reconnected.
`setup_status` exposes the server PID and executable path to identify the process.
Do not terminate another connection's sessions while updating installed files.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

[MIT](LICENSE)
