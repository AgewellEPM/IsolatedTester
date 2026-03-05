Capture a screenshot from a running IsolatedTester session.

Usage: /test-screenshot [session-id]

Follow these steps:

1. Call `list_sessions` to see all active test sessions.

2. If no sessions are active, tell the user they need to create one first (suggest using /test-app).

3. If a session ID was provided, use that. Otherwise, if there's exactly one active session, use it. If there are multiple sessions, list them and ask the user which one to capture.

4. Call the `screenshot` tool with the chosen sessionId.

5. Describe what's visible in the screenshot to the user.
