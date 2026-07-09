import CoreGraphics
import Foundation
import IsolatedTesterKit

/// Thread-safe manager for concurrent test sessions.
/// Used by both MCP and HTTP servers.
public actor SessionManager {
    private var sessions: [String: TestSession] = [:]
    private var agents: [String: AITestAgent] = [:]
    private var reports: [String: AITestAgent.TestReport] = [:]
    private var runningTests: [String: Task<TestResultResponse, Error>] = [:]

    // Session lifecycle tracking
    private var sessionCreatedAt: [String: Date] = [:]
    private var sessionLastActivity: [String: Date] = [:]
    private var cleanupTask: Task<Void, Never>?

    // Timeouts (configurable via env vars)
    private let idleTimeout: TimeInterval
    private let maxSessionAge: TimeInterval

    public init(
        idleTimeout: TimeInterval? = nil,
        maxSessionAge: TimeInterval? = nil
    ) {
        self.idleTimeout = idleTimeout
            ?? TimeInterval(ProcessInfo.processInfo.environment["IST_SESSION_IDLE_TIMEOUT"].flatMap(Int.init) ?? 1800)
        self.maxSessionAge = maxSessionAge
            ?? TimeInterval(ProcessInfo.processInfo.environment["IST_SESSION_MAX_AGE"].flatMap(Int.init) ?? 7200)
    }

    /// Call after init to start the background cleanup loop.
    public func startCleanupLoop() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self = Optional(self)] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                guard let mgr = self else { return }
                await mgr.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        var toRemove: [String] = []
        for (id, _) in sessions {
            let isIdle = sessionLastActivity[id].map { now.timeIntervalSince($0) > idleTimeout } ?? false
            let isExpired = sessionCreatedAt[id].map { now.timeIntervalSince($0) > maxSessionAge } ?? false
            if isIdle || isExpired {
                toRemove.append(id)
            }
        }
        for id in toRemove {
            ISTLogger.console("Session \(id) expired (idle or max age exceeded)", level: .verbose)
            _ = stopSession(id)
        }
    }

    /// Number of currently active sessions.
    public var activeSessionCount: Int {
        sessions.count
    }

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

        let now = Date()
        sessions[session.id] = session
        sessionCreatedAt[session.id] = now
        sessionLastActivity[session.id] = now

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

        let aiProvider: AITestAgent.AIProvider
        switch provider.lowercased() {
        case "openai": aiProvider = .openai
        case "claude-code", "claudecode": aiProvider = .claudeCode
        default: aiProvider = .anthropic
        }
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
        sessionLastActivity[sessionId] = Date()

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
        sessionLastActivity[sessionId] = Date()

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
        runningTests[sessionId]?.cancel()
        runningTests.removeValue(forKey: sessionId)
        sessions[sessionId]?.stop()
        sessions.removeValue(forKey: sessionId)
        agents.removeValue(forKey: sessionId)
        sessionCreatedAt.removeValue(forKey: sessionId)
        sessionLastActivity.removeValue(forKey: sessionId)
        return true
    }

    /// Stop every active session. Called during server shutdown so no launched
    /// apps are orphaned after the server process exits.
    public func stopAll() {
        cleanupTask?.cancel()
        cleanupTask = nil
        for (id, session) in sessions {
            runningTests[id]?.cancel()
            session.stop()
            agents.removeValue(forKey: id)
        }
        sessions.removeAll()
        runningTests.removeAll()
        sessionCreatedAt.removeAll()
        sessionLastActivity.removeAll()
    }

    /// Cancel a running test on a session.
    /// - Returns: `true` if a test was running and cancelled.
    @discardableResult
    public func cancelTest(_ sessionId: String) -> Bool {
        guard let task = runningTests[sessionId] else { return false }
        task.cancel()
        runningTests.removeValue(forKey: sessionId)
        return true
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

    // MARK: - Accessibility

    /// Get the accessibility tree for a session's running app.
    public func getAccessibilityTree(sessionId: String) throws -> AXElement {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let pid = session.state.appPID else {
            throw ServerError.invalidRequest("No running app in session \(sessionId)")
        }
        let introspector = AXIntrospector()
        return introspector.introspect(pid: pid)
    }

    /// Get a flattened summary of interactive elements.
    public func getInteractiveElements(sessionId: String) throws -> AXTreeSummary {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let pid = session.state.appPID else {
            throw ServerError.invalidRequest("No running app in session \(sessionId)")
        }
        let introspector = AXIntrospector()
        return introspector.interactiveSummary(pid: pid)
    }

    /// Find elements by role, label, or identifier.
    public func findElements(sessionId: String, role: String? = nil, label: String? = nil, identifier: String? = nil) throws -> [AXElement] {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let pid = session.state.appPID else {
            throw ServerError.invalidRequest("No running app in session \(sessionId)")
        }
        let introspector = AXIntrospector()
        return introspector.findElements(pid: pid, role: role, label: label, identifier: identifier)
    }

    /// Perform an accessibility action on an element at a position.
    public func performElementAction(sessionId: String, x: Double, y: Double, action: String) throws -> Bool {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let pid = session.state.appPID else {
            throw ServerError.invalidRequest("No running app in session \(sessionId)")
        }
        let introspector = AXIntrospector()
        return introspector.performAction(pid: pid, x: Float(x), y: Float(y), action: action)
    }

    // MARK: - System Info

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
