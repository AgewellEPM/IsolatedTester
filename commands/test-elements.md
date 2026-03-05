Inspect the accessibility tree of a running IsolatedTester session.

Usage: /test-elements [session-id]

Follow these steps:

1. Call `list_sessions` to see all active test sessions.

2. If no sessions are active, tell the user they need to create one first (suggest using /test-app).

3. If a session ID was provided, use that. Otherwise, if there's exactly one active session, use it. If there are multiple, ask the user which one.

4. Call `get_interactive_elements` with the sessionId to get a flat list of all interactive UI elements (buttons, text fields, menus, etc.).

5. Present the elements in a clear, organized format showing:
   - Element role (button, text field, etc.)
   - Label/title
   - Position (x, y coordinates)
   - Whether it's enabled/disabled

6. If the user asks about a specific element, use `find_element` to search by role, label, or identifier.
