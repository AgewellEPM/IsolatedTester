Launch and test a macOS application in an isolated virtual display.

Usage: /test-app <app-path> <test-objective>

Example: /test-app /Applications/Calculator.app "Calculate 5 + 3 and verify the result is 8"

Follow these steps to test the application:

1. Call the `check_permissions` tool to verify macOS Screen Recording and Accessibility permissions are granted. If permissions are missing, tell the user what to enable and stop.

2. Call the `create_session` tool with the app path provided by the user. Note the returned `sessionId`.

3. Call the `screenshot` tool with the sessionId to capture the initial state. Describe what you see to the user.

4. Call the `run_test` tool with the sessionId and the user's test objective. If the user didn't specify a provider, use "anthropic" as default.

5. When the test completes, call `get_test_report` to retrieve the full results.

6. Present the test results to the user: pass/fail status, steps taken, any issues found.

7. Call `stop_session` to clean up the session and release resources.

If any step fails, report the error clearly and attempt to clean up by stopping the session.
