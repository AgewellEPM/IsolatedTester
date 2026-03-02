import Foundation
import NIOHTTP1
import IsolatedServerCore
import IsolatedTesterKit

/// Routes HTTP requests to the appropriate handler.
final class Router: @unchecked Sendable {
    let sessionManager: SessionManager
    private let startTime = Date()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    struct HTTPResponse {
        let status: HTTPResponseStatus
        let body: [UInt8]
        let contentType: String

        init(status: HTTPResponseStatus = .ok, json: Data) {
            self.status = status
            self.body = Array(json)
            self.contentType = "application/json"
        }

        init(status: HTTPResponseStatus = .ok, text: String) {
            self.status = status
            self.body = Array(text.utf8)
            self.contentType = "text/plain"
        }

        // Bug 4 fix: use JSONSerialization to produce a properly escaped JSON error
        // object instead of manual string interpolation, which previously only escaped
        // double-quotes and missed backslashes, newlines, tabs, and other control chars.
        static func error(_ status: HTTPResponseStatus, _ message: String) -> HTTPResponse {
            let dict: [String: Any] = ["error": message]
            if let data = try? JSONSerialization.data(withJSONObject: dict) {
                return HTTPResponse(status: status, json: data)
            }
            // Fallback: safe ASCII-only representation
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return HTTPResponse(status: status, json: Data("{\"error\":\"\(escaped)\"}".utf8))
        }
    }

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func handle(method: HTTPMethod, uri: String, body: Data, headers: HTTPHeaders) async -> HTTPResponse {
        // Strip query string
        let path = uri.components(separatedBy: "?").first ?? uri

        // Handle CORS preflight — done first so it is never blocked by auth
        if method == .OPTIONS {
            return HTTPResponse(text: "")
        }

        // Route matching
        let parts = path.split(separator: "/").map(String.init)

        // Route matching using if-else since Swift 5.10 doesn't allow let-bindings in tuple patterns
        if method == .GET && (parts.isEmpty || parts == ["health"]) {
            return await health()
        } else if method == .GET && parts == ["displays"] {
            return await listDisplays()
        } else if method == .GET && parts == ["permissions"] {
            return await checkPermissions()
        } else if method == .POST && parts == ["sessions"] {
            return await createSession(body: body)
        } else if method == .GET && parts == ["sessions"] {
            return await listSessions()
        } else if method == .GET && parts.count == 2 && parts[0] == "sessions" {
            return await getSession(id: parts[1])
        } else if method == .DELETE && parts.count == 2 && parts[0] == "sessions" {
            return await stopSession(id: parts[1])
        } else if method == .POST && parts.count == 3 && parts[0] == "sessions" && parts[2] == "screenshot" {
            return await screenshot(sessionId: parts[1], body: body)
        } else if method == .POST && parts.count == 3 && parts[0] == "sessions" && parts[2] == "action" {
            return await performAction(sessionId: parts[1], body: body)
        } else if method == .POST && parts.count == 3 && parts[0] == "sessions" && parts[2] == "test" {
            return await runTest(sessionId: parts[1], body: body)
        } else if method == .GET && parts.count == 3 && parts[0] == "sessions" && parts[2] == "report" {
            return await getReport(sessionId: parts[1])
        } else if method == .GET && parts.count == 3 && parts[0] == "sessions" && parts[2] == "log" {
            return await getLog(sessionId: parts[1])
        } else {
            // Bug 7 fix: removed the dead `else if method == .OPTIONS` branch that
            // could never be reached (OPTIONS is handled unconditionally at the top).
            return .error(.notFound, "Not found: \(method) \(path)")
        }
    }

    // MARK: - Handlers

    private func health() async -> HTTPResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let response = HealthResponse(version: "1.0.0", status: "ok", uptime: uptime)
        return jsonResponse(response)
    }

    private func listDisplays() async -> HTTPResponse {
        let displays = await sessionManager.listDisplays()
        return jsonResponse(displays)
    }

    private func checkPermissions() async -> HTTPResponse {
        let perms = await sessionManager.checkPermissions()
        return jsonResponse(perms)
    }

    private func createSession(body: Data) async -> HTTPResponse {
        do {
            let request = try JSONDecoder().decode(CreateSessionRequest.self, from: body)
            let response = try await sessionManager.createSession(
                appPath: request.appPath,
                displayWidth: request.displayWidth ?? 1920,
                displayHeight: request.displayHeight ?? 1080,
                fallbackToMainDisplay: request.fallbackToMainDisplay ?? true
            )
            return jsonResponse(response, status: .created)
        } catch {
            return .error(.badRequest, error.localizedDescription)
        }
    }

    private func listSessions() async -> HTTPResponse {
        let sessions = await sessionManager.listSessions()
        return jsonResponse(sessions)
    }

    private func getSession(id: String) async -> HTTPResponse {
        let sessions = await sessionManager.listSessions()
        guard let session = sessions.first(where: { $0.sessionId == id }) else {
            return .error(.notFound, "Session not found: \(id)")
        }
        return jsonResponse(session)
    }

    // Bug 6 fix: check whether the session actually existed and return 404 if not.
    private func stopSession(id: String) async -> HTTPResponse {
        let existed = await sessionManager.stopSession(id)
        if !existed {
            return .error(.notFound, "Session not found: \(id)")
        }
        return jsonResponse(["success": true])
    }

    private func screenshot(sessionId: String, body: Data) async -> HTTPResponse {
        do {
            let format = (try? JSONDecoder().decode(ScreenshotRequest.self, from: body))?.format ?? "png"
            let response = try await sessionManager.screenshot(sessionId: sessionId, format: format)
            return jsonResponse(response)
        } catch {
            return .error(.internalServerError, error.localizedDescription)
        }
    }

    private func performAction(sessionId: String, body: Data) async -> HTTPResponse {
        do {
            let action = try JSONDecoder().decode(ActionRequest.self, from: body)
            try await sessionManager.performAction(sessionId: sessionId, action: action)
            return jsonResponse(["success": true])
        } catch {
            return .error(.badRequest, error.localizedDescription)
        }
    }

    private func runTest(sessionId: String, body: Data) async -> HTTPResponse {
        do {
            let request = try JSONDecoder().decode(RunTestRequest.self, from: body)
            let provider = request.provider ?? "anthropic"
            let apiKey = APIKeyResolver.resolve(
                provider: provider,
                explicit: request.apiKey
            ) ?? ""

            guard !apiKey.isEmpty else {
                return .error(.unauthorized, "API key required. Provide via request body, env var, config file, or Keychain.")
            }

            let response = try await sessionManager.runTest(
                sessionId: sessionId,
                objective: request.objective,
                successCriteria: request.successCriteria ?? [],
                failureCriteria: request.failureCriteria ?? [],
                provider: request.provider ?? "anthropic",
                apiKey: apiKey,
                model: request.model,
                maxSteps: request.maxSteps ?? 25
            )
            return jsonResponse(response)
        } catch {
            return .error(.internalServerError, error.localizedDescription)
        }
    }

    private func getReport(sessionId: String) async -> HTTPResponse {
        if let report = await sessionManager.getReport(sessionId: sessionId) {
            return jsonResponse(report)
        }
        return .error(.notFound, "No report found for session \(sessionId)")
    }

    // Bug 5 fix: delegate to SessionManager.getLog(sessionId:) which returns the
    // action records already stored on TestSession.  The encoder handles serialization.
    private func getLog(sessionId: String) async -> HTTPResponse {
        guard let log = await sessionManager.getLog(sessionId: sessionId) else {
            return .error(.notFound, "Session not found: \(sessionId)")
        }
        return jsonResponse(log)
    }

    // MARK: - Helpers

    private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> HTTPResponse {
        guard let data = try? encoder.encode(value) else {
            return .error(.internalServerError, "Failed to encode response")
        }
        return HTTPResponse(status: status, json: data)
    }

    private func jsonResponse(_ dict: [String: Bool]) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return .error(.internalServerError, "Failed to encode response")
        }
        return HTTPResponse(json: data)
    }
}
