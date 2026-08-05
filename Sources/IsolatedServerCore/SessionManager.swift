import CoreGraphics
import Darwin
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

    private func cleanupStaleSessions() async {
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
            _ = await stopSession(id)
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
        fallbackToMainDisplay: Bool = true,
        objective: String? = nil
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

        startFrameHistoryIfEnabled(session)
        // Document what this footage is for (stamped into the video metadata
        // + the queryable index) — set AFTER frame history so the recorder/
        // ledger exist to receive the objective marker.
        if let objective, !objective.isEmpty { session.setObjective(objective) }

        return SessionResponse(
            sessionId: session.id,
            displayID: state.displayID,
            appPID: state.appPID.map { Int32($0) } ?? 0,
            isRunning: state.isRunning,
            windowsPlaced: state.windowsPlaced
        )
    }

    /// Continuous visual memory is ON by default for every session
    /// (IST_FRAME_HISTORY=0 disables; IST_FRAME_CAPACITY overrides the 300).
    private func startFrameHistoryIfEnabled(_ session: TestSession) {
        let env = ProcessInfo.processInfo.environment
        guard env["IST_FRAME_HISTORY"] != "0" else { return }
        // If Screen Recording isn't granted yet, fire the prompt now so the
        // operator can slide the toggle on — the history loop otherwise pauses
        // with an honest reason instead of capturing.
        if !PermissionChecker.check().screenRecording {
            PermissionChecker.request()
        }
        let capacity = env["IST_FRAME_CAPACITY"].flatMap(Int.init) ?? 300
        do {
            try session.startFrameHistory(intervalSeconds: 1.0, capacity: capacity)
        } catch {
            ISTLogger.console("frame history failed to start for \(session.id): \(error)", level: .verbose)
        }
    }

    /// Set/replace a live session's task objective (documented in the video
    /// metadata and queryable index).
    public func setObjective(sessionId: String, objective: String) throws {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        session.setObjective(objective)
    }

    /// Reviewable Markdown report of one session's footage + actions + evidence.
    public func sessionReport(sessionId: String) throws -> [String: String] {
        guard let md = SessionReporter.sessionReportMarkdown(id: sessionId) else {
            throw ServerError.unknownAction("no indexed session \(sessionId) (stop it first to seal + index)")
        }
        let video = SessionReporter.sessionDetail(id: sessionId)?["video"] as? String ?? ""
        return ["sessionId": sessionId, "markdown": md, "video": video]
    }

    /// Cross-session trend analysis over all recorded footage — the "learn from
    /// failures later" surface. Returns structured findings that Peel/Jeeves can
    /// ingest over MCP (no cross-repo coupling here).
    public func trendReport() -> SessionReporter.Trends {
        SessionReporter.trends()
    }

    /// Toggle recording ON: (re)start the ~1fps ring for a session. Resumes the
    /// existing ring + evidence chain if it was paused; starts fresh otherwise.
    public func startRecording(sessionId: String, capacity: Int = 300) throws -> FrameHistoryResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        try session.startFrameHistory(intervalSeconds: 1.0, capacity: capacity)
        return try frameHistory(sessionId: sessionId, limit: 1)
    }

    /// Toggle recording OFF: pause capture. The ring and evidence chain are
    /// retained (a pause marker is logged) so recording can resume later.
    public func stopRecording(sessionId: String) async throws -> FrameHistoryResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        await session.stopFrameHistory()
        return try frameHistory(sessionId: sessionId, limit: 1)
    }

    /// Rolling frame history of a session (newest last).
    public func frameHistory(sessionId: String, limit: Int = 50) throws -> FrameHistoryResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        let status = session.frameHistoryStatus
        let store = session.frameHistoryStore
        let now = ProcessInfo.processInfo.systemUptime
        let frames = (store?.history(last: limit) ?? []).map {
            FrameRecord(ordinal: $0.ordinal, path: $0.path, sha256: $0.sha256,
                        bytes: $0.bytes, width: $0.width, height: $0.height,
                        ageSeconds: max(0, now - $0.capturedAtUptime))
        }
        return FrameHistoryResponse(
            sessionId: sessionId,
            active: status.active,
            error: status.error,
            count: store?.count ?? 0,
            capacity: store?.capacity ?? 0,
            frames: frames
        )
    }

    /// Export a bounded flipbook for non-visual models: change-detected frames
    /// (repeated sha256 skipped) with an OCR caption each, written under
    /// ~/.kist/visual-flipbooks/<session>/ with an index.json. Makes the
    /// console's long-standing "1fps-to-300-frame flipbook" prompt real.
    public func flipbookExport(sessionId: String, maxFrames: Int = 60) throws -> FlipbookResponse {
        // Reject non-positive caps up front: a 0/negative maxFrames would make
        // the subsample stride zero/negative and silently produce an empty
        // export instead of an honest error.
        guard (1...1000).contains(maxFrames) else {
            throw ServerError.unknownAction("maxFrames must be 1...1000, got \(maxFrames)")
        }
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let store = session.frameHistoryStore else {
            throw ServerError.unknownAction("session \(sessionId) has no frame history")
        }
        let all = store.history(last: Int.max)
        // Change-detection: keep a frame only when its hash differs from the last kept.
        var kept: [FrameStore.Frame] = []
        var lastHash = ""
        for frame in all where frame.sha256 != lastHash {
            kept.append(frame)
            lastHash = frame.sha256
        }
        if kept.count > maxFrames {
            // Evenly subsample down to the cap so the flipbook spans the session.
            let stride = Double(kept.count) / Double(maxFrames)
            kept = (0..<maxFrames).map { kept[Int(Double($0) * stride)] }
        }

        let outDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kist/visual-flipbooks/\(sessionId)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var indexEntries: [[String: Any]] = []
        for (i, frame) in kept.enumerated() {
            let dest = outDir.appendingPathComponent(String(format: "flip-%04d.jpg", i))
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(atPath: frame.path, toPath: dest.path)
            let caption = (try? FrameOCR.recognize(path: frame.path, expectedSha256: frame.sha256))?
                .observations.prefix(8).map(\.text).joined(separator: " · ") ?? ""
            indexEntries.append([
                "index": i, "ordinal": frame.ordinal, "file": dest.lastPathComponent,
                "sha256": frame.sha256, "caption": caption,
            ])
        }
        let index: [String: Any] = ["sessionID": sessionId, "frames": indexEntries]
        let indexURL = outDir.appendingPathComponent("index.json")
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: indexURL, options: .atomic)

        return FlipbookResponse(
            sessionId: sessionId, directory: outDir.path, indexPath: indexURL.path,
            exportedCount: kept.count, totalConsidered: all.count
        )
    }

    /// Seal a live session's evidence chain without stopping it: appends a
    /// terminal entry, writes the frame manifest, and reports whether the
    /// hash chain verified end-to-end.
    public func sealSession(sessionId: String) throws -> SealResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let ledger = session.receiptsLedger else {
            throw ServerError.unknownAction("session \(sessionId) has no evidence ledger")
        }
        let frames = session.frameHistoryStore?.history(last: Int.max) ?? []
        let seal = try ledger.seal(frames: frames)
        return SealResponse(
            sessionId: sessionId,
            entryCount: seal.entryCount,
            chainHead: seal.chainHead,
            frameCount: seal.frameCount,
            manifestPath: seal.path,
            chainIntact: ledger.firstBrokenIndex() == nil
        )
    }

    /// ASCII vision bridge: render a history frame (default: newest) as a
    /// character grid with OCR text stamped in place — sight for text-only
    /// models, with grid→pixel scale for acting on what they see.
    public func asciiFrame(sessionId: String, ordinal: Int? = nil, cols: Int = 160,
                           overlayText: Bool = true) throws -> AsciiFrameResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let store = session.frameHistoryStore else {
            throw ServerError.unknownAction("session \(sessionId) has no frame history")
        }
        let frame: FrameStore.Frame?
        if let ordinal {
            frame = store.frame(ordinal: ordinal)
        } else {
            frame = store.history(last: 1).last
        }
        guard let frame else {
            throw ServerError.unknownAction("no frame available in session \(sessionId) history")
        }
        var overlay: [FrameOCR.TextObservation]? = nil
        if overlayText {
            overlay = (try? FrameOCR.recognize(path: frame.path, expectedSha256: frame.sha256))?.observations
        }
        let grid = try AsciiRenderer.render(path: frame.path, cols: cols, ocrOverlay: overlay)
        return AsciiFrameResponse(
            sessionId: sessionId,
            ordinal: frame.ordinal,
            cols: grid.cols,
            rows: grid.rows,
            pixelsPerCol: grid.pixelsPerCol,
            pixelsPerRow: grid.pixelsPerRow,
            frameSha256: grid.frameSha256,
            text: grid.text
        )
    }

    /// Frame-bound OCR on one history frame (sha256 verified before recognition).
    public func ocrFrame(sessionId: String, ordinal: Int) throws -> FrameOCRResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        guard let store = session.frameHistoryStore,
              let frame = store.frame(ordinal: ordinal) else {
            throw ServerError.unknownAction("no frame \(ordinal) in session \(sessionId) history")
        }
        let result = try FrameOCR.recognize(path: frame.path, expectedSha256: frame.sha256)
        return FrameOCRResponse(
            sessionId: sessionId,
            ordinal: ordinal,
            frameSha256: result.frameSha256,
            width: result.width,
            height: result.height,
            observations: result.observations
        )
    }

    /// Attach a running QEMU VM to an isolated display. Repeated calls for the
    /// same PID reuse the existing session and never take ownership of QEMU.
    public func attachVMSession(
        pid: Int,
        displayWidth: Int = 1280,
        displayHeight: Int = 960
    ) async throws -> SessionResponse {
        guard pid > 1, pid <= Int(Int32.max) else {
            throw ServerError.unknownAction("Invalid QEMU PID")
        }
        if let existing = sessions.values.first(where: { $0.state.appPID == pid_t(pid) && $0.state.isRunning }) {
            let state = existing.state
            sessionLastActivity[existing.id] = Date()
            return SessionResponse(
                sessionId: existing.id,
                displayID: state.displayID,
                appPID: Int32(pid),
                isRunning: true,
                windowsPlaced: state.windowsPlaced
            )
        }

        let session = TestSession()
        let config = VirtualDisplayManager.DisplayConfig(
            width: displayWidth,
            height: displayHeight,
            ppi: 96,
            name: "IsolatedVM-\(pid)"
        )
        let state = try await session.attachVM(pid: pid_t(pid), displayConfig: config)
        let now = Date()
        sessions[session.id] = session
        sessionCreatedAt[session.id] = now
        sessionLastActivity[session.id] = now
        startFrameHistoryIfEnabled(session)
        return SessionResponse(
            sessionId: session.id,
            displayID: state.displayID,
            appPID: Int32(pid),
            isRunning: state.isRunning,
            windowsPlaced: state.windowsPlaced
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

    /// Export a PNG frame to an owner-private local file for another local MCP
    /// vision server. This is observation only; it does not actuate the guest.
    public func sessionFrame(sessionId: String, format: String = "png") async throws -> SessionFrameResponse {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()
        // Honor the requested format (was accepted-but-ignored) so png/jpeg is real.
        let imageFormat: ScreenCapture.ImageFormat = format.lowercased() == "jpeg" ? .jpeg : .png
        let result = try await session.screenshot(format: imageFormat)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isolated-tester/captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        let ext = imageFormat == .jpeg ? "jpg" : "png"
        let url = directory.appendingPathComponent("\(sessionId)-\(UUID().uuidString.lowercased()).\(ext)")
        try result.imageData.write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
        return SessionFrameResponse(
            sessionId: sessionId,
            path: url.path,
            width: result.width,
            height: result.height,
            format: imageFormat.rawValue,
            sizeKB: result.imageData.count / 1024
        )
    }

    /// Perform a UI action on a session.
    public func performAction(sessionId: String, action: ActionRequest) async throws {
        guard let session = sessions[sessionId] else {
            throw ServerError.sessionNotFound(sessionId)
        }
        sessionLastActivity[sessionId] = Date()

        // Self-heal placement: apps that opened their first window after
        // launch-time placement gave up get landed on the isolated display
        // before we act, instead of typing into a mis-placed window.
        _ = await session.ensurePlaced()

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
    public func stopSession(_ sessionId: String) async -> Bool {
        // Claim-and-remove BEFORE the await. `session.stop()` is async, so the
        // await is an actor suspension point; if the id stayed in `sessions`, a
        // concurrent stopSession(sameId) could re-enter and stop() the session
        // twice (duplicate termination + duplicate seal/pause ledger entries).
        // Removing first makes teardown single-shot: the racing call sees nil.
        guard let session = sessions.removeValue(forKey: sessionId) else { return false }
        runningTests[sessionId]?.cancel()
        runningTests.removeValue(forKey: sessionId)
        agents.removeValue(forKey: sessionId)
        sessionCreatedAt.removeValue(forKey: sessionId)
        sessionLastActivity.removeValue(forKey: sessionId)
        await session.stop()
        return true
    }

    /// Stop every active session. Called during server shutdown so no launched
    /// apps are orphaned after the server process exits.
    public func stopAll() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        // Snapshot and clear the maps BEFORE awaiting any teardown, for the same
        // single-shot reason as stopSession — a concurrent stopSession can't then
        // re-stop a session this loop is already tearing down.
        let claimed = sessions
        sessions.removeAll()
        runningTests.values.forEach { $0.cancel() }
        runningTests.removeAll()
        agents.removeAll()
        sessionCreatedAt.removeAll()
        sessionLastActivity.removeAll()
        for (_, session) in claimed {
            await session.stop()
        }
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

    /// Narrow self-substrate keystroke guard. Returns a refusal reason if the target
    /// session's visible accessibility text shows a self-restart of the Kist substrate
    /// (see `SubstrateGuard`), else nil. Fails OPEN: an unreadable AX tree blocks nothing
    /// (precision over recall; the console's circuit breaker is the hard backstop).
    public func substrateInputRefusal(sessionId: String) -> String? {
        guard let tree = try? getAccessibilityTree(sessionId: sessionId) else { return nil }
        return SubstrateGuard.selfRestartReason(inWindowText: SubstrateGuard.flatten(tree))
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

    /// Actively fire the macOS permission prompts so the operator can slide the
    /// Screen Recording / Accessibility toggles on. Registers this binary in
    /// System Settings even when the prompt itself is dismissed.
    public func requestPermissions() -> PermissionsResponse {
        let status = PermissionChecker.request()
        return PermissionsResponse(
            screenRecording: status.screenRecording,
            accessibility: status.accessibility,
            allGranted: status.screenRecording && status.accessibility
        )
    }
}
