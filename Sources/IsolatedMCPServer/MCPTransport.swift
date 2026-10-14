import Foundation
import IsolatedServerCore
import IsolatedTesterKit

/// JSON-RPC 2.0 transport over stdin/stdout for the MCP protocol.
final class MCPTransport {
    private let sessionManager: SessionManager
    private let toolHandlers: MCPToolHandlers
    typealias ToolCall = (String, [String: Any]) async -> (result: String, isError: Bool)
    private let callTool: ToolCall
    private let input: FileHandle
    private let output: FileHandle
    private let outputLock = NSLock()

    init(sessionManager: SessionManager, input: FileHandle = .standardInput,
         output: FileHandle = .standardOutput, callTool: ToolCall? = nil) {
        self.sessionManager = sessionManager
        let handlers = MCPToolHandlers(sessionManager: sessionManager)
        self.toolHandlers = handlers
        self.callTool = callTool ?? { await handlers.callTool(name: $0, arguments: $1) }
        self.input = input
        self.output = output
    }

    func run() async {
        // Keep reading while a capture/test is pending. Only session inventory
        // and protocol bookkeeping bypass the serial worker; app actions and
        // session creation retain their original ordering.
        let (requests, pending) = AsyncStream<String>.makeStream()
        async let worker: Void = processRequests(requests)
        do {
            for await line in MCPInputLines.read(input) {
                guard !line.isEmpty else { continue }
                guard let request = decodeRequest(line) else {
                    sendError(id: nil, code: -32700, message: "Parse error")
                    continue
                }
                let method = request["method"] as? String ?? ""
                let params = request["params"] as? [String: Any] ?? [:]
                if isStatusRequest(method: method, params: params) {
                    await handleRequest(id: request["id"], method: method, params: params)
                } else {
                    pending.yield(line)
                }
            }
        }
        pending.finish()
        await worker
    }

    private func decodeRequest(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private func isStatusRequest(method: String, params: [String: Any]) -> Bool {
        switch method {
        case "initialize", "initialized", "notifications/initialized", "ping", "tools/list", "resources/list":
            return true
        case "tools/call":
            return params["name"] as? String == "list_sessions"
        case "resources/read":
            return params["uri"] as? String == "isolated://sessions"
        default:
            return false
        }
    }

    private func processRequests(_ requests: AsyncStream<String>) async {
        for await line in requests {
            guard let request = decodeRequest(line) else { continue }
            await handleRequest(id: request["id"], method: request["method"] as? String ?? "",
                                params: request["params"] as? [String: Any] ?? [:])
        }
    }

    // MARK: - Request Handling

    private func handleRequest(id: Any?, method: String, params: [String: Any]) async {
        switch method {
        case "initialize":
            sendResult(id: id, result: initializeResponse())

        case "initialized", "notifications/initialized":
            // Client acknowledgment, no response needed
            break

        case "tools/list":
            sendResult(id: id, result: ["tools": toolHandlers.listTools()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            // callTool returns (result, isError) so we can set the MCP isError flag
            let (resultText, isError) = await callTool(toolName, args)
            var toolResult: [String: Any] = ["content": [["type": "text", "text": resultText]]]
            if isError {
                // Per MCP spec, set isError: true when the tool invocation failed
                toolResult["isError"] = true
            }
            sendResult(id: id, result: toolResult)

        case "resources/list":
            sendResult(id: id, result: ["resources": listResources()])

        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            let content = await readResource(uri: uri)
            sendResult(id: id, result: ["contents": [["uri": uri, "mimeType": "application/json", "text": content]]])

        case "ping":
            sendResult(id: id, result: [:])

        default:
            // Per JSON-RPC 2.0, requests without an "id" are notifications and MUST NOT receive
            // a response. Only send the error when an id was present in the original request.
            guard id != nil else { break }
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func initializeResponse() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:],
                "resources": [:]
            ],
            "serverInfo": [
                "name": "isolated-tester",
                "version": IsolatedTesterVersion.current
            ]
        ]
    }

    // MARK: - Resources

    private func listResources() -> [[String: Any]] {
        [
            ["uri": "isolated://sessions", "name": "Active Sessions", "mimeType": "application/json"],
        ]
    }

    private func readResource(uri: String) async -> String {
        if uri == "isolated://sessions" {
            let sessions = await sessionManager.listSessions()
            if let data = try? JSONEncoder().encode(sessions),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }

        // Session-specific resources
        let parts = uri.components(separatedBy: "/")
        if parts.count >= 4, parts[2] == "sessions" {
            let sessionId = parts[3]
            let subResource = parts.count > 4 ? parts[4] : ""

            switch subResource {
            case "screenshot":
                if let result = try? await sessionManager.screenshot(sessionId: sessionId),
                   let data = try? JSONEncoder().encode(result),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
            case "report":
                if let report = await sessionManager.getReport(sessionId: sessionId),
                   let data = try? JSONEncoder().encode(report),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
            default:
                break
            }
        }

        return "{\"error\": \"Resource not found\"}"
    }

    // MARK: - JSON-RPC Output

    private func sendResult(id: Any?, result: Any) {
        guard let id else { return } // Notifications never receive responses.
        var response: [String: Any] = ["jsonrpc": "2.0"]
        response["id"] = id
        response["result"] = result
        send(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        response["id"] = id ?? NSNull()
        send(response)
    }

    func sendNotification(method: String, params: Any) {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        send(notification)
    }

    private func send(_ json: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            guard let line = String(data: data, encoding: .utf8) else {
                logToStderr("MCPTransport: UTF-8 encoding failed for serialized response")
                return
            }
            // MCP uses newline-delimited JSON on stdout
            write(Data((line + "\n").utf8))
        } catch {
            // Log the serialization error to stderr so it is visible without polluting stdout
            logToStderr("MCPTransport: JSONSerialization failed: \(error)")

            // Attempt a minimal fallback error response so the client is not left hanging.
            // Extract the id from the original dict if available (it must be a JSON scalar).
            let fallbackId = (json as? [String: Any])?["id"]
            let isNullId = fallbackId == nil
            // Build the fallback manually to avoid another potential serialization failure
            let idFragment: String
            if isNullId {
                idFragment = "null"
            } else if let n = fallbackId as? NSNumber {
                idFragment = n.stringValue
            } else if let s = fallbackId as? String {
                // JSON-encode the string by escaping backslash and double-quote
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
                idFragment = "\"\(escaped)\""
            } else {
                idFragment = "null"
            }
            let fallback = "{\"jsonrpc\":\"2.0\",\"id\":\(idFragment)," +
                           "\"error\":{\"code\":-32603,\"message\":\"Internal serialization error\"}}\n"
            write(Data(fallback.utf8))
        }
    }

    private func write(_ data: Data) {
        // A status reply may race the worker's reply, including a large image.
        // Hold the lock for the whole JSON line so responses cannot interleave.
        outputLock.lock()
        defer { outputLock.unlock() }
        output.write(data)
    }

    /// Write a diagnostic message to stderr so it does not corrupt the JSON-RPC stdout stream.
    private func logToStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
