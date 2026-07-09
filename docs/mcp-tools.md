# MCP Tools Reference

IsolatedTester exposes the following tools via the Model Context Protocol (MCP) over stdin/stdout.

## Session Management

### create_session
Launch an app and create a test session on a virtual display.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| appPath | string | yes | Path to the .app bundle |
| displayWidth | integer | no | Display width (default: 1920) |
| displayHeight | integer | no | Display height (default: 1080) |

**Returns:** `{ sessionId, displayID, appPID, isRunning }`

### list_sessions
List all active test sessions.

**Returns:** Array of `{ sessionId, displayID, appPID, isRunning, actionCount }`

### stop_session
Stop and clean up a session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |

## Testing

### run_test
Run an AI-driven visual test on a session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| objective | string | yes | What the test should accomplish |
| successCriteria | array | no | Conditions for success |
| failureCriteria | array | no | Conditions for failure |
| provider | string | no | AI provider: anthropic, openai, or claude-code |
| apiKey | string | no | API key (or set env var) |
| model | string | no | Model name override |
| maxSteps | integer | no | Maximum test steps (default: 25) |

**Returns:** `{ sessionId, success, summary, stepCount, duration }`

### cancel_test
Cancel a running AI test.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |

**Returns:** `{ success, cancelled }`

### get_test_report
Get the detailed test report for a session.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |

## UI Interaction

### screenshot
Capture the current screen state.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| format | string | no | Image format: png or jpeg |

**Returns:** `{ sessionId, width, height, format, base64Data, sizeKB }`

### click
Click at coordinates.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| x | number | yes | X coordinate |
| y | number | yes | Y coordinate |

### type_text
Type text into the app.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| text | string | yes | Text to type |

### key_press
Press a key with optional modifiers.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| key | string | yes | Key name (e.g., return, tab, escape) |

### scroll
Scroll the view.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| deltaY | integer | yes | Vertical scroll amount |
| deltaX | integer | no | Horizontal scroll amount |

### drag
Drag from one point to another.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| fromX | number | yes | Start X |
| fromY | number | yes | Start Y |
| toX | number | yes | End X |
| toY | number | yes | End Y |

## Accessibility

### get_accessibility_tree
Get the full accessibility element tree for a session's app.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |

**Returns:** Nested `AXElement` tree with role, label, value, frame, children, actions.

### get_interactive_elements
Get a flat list of interactive UI elements (buttons, text fields, etc.).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |

**Returns:** `{ elementCount, interactiveElements: [{ index, role, label, value, frame, actions, isEnabled }] }`

### find_element
Find accessibility elements by role, label, or identifier.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| role | string | no | AX role (e.g., AXButton, AXTextField) |
| label | string | no | Text label to search (case-insensitive) |
| identifier | string | no | Accessibility identifier |

**Returns:** Array of matching `AXElement` objects.

### click_element
Click an element using accessibility action at coordinates.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| sessionId | string | yes | Session ID |
| x | number | yes | X coordinate |
| y | number | yes | Y coordinate |
| action | string | no | AX action name (default: AXPress) |

**Returns:** `{ success: true/false }`

## System Info

### list_displays
List available displays.

**Returns:** Array of `{ displayID, width, height, isMain }`

### check_permissions
Check macOS permissions (Screen Recording + Accessibility).

**Returns:** `{ screenRecording, accessibility, allGranted }`
