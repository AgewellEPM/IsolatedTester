# Privacy Policy — IsolatedTester

_Last updated: 2026-09-11_

IsolatedTester is a local-first MCP server for macOS. It runs entirely on your
machine. This policy describes exactly what data it touches, where that data
goes, and what never leaves your computer.

## What IsolatedTester collects

- **Screen captures of isolated sessions.** Frames, screenshots, recordings,
  flipbooks, and OCR text are captured **only** from apps or VMs you explicitly
  launch inside an IsolatedTester session (virtual display or headless
  window-capture). It does not capture your real desktop.
- **Session metadata.** Objectives you set, action logs (clicks, keystrokes
  sent to the session), timestamps, and evidence-chain hashes.
- **Setup state.** macOS permission status (Screen Recording, Accessibility)
  and version info, checked locally to report readiness.

## Where data is stored

All captured data is written to **owner-private local files** under your home
directory (e.g. `~/.kist/`). Tool responses return file paths, not raw image
bytes. Nothing is uploaded by default.

## What is shared with third parties

- **Nothing, by default.** IsolatedTester has no telemetry, no analytics, no
  crash reporting, and no server operated by the developer. We never see your
  data.
- **AI providers, only when you ask.** The `run_test` tool drives an
  AI-powered test loop using a provider **you** configure (Anthropic or
  OpenAI) and **your own API key**. During a run, session screenshots and test
  context are sent to that provider's API. Their handling of that data is
  governed by their privacy policies:
  - Anthropic: https://www.anthropic.com/legal/privacy
  - OpenAI: https://openai.com/policies/privacy-policy
  If you never call `run_test`, no data leaves your machine.

## API keys

API keys are read from environment variables or passed per-call by your MCP
client. They are used only to authenticate with the provider you selected and
are never written to disk or logged by IsolatedTester.

## Retention and deletion

You control retention entirely. Frame rings are bounded (default ~300 frames)
and recycle oldest-first. To delete everything IsolatedTester has stored,
remove its data directories (e.g. `~/.kist/visual-flipbooks/`, session
artifact folders) — or run `./uninstall.sh`, which removes installed binaries.
Stopping a session with `stop_session` cleans up its live resources.

## Permissions

IsolatedTester requests macOS **Screen Recording** and **Accessibility**
permissions. These are required to capture isolated session displays and to
read/drive accessibility trees of apps under test. They are requested through
the standard macOS consent prompts and can be revoked at any time in
System Settings → Privacy & Security.

## Children's privacy

IsolatedTester is a developer tool and is not directed at children.

## Changes to this policy

Changes are published in this file in the project repository; the git history
is the changelog.

## Contact

Questions or concerns: open an issue at
https://github.com/AgewellEPM/IsolatedTester/issues
