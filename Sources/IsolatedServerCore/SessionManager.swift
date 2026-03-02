import CoreGraphics
import Foundation
import IsolatedTesterKit

/// Thread-safe manager for concurrent test sessions.
/// Used by both MCP and HTTP servers.
public actor SessionManager {
    private var sessions: [String: TestSession] = [:]
    private var agents: [String: AITestAgent] = [:]
    private var reports: [String: AITestAgent.TestReport] = [:]

    public init() {}

    // MARK: - Session Lifecycle

    /// Create and start a new test session.
    public func createSession(
        appPath: String,
        displayWidth: Int = 1920,
        displayHeight: Int = 1080,
        fallbackToMainDisplay: Bool = true
    ) async throws -> SessionResponse {
        let session = TestSession()
        let appURL = URL(fileURLWithPath: appPath)

        let displayConfig = VirtualDisplayManager.DisplayConfig(
            width: displayWidth,
            height: displayHeight
        )

        let state = try await session.start(
            appURL: appURL,
            displayConfig: displayConfig,
            fallbackToMainDisplay: fallbackToMainDisplay
        )

        sessions[session.id] = session

        return SessionResponse(
            sessionId: session.id,
            displayID: state.displayID,
            appPID: state.appPID.map { Int32($0) } ?? 0,
            isRunning: state.isRunning
        )
    }

    /// Run an AI-driven test on a session.
    public func runTest(
        sessionId: String,
        objective: String,
        successCriteria: [String] = [],
        failureCriteria: [String] = [],
        provider: String = "anthropic",
        apiKey: String,
        model: String? = nil,
        maxSteps: Int = 25,
        onProgress: (@Sendable (TestProgressEvent) -> Void)? = nil
    ) async throws -> TestResultResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }

        let aiProvider: AITestAgent.AIProvider = provider.lowercased() == "openai" ? .openai : .anthropic
        let config = AITestAgent.AgentConfig(
            provider: aiProvider,
            apiKey: apiKey,
            model: model,
            maxSteps: maxSteps
        )

        let agent = AITestAgent(session: session, config: config)
        agents[sessionId] = agent

        let testObjective = AITestAgent.TestObjective(
            description: objective,
            successCriteria: successCriteria,
            failureCriteria: failureCriteria
        )

        let report = try await agent.runTest(objective: testObjective)
        reports[sessionId] = report

        return TestResultResponse(
            sessionId: sessionId,
            success: report.success,
            summary: report.summary,
            stepCount: report.stepCount,
            duration: report.duration
        )
    }

    /// Take a screenshot of a session.
    public func screenshot(sessionId: String, format: String = "png") async throws -> ScreenshotResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }

        let imgFormat: ScreenCapture.ImageFormat = format.lowercased() == "jpeg" ? .jpeg : .png
        let result = try await session.screenshot(format: imgFormat)

        return ScreenshotResponse(
            sessionId: sessionId,
            width: result.width,
            height: result.height,
            format: format,
            base64Data: result.imageData.base64EncodedString(),
            sizeKB: result.imageData.count / 1024
        )
    }

    /// Perform a UI action on a session.
    public func performAction(sessionId: String, action: ActionRequest) async throws {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }

        switch action.action {
        case "click":
            try session.click(x: action.x ?? 0, y: action.y ?? 0)
        case "doubleClick":
            try session.doubleClick(x: action.x ?? 0, y: action.y ?? 0)
        case "type":
            try session.type(action.text ?? "")
        case "keyPress":
            if let keyName = action.key, let code = InputController.KeyCode.fromString(keyName) {
                var flags: CGEventFlags = []
                for mod in action.modifiers ?? [] {
                    switch mod.lowercased() {
                    case "command", "cmd": flags.insert(.maskCommand)
                    case "shift": flags.insert(.maskShift)
                    case "option", "alt": flags.insert(.maskAlternate)
                    case "control", "ctrl": flags.insert(.maskControl)
                    default: break
                    }
                }
                try session.keyPress(code, modifiers: flags)
            }
        case "scroll":
            try session.scroll(deltaY: Int32(action.deltaY ?? 0), deltaX: Int32(action.deltaX ?? 0))
        case "drag":
            try session.drag(
                fromX: action.fromX ?? 0, fromY: action.fromY ?? 0,
                toX: action.toX ?? 0, toY: action.toY ?? 0
            )
        case "wait":
            await session.wait(seconds: action.seconds ?? 1.0)
        default:
            throw ServerError.unknownAction(action.action)
        }
    }

    /// Stop and clean up a session.
    /// - Returns: `true` if the session existed and was stopped; `false` if not found.
    /// Bug 6 fix: changed return type from Void to Bool so HTTP callers can return
    /// 404 instead of silently succeeding when the session ID is unknown.
    @discardableResult
    public func stopSession(_ sessionId: String) -> Bool {
        guard sessions[sessionId] != nil else { return false }
        sessions[sessionId]?.stop()
        sessions.removeValue(forKey: sessionId)
        agents.removeValue(forKey: sessionId)
        return true
    }

    /// Stop every active session. Called during server shutdown so no launched
    /// apps are orphaned after the server process exits.
    public func stopAll() {
        for (id, session) in sessions {
            session.stop()
            agents.removeValue(forKey: id)
        }
        sessions.removeAll()
    }

    /// List all active sessions.
    public func listSessions() -> [SessionInfoResponse] {
        sessions.map { (id, session) in
            let state = session.state
            return SessionInfoResponse(
                sessionId: id,
                displayID: state.displayID,
                appPID: state.appPID.map { Int32($0) } ?? 0,
                isRunning: state.isRunning,
                actionCount: state.actionCount
            )
        }
    }

    /// Get a stored test report.
    public func getReport(sessionId: String) -> AITestAgent.TestReport? {
        reports[sessionId]
    }

    /// Bug 5 fix: expose the session's action log through SessionManager.
    /// Returns nil when the session does not exist (caller returns 404).
    /// Returns an empty array when the session exists but has no actions yet.
    public func getLog(sessionId: String) -> [TestSession.ActionRecord]? {
        guard let session = sessions[sessionId] else { return nil }
        return session.actions
    }

    /// List available displays.
    public func listDisplays() -> [DisplayInfoResponse] {
        let manager = VirtualDisplayManager()
        let displays = manager.getActiveDisplays()
        return displays.map { id in
            let bounds = manager.displayBounds(for: id)
            return DisplayInfoResponse(
                displayID: id,
                width: Int(bounds.width),
                height: Int(bounds.height),
                isMain: id == CoreGraphics.CGMainDisplayID()
            )
        }
    }

    /// Check macOS permissions.
    public func checkPermissions() -> PermissionsResponse {
        let status = PermissionChecker.check()
        return PermissionsResponse(
            screenRecording: status.screenRecording,
            accessibility: status.accessibility,
            allGranted: status.screenRecording && status.accessibility
        )
    }
}
