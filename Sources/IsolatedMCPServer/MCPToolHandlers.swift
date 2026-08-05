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
            tool("attach_vm_session", "Attach a running qemu-system-* VM to an isolated virtual display without owning or terminating the VM", [
                param("pid", "integer", "Running QEMU process ID", required: true),
                param("displayWidth", "integer", "Display width (default: 1280)"),
                param("displayHeight", "integer", "Display height (default: 960)"),
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
            tool("screenshot", "Export the current screen state to an owner-private local image file; returns path metadata, never base64 image bytes", [
                param("sessionId", "string", "Session ID", required: true),
                param("format", "string", "Image format: png or jpeg"),
            ]),
            tool("session_frame", "Export a PNG frame from an isolated session to an owner-private local file for vision analysis", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("frame_history", "List the session's rolling ~1fps frame history (bounded ring, default 300 frames ≈ 5 min): ordinals, sha256 hashes, sizes, file paths — newest last", [
                param("sessionId", "string", "Session ID", required: true),
                param("limit", "integer", "Max frames to return (default 50)"),
            ]),
            tool("start_recording", "Turn the session's ~1fps screen recording ON. Resumes the existing frame ring + evidence chain if it was paused, otherwise starts fresh", [
                param("sessionId", "string", "Session ID", required: true),
                param("capacity", "integer", "Ring size in frames, 1-10000 (default 300 ≈ 5 min); ignored when resuming"),
            ]),
            tool("stop_recording", "Turn the session's screen recording OFF (pause). The frame ring and evidence chain are retained with a pause marker so recording can be resumed later", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("ocr_frame", "Frame-bound OCR on one history frame: verifies the stored sha256 before recognizing, returns text observations with confidence and normalized bounds", [
                param("sessionId", "string", "Session ID", required: true),
                param("ordinal", "integer", "Frame ordinal from frame_history", required: true),
            ]),
            tool("ascii_frame", "Vision for text-only models: render a history frame (default newest) as an ASCII character grid with on-screen text stamped at its true position. Convert grid to click coords: x=(col+0.5)*pixelsPerCol, y=(row+0.5)*pixelsPerRow", [
                param("sessionId", "string", "Session ID", required: true),
                param("ordinal", "integer", "Frame ordinal (omit for newest)"),
                param("cols", "integer", "Grid width in characters, 20-400 (default 160)"),
                param("overlayText", "boolean", "Stamp OCR text into the grid (default true)"),
            ]),
            tool("seal_session", "Seal the session's evidence chain (hash-linked receipts of every captured frame, eviction, and action) and write a frame manifest. Reports whether the chain verified end-to-end. Non-destructive; the session keeps running", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("flipbook_export", "Export a bounded, change-detected flipbook of the session's frame history (repeated frames skipped, each captioned via OCR) to ~/.kist/visual-flipbooks/<session>/ with an index.json — a time-lapse a non-visual model can page through", [
                param("sessionId", "string", "Session ID", required: true),
                param("maxFrames", "integer", "Max frames to export (default 60)"),
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
            tool("request_permissions", "Fire the macOS Screen Recording + Accessibility prompts on demand and register IsolatedTester in System Settings → Privacy & Security so the operator can slide the toggle on. Screen Recording usually still reads false until the next launch — that's expected, the toggle now exists", []),
            tool("get_test_report", "Get test report for a session", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("cancel_test", "Cancel a running AI test", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("get_accessibility_tree", "Get the accessibility element tree for a session's app", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("get_interactive_elements", "Get a flat list of interactive UI elements (buttons, fields, etc.)", [
                param("sessionId", "string", "Session ID", required: true),
            ]),
            tool("find_element", "Find accessibility elements by role, label, or identifier", [
                param("sessionId", "string", "Session ID", required: true),
                param("role", "string", "AX role (e.g., AXButton, AXTextField)"),
                param("label", "string", "Text label to search for (case-insensitive)"),
                param("identifier", "string", "Accessibility identifier"),
            ]),
            tool("click_element", "Click an element using accessibility action at coordinates", [
                param("sessionId", "string", "Session ID", required: true),
                param("x", "number", "X coordinate of the element", required: true),
                param("y", "number", "Y coordinate of the element", required: true),
                param("action", "string", "AX action name (default: AXPress)"),
            ]),
            tool("setup_status", "Check IsolatedTester setup status: version, platform, permissions, virtual display, active sessions", []),
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

            case "attach_vm_session":
                let response = try await sessionManager.attachVMSession(
                    pid: args["pid"] as? Int ?? 0,
                    displayWidth: args["displayWidth"] as? Int ?? 1280,
                    displayHeight: args["displayHeight"] as? Int ?? 960
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
                let response = try await sessionManager.sessionFrame(
                    sessionId: args["sessionId"] as? String ?? ""
                )
                result = encode(response)

            case "session_frame":
                let response = try await sessionManager.sessionFrame(
                    sessionId: args["sessionId"] as? String ?? ""
                )
                result = encode(response)

            case "frame_history":
                let response = try await sessionManager.frameHistory(
                    sessionId: args["sessionId"] as? String ?? "",
                    limit: args["limit"] as? Int ?? 50
                )
                result = encode(response)

            case "start_recording":
                let response = try await sessionManager.startRecording(
                    sessionId: args["sessionId"] as? String ?? "",
                    capacity: args["capacity"] as? Int ?? 300
                )
                result = encode(response)

            case "stop_recording":
                let response = try await sessionManager.stopRecording(
                    sessionId: args["sessionId"] as? String ?? ""
                )
                result = encode(response)

            case "ocr_frame":
                let response = try await sessionManager.ocrFrame(
                    sessionId: args["sessionId"] as? String ?? "",
                    ordinal: args["ordinal"] as? Int ?? -1
                )
                result = encode(response)

            case "ascii_frame":
                let response = try await sessionManager.asciiFrame(
                    sessionId: args["sessionId"] as? String ?? "",
                    ordinal: args["ordinal"] as? Int,
                    cols: args["cols"] as? Int ?? 160,
                    overlayText: args["overlayText"] as? Bool ?? true
                )
                result = encode(response)

            case "seal_session":
                let response = try await sessionManager.sealSession(
                    sessionId: args["sessionId"] as? String ?? ""
                )
                result = encode(response)

            case "flipbook_export":
                let response = try await sessionManager.flipbookExport(
                    sessionId: args["sessionId"] as? String ?? "",
                    maxFrames: args["maxFrames"] as? Int ?? 60
                )
                result = encode(response)

            case "click":
                if let blocked = await substrateBlock(args) { return blocked }
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "click", x: args["x"] as? Double, y: args["y"] as? Double)
                )
                result = "{\"success\": true}"

            case "type_text":
                if let blocked = await substrateBlock(args) { return blocked }
                try await sessionManager.performAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    action: ActionRequest(action: "type", text: args["text"] as? String)
                )
                result = "{\"success\": true}"

            case "key_press":
                if let blocked = await substrateBlock(args) { return blocked }
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

            case "request_permissions":
                let requested = await sessionManager.requestPermissions()
                result = encode(requested)

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

            case "cancel_test":
                let cancelled = await sessionManager.cancelTest(args["sessionId"] as? String ?? "")
                result = "{\"success\": true, \"cancelled\": \(cancelled)}"

            case "get_accessibility_tree":
                let tree = try await sessionManager.getAccessibilityTree(sessionId: args["sessionId"] as? String ?? "")
                result = encode(tree)

            case "get_interactive_elements":
                let summary = try await sessionManager.getInteractiveElements(sessionId: args["sessionId"] as? String ?? "")
                result = encode(summary)

            case "find_element":
                let elements = try await sessionManager.findElements(
                    sessionId: args["sessionId"] as? String ?? "",
                    role: args["role"] as? String,
                    label: args["label"] as? String,
                    identifier: args["identifier"] as? String
                )
                result = encode(elements)

            case "click_element":
                if let blocked = await substrateBlock(args) { return blocked }
                let success = try await sessionManager.performElementAction(
                    sessionId: args["sessionId"] as? String ?? "",
                    x: args["x"] as? Double ?? 0,
                    y: args["y"] as? Double ?? 0,
                    action: args["action"] as? String ?? "AXPress"
                )
                result = "{\"success\": \(success)}"

            case "setup_status":
                let perms = await sessionManager.checkPermissions()
                let activeSessions = await sessionManager.activeSessionCount
                let virtualDisplayAvailable = NSClassFromString("CGVirtualDisplayDescriptor") != nil
                let status: [String: Any] = [
                    "version": IsolatedTesterVersion.current,
                    "platform": "macOS",
                    "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                    "permissions": [
                        "screenRecording": perms.screenRecording,
                        "accessibility": perms.accessibility,
                        "allGranted": perms.allGranted
                    ],
                    "virtualDisplayAvailable": virtualDisplayAvailable,
                    "activeSessions": activeSessions,
                    "toolCount": listTools().count,
                    "status": perms.allGranted ? "ready" : "permissions_required"
                ]
                if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    result = json
                } else {
                    result = "{}"
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

    /// Self-substrate keystroke guard. Returns a populated (error, true) tuple when the
    /// target session's window text is a self-restart of the Kist substrate, so the input
    /// action must be refused; nil when it's safe to proceed. Fails open on unreadable AX.
    private func substrateBlock(_ args: [String: Any]) async -> (result: String, isError: Bool)? {
        let sessionId = args["sessionId"] as? String ?? ""
        guard !sessionId.isEmpty else { return nil }
        if let reason = await sessionManager.substrateInputRefusal(sessionId: sessionId) {
            return (encode(ErrorResponse(error: reason, code: "SELF_SUBSTRATE_BLOCKED")), true)
        }
        return nil
    }

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
