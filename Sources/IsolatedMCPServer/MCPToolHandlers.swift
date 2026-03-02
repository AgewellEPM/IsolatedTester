import Foundation
import IsolatedServerCore
import IsolatedTesterKit

/// Handles MCP tool calls by dispatching to SessionManager.
final class MCPToolHandlers {
    private let sessionManager: SessionManager

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    /// Return the list of available tools in MCP format.
    func listTools() -> [[String: Any]] {
        [
            tool("create_session", "Launch an app and create a test session", [
                param("appPath", "string", "Path to the .app bundle", required: true),
                param("displayWidth", "integer", "Display width (default: 1920)"),
                param("displayHeight", "integer", "Display height (default: 1080)"),
            ]),
            tool("run_test", "Run an AI-driven visual test", [
                param("sessionId", "string", "Session ID", required: true),
                param("objective", "string", "What the test should accomplish", required: true),
                param("successCriteria", "array", "Conditions for success"),
                param("failureCriteria", "array", "Conditions for failure"),
                param("provider", "string", "AI provider: anthropic or openai"),
                param("apiKey", "string", "API key (or set env var)"),
                param("model", "string", "Model name override"),
                param("maxSteps", "integer", "Maximum test steps (default: 25)"),
            ]),
            tool("screenshot", "Capture the current screen state", [
                param("sessionId", "string", "Session ID", required: true),
                param("format", "string", "Image format: png or jpeg"),
            ]),
            tool("click", "Click at coordinates", [
                param("sessionId", "string", "Session ID", required: true),
                param("x", "number", "X coordinate", required: true),
                param("y", "number", "Y coordinate", required: true),
            ]),
            tool("type_text", "Type text into the app", [
                param("sessionId", "string", "Session ID", required: true),
                param("text", "string", "Text to type", required: true),
            ]),
            tool("key_press", "Press a key with optional modifiers", [
                param("sessionId", "string", "Session ID", required: true),
                param("key", "string", "Key name (e.g., return, tab, cmd+c)", required: true),
            ]),
            tool("scroll", "Scroll the view", [
                param("sessionId", "string", "Session ID", required: true),
                param("deltaY", "integer", "Vertical scroll amount", required: true),
                param("deltaX", "integer", "Horizontal scroll amount"),
            ]),
            tool("drag", "Drag from one point to another", [
                param("sessionId", "string", "Session ID", required: true),
                param("fromX", "number", "Start X", required: true),
                param("fromY", "number", "Start Y", required: true),
                param("toX", "number", "End X", required: true),
                param("toY", "number", "End Y", required: true),
            ]),
            tool("list_sessions", "List all active test sessions", []),
            tool("stop_session", "Stop and clean up a session", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("list_displays", "List available displays", []),
            tool("check_permissions", "Check macOS permissions", []),
            tool("get_test_report", "Get test report for a session", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
        ]
    }

    /// Call a tool and return the result text plus an isError flag per the MCP spec.
    /// isError is true when the invocation failed (thrown error or logical error response).
    func callTool(name: String, arguments args: [String: Any]) async -> (result: String, isError: Bool) {
        do {
            let result: Any
            switch name {
            case "create_session":
                let response = try await sessionManager.createSession(
                    appPath: args["appPath"] as? String ?? "",
                    displayWidth: args["displayWidth"] as? Int ?? 1920,
                    displayHeight: args["displayHeight"] as? Int ?? 1080,
                    fallbackToMainDisplay: args["fallbackToMainDisplay"] as? Bool ?? true
                )
                result = encode(response)

            case "run_test":
                let sessionId = args["sessionId"] as? String ?? ""
                let provider = args["provider"] as? String ?? "anthropic"
                let apiKey = APIKeyResolver.resolve(
                    provider: provider,
                    explicit: args["apiKey"] as? String
                ) ?? ""

                guard !apiKey.isEmpty else {
                    // Missing API key is a caller error — signal isError
                    return (encode(ErrorResponse(error: "API key required", code: "MISSING_API_KEY")), true)
                }

                let response = try await sessionManager.runTest(
                    sessionId: sessionId,
                    objective: args["objective"] as? String ?? "",
                    successCriteria: args["successCriteria"] as? [String] ?? [],
                    failureCriteria: args["failureCriteria"] as? [String] ?? [],
                    provider: args["provider"] as? String ?? "anthropic",
                    apiKey: apiKey,
                    model: args["model"] as? String,
                    maxSteps: args["maxSteps"] as? Int ?? 25
                )
                result = encode(response)

            case "screenshot":
                let response = try await sessionManager.screenshot(
                    sessionId: args["sessionId"] as? String ?? "",
                    format: args["format"] as? String ?? "png"
                )
                result = encode(response)

            case "click":
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "click", x: args["x"] as? Double, y: args["y"] as? Double)
                )
                result = "{\"success\": true}"

            case "type_text":
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "type", text: args["text"] as? String)
                )
                result = "{\"success\": true}"

            case "key_press":
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "keyPress", key: args["key"] as? String)
                )
                result = "{\"success\": true}"

            case "scroll":
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "scroll", deltaY: args["deltaY"] as? Int, deltaX: args["deltaX"] as? Int)
                )
                result = "{\"success\": true}"

            case "drag":
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(
                        action: "drag",
                        fromX: args["fromX"] as? Double, fromY: args["fromY"] as? Double,
                        toX: args["toX"] as? Double, toY: args["toY"] as? Double
                    )
                )
                result = "{\"success\": true}"

            case "list_sessions":
                let sessions = await sessionManager.listSessions()
                result = encode(sessions)

            case "stop_session":
                await sessionManager.stopSession(args["sessionId"] as? String ?? "")
                result = "{\"success\": true}"

            case "list_displays":
                let displays = await sessionManager.listDisplays()
                result = encode(displays)

            case "check_permissions":
                let perms = await sessionManager.checkPermissions()
                result = encode(perms)

            case "get_test_report":
                let sessionId = args["sessionId"] as? String ?? ""
                if let report = await sessionManager.getReport(sessionId: sessionId) {
                    result = encode(report)
                } else {
                    // Report not found is a logical error — signal isError
                    return (encode(ErrorResponse(error: "No report found", code: "NOT_FOUND")), true)
                }

            default:
                // Unknown tool is an error
                return (encode(ErrorResponse(error: "Unknown tool: \(name)", code: "UNKNOWN_TOOL")), true)
            }

            return (result as? String ?? "{}", false)

        } catch {
            // Thrown errors propagate as isError = true per MCP spec
            return (encode(ErrorResponse(error: error.localizedDescription, code: "ERROR")), true)
        }
    }

    // MARK: - Helpers

    private func tool(_ name: String, _ description: String, _ properties: [[String: Any]]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in properties {
            let pName = p["name"] as! String
            var schema: [String: Any] = ["type": p["type"] as! String]
            if let desc = p["description"] as? String { schema["description"] = desc }
            props[pName] = schema
            if p["required"] as? Bool == true { required.append(pName) }
        }

        var result: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": props,
            ]
        ]
        if !required.isEmpty {
            var schema = result["inputSchema"] as! [String: Any]
            schema["required"] = required
            result["inputSchema"] = schema
        }
        return result
    }

    private func param(_ name: String, _ type: String, _ description: String, required: Bool = false) -> [String: Any] {
        ["name": name, "type": type, "description": description, "required": required]
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
