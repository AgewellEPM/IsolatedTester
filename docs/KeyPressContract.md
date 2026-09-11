# Key-press parsing and receipt contract

The MCP `key_press` tool, HTTP `ActionRequest(action: "keyPress")`, and
`AITestAgent` use the same pure `IsolatedTesterKit.KeyCombination` parser.
Parsing creates no events and does not inspect, place, or activate a window.

## Accepted requests

Existing single-key names remain supported, including literal space, letters,
digits, existing punctuation, arrows, navigation keys, and F1–F12.
The parser also accepts a modifier prefix followed by one base key:

```json
{"sessionId":"SESSION_ID","key":"cmd+c"}
{"sessionId":"SESSION_ID","key":"c","modifiers":["command","shift"]}
{"sessionId":"SESSION_ID","key":"ctrl+alt+delete"}
```

Supported host modifier aliases are `cmd`/`command`, `ctrl`/`control`,
`alt`/`option`, and `shift`, case-insensitively. Explicit modifiers merge with
prefix modifiers; duplicate aliases produce one flag and one physical modifier
press. Uppercase letters retain the existing behavior: they do not implicitly
add Shift. Use `shift+a` when Shift is intended.

The key is at most 128 UTF-8 bytes, with at most 16 prefix modifiers and 16
explicit modifier entries. Missing/empty/unknown keys, unknown modifiers,
empty `+` components, multiple base keys, and modifier-only requests fail.
An explicitly supplied `modifiers` value must be an array of strings or null
(null means absent, matching the HTTP Codable model). Malformed MCP requests
return `isError: true`, never a success-without-action response.

Literal `+` is not a key name; `shift+=` identifies that host key combination
on an appropriate keyboard layout. Use `cmd+space`, not an empty trailing token.

## Receipt and validation boundary

MCP validates the key arguments before its substrate guard; SessionManager
validates before session lookup, placement, or input. The AI agent no longer
substitutes keycode 0 (`a`) for unknown keys.

After the existing session-scoped input path returns successfully, TestSession
records the existing action receipt with this exact detail, including zero flags:

```text
keyPress: key=36 modifiers=0
keyPress: key=8 modifiers=1048576
```

The fields are decimal macOS virtual keycode and `CGEventFlags.rawValue`.
Shift is 131072, Control 262144, Option 524288, and Command 1048576; combinations
use bitwise union. Failed parsing never reaches input or its action receipt.
An input-post receipt is not proof that the target application accepted a key.
In particular, Command is a host modifier: mapping it to a Windows guest key
depends on the VM configuration and has not been verified here.

## Verification and activation

On 2026-09-07, 78 selected Swift tests passed: 19 new pure-parser, in-memory
MCP protocol, and source-wiring tests plus 59 existing model/validation tests.
They construct no active sessions, post no events, launch no applications,
and never call the MCP server entry point. Compilation used an isolated
scratch directory and the existing cached dependencies:

```sh
swift test --scratch-path /private/tmp/isolated-key-tests.VtXQqG \
  --cache-path /Users/lukekist/.kist/mcp/isolated-tester/.build \
  --skip-update --disable-automatic-resolution --disable-experimental-prebuilts \
  --jobs 4 \
  --filter 'KeyCombinationTests|KeyPressParserTests|KeyPressProtocolTests|KeyPressWiringTests|IsolatedServerCoreTests.ValidationTests|IsolatedServerCoreTests.ModelsTests'
```

The installed/running MCP service was not replaced or restarted. No VM or UI
test occurred. Existing capture behavior, the 1 FPS / 300-frame policy, and
`IST_VIDEO=0` were not changed. Activation and actual guest-key verification
must happen in a separately authorized session with guaranteed cleanup.
