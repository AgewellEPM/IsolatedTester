# Directory Submission Kit

Everything needed to submit IsolatedTester to Anthropic's directories.
Prepared 2026-09-11.

## 1. Official MCP Registry (registry.modelcontextprotocol.io)

- `server.json` at repo root, name `io.github.agewellepm/isolated-tester`
- Publish: `mcp-publisher login github` then `mcp-publisher publish` from repo root
- Package: mcpb release asset v1.2.0, sha256
  `2306a80402f808aeac2dc5d6b290dbebe4db2c681c9e767100c25e6784e521aa`
- New releases: bump `version` + asset URL + sha256 in server.json, re-publish

## 2. Anthropic Desktop Extension Directory (Claude Desktop)

- Submission form: https://forms.gle/tyiAZvch1kDADKoP9
- Artifact: `isolated-tester-1.2.0.mcpb` from the v1.2.0 GitHub release
- Note: tested on macOS only (`platforms: ["darwin"]`) — this is a
  macOS-native tool by design; state that in the form.

### Listing copy (fits the field limits)

**Name** (≤100 chars):
IsolatedTester

**Tagline** (≤55 chars):
Vision & control of macOS apps, without your screen

**Description** (≤2000 chars):
IsolatedTester gives any MCP-capable model eyes and hands on macOS — without
taking over your screen. Launch any .app (or attach a running QEMU VM) on an
isolated virtual display, observe it through screenshots, ~1fps frame history,
OCR, accessibility trees, or ASCII-rendered frames for text-only models, and
drive it with clicks, typing, key combos, scrolling, and accessibility
actions.

Built for AI-driven app testing and automation:
- Isolated by construction: sessions run on virtual displays (or headless
  window capture) — never on your real desktop. A removed-by-design fallback
  guarantees a failed virtual display can't take over your screen.
- Evidence you can audit: every session keeps a hash-linked chain of frames
  and actions; seal it, verify it end-to-end, and export reviewable Markdown
  reports, OCR-captioned flipbooks, and cross-session trend analyses.
- Vision for every model: image frames for vision models, ASCII grids with
  positioned on-screen text for text-only models.
- Optional AI test loop: run_test drives the app toward an objective using
  your own Anthropic or OpenAI API key, with success/failure criteria.

Local-first privacy: all captures are owner-private files on your machine.
No telemetry, no developer servers. Data leaves your Mac only when you
explicitly run an AI test with your own key.

32 tools, all annotated (read-only vs destructive). MIT licensed, open
source, 248 tests.

**Icon**: `icon.png` in the .mcpb (512×512). Also at repo root if exported.

**Documentation URL**: https://github.com/AgewellEPM/IsolatedTester/blob/main/README.md

**Privacy policy URL**: https://github.com/AgewellEPM/IsolatedTester/blob/main/PRIVACY.md

**Support contact**: https://github.com/AgewellEPM/IsolatedTester/issues
(add a support email in the form — decide which address to expose)

**Authentication**: None for the server itself. The optional run_test tool
uses the operator's own AI provider API key via environment variable or
per-call argument; keys are never persisted or logged.

**Data handling (form answers)**:
- Collects: screen captures of isolated sessions only, session metadata,
  permission status. All stored locally under the user's home directory.
- Shares: nothing by default; run_test sends session screenshots to the
  user-chosen AI provider with the user's key.
- Retention: user-controlled; bounded frame rings; uninstall script removes
  binaries; data dirs deletable at any time.

**Test account for reviewers**: none needed — no accounts. Reviewer setup:
macOS 14+, grant Screen Recording + Accessibility on first launch
(request_permissions tool fires the prompts; setup_status reports readiness).

## 3. Remote connectors directory (claude.ai) — NOT applicable yet

Requires a public HTTPS remote MCP server + Team/Enterprise org. IsolatedTester
is local-first by design; revisit only if a hosted gateway ever exists.
