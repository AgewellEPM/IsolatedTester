#!/bin/bash
set -euo pipefail

# IsolatedTester — Claude Code Plugin Installer
# Builds from source and configures as a Claude Code MCP server.

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

BIN_DIR="$HOME/.local/bin"
BINARIES=(isolated isolated-mcp isolated-http)

info()  { echo -e "${BOLD}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

# ── Prerequisites ──────────────────────────────────────────────

info "Checking prerequisites..."

[[ "$(uname)" == "Darwin" ]] || fail "IsolatedTester requires macOS."

if ! command -v swift &>/dev/null; then
    fail "Swift toolchain not found. Install Xcode or Xcode Command Line Tools:\n  xcode-select --install"
fi

if ! xcode-select -p &>/dev/null; then
    fail "Xcode Command Line Tools not installed:\n  xcode-select --install"
fi

SWIFT_VERSION=$(swift --version 2>&1 | head -1)
ok "Swift found: $SWIFT_VERSION"

# ── Build ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info "Building IsolatedTester (release)..."
swift build -c release 2>&1 | tail -3

BUILD_DIR=".build/release"
for bin in "${BINARIES[@]}"; do
    [[ -f "$BUILD_DIR/$bin" ]] || fail "Build failed: $BUILD_DIR/$bin not found."
done
ok "Build succeeded."

# ── Install binaries ──────────────────────────────────────────

info "Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"

for bin in "${BINARIES[@]}"; do
    cp "$BUILD_DIR/$bin" "$BIN_DIR/$bin"
done
ok "Binaries installed."

# Ensure ~/.local/bin is on PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not on your PATH."
    echo "  Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# ── Configure Claude Code ─────────────────────────────────────

info "Configuring Claude Code MCP server..."

if command -v claude &>/dev/null; then
    # Remove existing config first (idempotent)
    claude mcp remove isolated-tester 2>/dev/null || true
    claude mcp add isolated-tester -- "$BIN_DIR/isolated-mcp"
    ok "Claude Code MCP server configured."
else
    warn "Claude Code CLI not found. Add manually to ~/.claude/settings.json:"
    echo '  {
    "mcpServers": {
      "isolated-tester": {
        "command": "'"$BIN_DIR/isolated-mcp"'",
        "args": []
      }
    }
  }'
    echo ""
fi

# ── Verify ─────────────────────────────────────────────────────

info "Verifying installation..."
if "$BIN_DIR/isolated-mcp" <<< '{"jsonrpc":"2.0","id":1,"method":"ping"}' 2>/dev/null | head -1 | grep -q '"jsonrpc"'; then
    ok "MCP server responds to ping."
else
    warn "Could not verify MCP server (may need permissions granted first)."
fi

# ── Done ───────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}IsolatedTester installed successfully!${NC}"
echo ""
echo "  19 MCP tools available in Claude Code:"
echo "    create_session, run_test, screenshot, click, type_text,"
echo "    key_press, scroll, drag, list_sessions, stop_session,"
echo "    list_displays, check_permissions, get_test_report,"
echo "    cancel_test, get_accessibility_tree, get_interactive_elements,"
echo "    find_element, click_element, setup_status"
echo ""
echo "  Slash commands: /test-app, /test-screenshot, /test-elements, /test-cleanup"
echo ""
echo "  Required macOS permissions:"
echo "    - Screen Recording (System Settings → Privacy & Security)"
echo "    - Accessibility (System Settings → Privacy & Security)"
echo ""
echo "  Verify setup:  Ask Claude Code to call the setup_status tool"
echo "  Update:         git pull && ./install.sh"
echo "  Uninstall:      ./uninstall.sh"
