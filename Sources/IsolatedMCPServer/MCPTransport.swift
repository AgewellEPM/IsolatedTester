import Foundation
import IsolatedServerCore
import IsolatedTesterKit

/// JSON-RPC 2.0 transport over stdin/stdout for the MCP protocol.
final class MCPTransport {
    private let sessionManager: SessionManager
    private let toolHandlers: MCPToolHandlers

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        self.toolHandlers = MCPToolHandlers(sessionManager: sessionManager)
    }

    func run() async {
        // Read line-by-line from stdin
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendError(id: nil, code: -32700, message: "Parse error")
                continue
            }

            let id = json["id"]
            let method = json["method"] as? String ?? ""
            let params = json["params"] as? [String: Any] ?? [:]

            await handleRequest(id: id, method: method, params: params)
        }
    }

    // MARK: - Request Handling

    private func handleRequest(id: Any?, method: String, params: [String: Any]) async {
        switch method {
        case "initialize":
            sendResult(id: id, result: initializeResponse())

        case "initialized":
            // Client acknowledgment, no response needed
            break

        case "tools/list":
            sendResult(id: id, result: ["tools": toolHandlers.listTools()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            // callTool returns (result, isError) so we can set the MCP isError flag
            let (resultText, isError) = await toolHandlers.callTool(name: toolName, arguments: args)
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
        var response: [String: Any] = ["jsonrpc": "2.0"]
        if let id = id { response["id"] = id }
        response["result"] = result
        send(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id = id { response["id"] = id }
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
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
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
            FileHandle.standardOutput.write(Data(fallback.utf8))
        }
    }

    /// Write a diagnostic message to stderr so it does not corrupt the JSON-RPC stdout stream.
    private func logToStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
