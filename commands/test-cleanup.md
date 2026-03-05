Stop all active IsolatedTester test sessions and release resources.

Usage: /test-cleanup

Follow these steps:

1. Call `list_sessions` to see all active test sessions.

2. If no sessions are active, tell the user there's nothing to clean up.

3. For each active session, call `stop_session` with its sessionId.

4. Report how many sessions were stopped.

5. Confirm all resources have been released.
