#!/bin/bash
set -euo pipefail

# IsolatedTester — Codex/Kist Plugin Installer
# Builds from source and configures the local MCP server.

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

BIN_DIR="$HOME/.local/bin"
PACKAGE_BIN_DIR=""
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
PACKAGE_BIN_DIR="$SCRIPT_DIR/bin"
cd "$SCRIPT_DIR"

info "Building IsolatedTester (release)..."
swift build -c release 2>&1 | tail -3

BUILD_DIR=".build/release"
for bin in "${BINARIES[@]}"; do
    [[ -f "$BUILD_DIR/$bin" ]] || fail "Build failed: $BUILD_DIR/$bin not found."
done
ok "Build succeeded."

# ── Install binaries ──────────────────────────────────────────

info "Installing binaries to $PACKAGE_BIN_DIR and $BIN_DIR..."
mkdir -p "$PACKAGE_BIN_DIR" "$BIN_DIR"

for bin in "${BINARIES[@]}"; do
    install -m 755 "$BUILD_DIR/$bin" "$PACKAGE_BIN_DIR/$bin"
    install -m 755 "$BUILD_DIR/$bin" "$BIN_DIR/$bin"
done

# Sign with a STABLE identity so TCC grants (Screen Recording, Accessibility)
# survive rebuilds. Adhoc signatures are per-hash: every rebuild silently
# revoked the grants and ScreenCaptureKit then blocked forever.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
for destination in "$PACKAGE_BIN_DIR" "$BIN_DIR"; do
    for bin in "${BINARIES[@]}"; do
        if [[ -n "$SIGN_ID" ]]; then
            codesign -f -s "$SIGN_ID" "$destination/$bin"
        else
            codesign -f -s - "$destination/$bin"
        fi
    done
done
ok "Binaries installed & signed (${SIGN_ID:-adhoc})."

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
echo "  32 MCP tools available:"
echo "    create_session, set_objective, attach_vm_session, run_test, screenshot, session_frame,"
echo "    frame_history, start_recording, stop_recording, session_report, trend_report, ocr_frame, ascii_frame,"
echo "    seal_session, flipbook_export, click, type_text, key_press, scroll, drag,"
echo "    list_sessions, stop_session, list_displays, check_permissions,"
echo "    request_permissions, get_test_report, cancel_test, get_accessibility_tree,"
echo "    get_interactive_elements, find_element, click_element, setup_status"
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
