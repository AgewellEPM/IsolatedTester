#!/bin/bash
set -euo pipefail

# IsolatedTester — Uninstaller
# Removes binaries and Claude Code MCP configuration.

BOLD='\033[1m'
GREEN='\033[0;32m'
NC='\033[0m'

BIN_DIR="$HOME/.local/bin"
BINARIES=(isolated isolated-mcp isolated-http)

info()  { echo -e "${BOLD}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }

# ── Remove Claude Code config ─────────────────────────────────

info "Removing Claude Code MCP configuration..."
if command -v claude &>/dev/null; then
    claude mcp remove isolated-tester 2>/dev/null && ok "MCP server removed from Claude Code." || ok "No MCP config found."
else
    ok "Claude Code CLI not found, skipping."
fi

# ── Remove binaries ───────────────────────────────────────────

info "Removing binaries from $BIN_DIR..."
for bin in "${BINARIES[@]}"; do
    if [[ -f "$BIN_DIR/$bin" ]]; then
        rm "$BIN_DIR/$bin"
        ok "Removed $bin"
    fi
done

# ── Remove discovery file ─────────────────────────────────────

DISCOVERY_DIR="$HOME/.isolated-tester"
if [[ -d "$DISCOVERY_DIR" ]]; then
    rm -rf "$DISCOVERY_DIR"
    ok "Removed discovery directory."
fi

# ── Done ───────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}IsolatedTester uninstalled.${NC}"
