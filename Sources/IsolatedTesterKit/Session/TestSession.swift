import CoreGraphics
import Foundation

/// Orchestrates a complete test session: virtual display + app + input + capture.
/// This is the main entry point for running isolated tests.
public final class TestSession: @unchecked Sendable {

    public let id: String
    public let displayManager: VirtualDisplayManager
    public let capture: ScreenCapture
    public let launcher: AppLauncher

    private var display: VirtualDisplayManager.ManagedDisplay?
    private var app: AppLauncher.LaunchedApp?
    private var input: InputController?
    private var actionLog: [ActionRecord] = []
    private let lock = NSLock()

    public struct ActionRecord: Sendable, Codable {
        public let timestamp: Date
        public let action: String
        public let details: String
        public let screenshotPath: String?
    }

    public struct SessionState: Sendable {
        public let sessionID: String
        public let displayID: CGDirectDisplayID
        public let appPID: pid_t?
        public let isRunning: Bool
        public let actionCount: Int
        public let startedAt: Date
        /// False when the app's windows never landed on the isolated display —
        /// the session is then NOT isolated and input targets a mis-placed app.
        public let windowsPlaced: Bool
    }

    public init(id: String) {
        self.id = id
        self.displayManager = VirtualDisplayManager()
        self.capture = ScreenCapture()
        self.launcher = AppLauncher()
    }

    public convenience init() {
        self.init(id: String(UUID().uuidString.prefix(8)).lowercased())
    }

    // MARK: - Session Lifecycle

    /// Start a test session with an isolated virtual display.
    /// Falls back to main display if virtual display creation fails.
    public func start(
        appURL: URL,
        displayConfig: VirtualDisplayManager.DisplayConfig = .init(),
        fallbackToMainDisplay: Bool = true
    ) async throws -> SessionState {
        // 1. Try to create isolated virtual display
        let managedDisplay: VirtualDisplayManager.ManagedDisplay
        do {
            managedDisplay = try await displayManager.createDisplay(config: displayConfig)
            ISTLogger.session.info("Created virtual display: \(managedDisplay.displayID)")
        } catch {
            if fallbackToMainDisplay {
                ISTLogger.session.info("Virtual display unavailable, using main display: \(error.localizedDescription)")
                managedDisplay = displayManager.useMainDisplay()
            } else {
                throw error
            }
        }
        self.display = managedDisplay

        // 2. Launch app on that display
        let launchedApp = try await launcher.launchApp(
            at: appURL,
            displayID: managedDisplay.displayID
        )
        self.app = launchedApp

        // 3. Create input controller targeting the display + process
        self.input = InputController(
            displayID: managedDisplay.displayID,
            targetPID: launchedApp.pid
        )

        // 4. Wait for initial render
        try await Task.sleep(nanoseconds: 1_000_000_000)

        return state
    }

    /// Start a session on the main display (for development/single-display systems).
    public func startOnMainDisplay(
        appURL: URL
    ) async throws -> SessionState {
        let managedDisplay = displayManager.useMainDisplay()
        self.display = managedDisplay

        let launchedApp = try await launcher.launchApp(
            at: appURL,
            displayID: managedDisplay.displayID
        )
        self.app = launchedApp

        self.input = InputController(
            displayID: managedDisplay.displayID,
            targetPID: launchedApp.pid
        )

        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s for initial render
        return state
    }

    /// Create an isolated display and move an existing QEMU window onto it.
    /// The VM remains owned by Perslis; stopping this session never terminates it.
    public func attachVM(
        pid: pid_t,
        displayConfig: VirtualDisplayManager.DisplayConfig = .init()
    ) async throws -> SessionState {
        let managedDisplay = try await displayManager.createDisplay(config: displayConfig)
        self.display = managedDisplay
        do {
            let attachedApp = try await launcher.attachExistingVM(
                pid: pid,
                displayID: managedDisplay.displayID
            )
            self.app = attachedApp
            self.input = InputController(
                displayID: managedDisplay.displayID,
                targetPID: attachedApp.pid
            )
            try await Task.sleep(nanoseconds: 500_000_000)
            return state
        } catch {
            displayManager.destroyDisplay(id: managedDisplay.displayID)
            self.display = nil
            throw error
        }
    }

    /// End the session: terminate app, destroy display.
    public func stop() {
        stopFrameHistory()
        // Seal the evidence before teardown: a terminal chain entry + a
        // manifest of the ordered frames still on disk. Frames are retained
        // (not purged) so the seal's referenced files exist for verification.
        if let ledger = receipts {
            _ = try? ledger.seal(frames: frameHistoryStore?.history(last: Int.max) ?? [])
        }
        if let app, app.ownsProcess {
            let pid = app.pid
            launcher.terminateApp(pid: pid)
        }
        if let displayID = display?.displayID {
            displayManager.destroyDisplay(id: displayID)
        }
        app = nil
        display = nil
        input = nil
    }

    // MARK: - Actions

    /// Take a screenshot of the current state.
    public func screenshot(format: ScreenCapture.ImageFormat = .png) async throws -> ScreenCapture.CaptureResult {
        guard let displayID = display?.displayID else {
            throw SessionError.noActiveSession
        }
        return try await capture.capture(displayID: displayID, format: format)
    }

    /// Click at a position.
    public func click(x: Double, y: Double) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.click(at: CGPoint(x: x, y: y))
        logAction("click", details: "(\(Int(x)), \(Int(y)))")
    }

    /// Double-click at a position.
    public func doubleClick(x: Double, y: Double) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.doubleClick(at: CGPoint(x: x, y: y))
        logAction("doubleClick", details: "(\(Int(x)), \(Int(y)))")
    }

    /// Type text.
    public func type(_ text: String) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.typeText(text)
        logAction("type", details: text)
    }

    /// Press a key.
    public func keyPress(_ keyCode: CGKeyCode, modifiers: CGEventFlags = []) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.keyPress(keyCode, modifiers: modifiers)
        logAction("keyPress", details: "key=\(keyCode)")
    }

    /// Scroll.
    public func scroll(deltaY: Int32, deltaX: Int32 = 0) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.scroll(deltaY: deltaY, deltaX: deltaX)
        logAction("scroll", details: "dy=\(deltaY) dx=\(deltaX)")
    }

    /// Drag from one point to another.
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) throws {
        guard let input = input else { throw SessionError.noActiveSession }
        try input.drag(
            from: CGPoint(x: fromX, y: fromY),
            to: CGPoint(x: toX, y: toY)
        )
        logAction("drag", details: "(\(Int(fromX)),\(Int(fromY))) → (\(Int(toX)),\(Int(toY)))")
    }

    /// Wait for the UI to settle after an action.
    public func wait(seconds: Double = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        logAction("wait", details: "\(seconds)s")
    }

    // MARK: - State

    public var state: SessionState {
        // Hold the lock while reading display, app, and actionLog to prevent data
        // races with logAction() and stop() which also mutate these fields.
        lock.lock()
        defer { lock.unlock() }
        return SessionState(
            sessionID: id,
            displayID: display?.displayID ?? 0,
            appPID: app?.pid,
            isRunning: app.map { launcher.isRunning(pid: $0.pid) } ?? false,
            actionCount: actionLog.count,
            startedAt: app?.launchedAt ?? Date(),
            windowsPlaced: app?.windowsPlaced ?? false
        )
    }

    // MARK: - Frame History (the 1fps / 300-frame visual memory)

    private var frameStore: FrameStore?
    private var frameHistoryTask: Task<Void, Never>?
    private var frameHistoryError: String?
    private var receipts: SessionReceipts?

    /// Continuous ~1fps capture into a bounded on-disk ring (default 300
    /// frames ≈ 5 minutes). Fails safe: five consecutive capture failures
    /// (e.g. no Screen Recording grant) stop the loop with a recorded error
    /// instead of spinning forever.
    public func startFrameHistory(intervalSeconds: Double = 1.0, capacity: Int = 300) throws {
        lock.lock()
        let alreadyRunning = frameHistoryTask != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isolated-tester/sessions/\(id)", isDirectory: true)
        let store = try FrameStore(directory: sessionDir.appendingPathComponent("frames", isDirectory: true),
                                   capacity: capacity)
        let ledger = try SessionReceipts(sessionID: id, directory: sessionDir)
        store.onRecord = { frame in
            ledger.append(kind: "frame", detail: "ordinal=\(frame.ordinal)",
                          sha256: frame.sha256, atUptime: frame.capturedAtUptime)
        }
        store.onEvict = { frame in
            ledger.append(kind: "eviction", detail: "ordinal=\(frame.ordinal)", sha256: frame.sha256)
        }

        lock.lock()
        frameStore = store
        receipts = ledger
        frameHistoryError = nil
        lock.unlock()

        let task = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    // ScreenCaptureKit HANGS (not errors) without a Screen
                    // Recording grant — race a deadline so the loop stays
                    // honest and can report why it stopped.
                    let shot = try await self.captureWithTimeout(seconds: 10)
                    _ = try store.record(shot.imageData, width: shot.width, height: shot.height)
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 5 {
                        self.setFrameHistoryError(
                            "frame history stopped after 5 consecutive capture failures: \(error.localizedDescription)")
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
        lock.lock()
        frameHistoryTask = task
        lock.unlock()
    }

    public func stopFrameHistory() {
        lock.lock()
        let task = frameHistoryTask
        frameHistoryTask = nil
        lock.unlock()
        task?.cancel()
    }

    public var frameHistoryStore: FrameStore? {
        lock.lock()
        defer { lock.unlock() }
        return frameStore
    }

    /// (active, error) — active means the capture loop is still running.
    public var frameHistoryStatus: (active: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (frameHistoryTask != nil && frameHistoryError == nil, frameHistoryError)
    }

    private func setFrameHistoryError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        frameHistoryError = message
        frameHistoryTask = nil
    }

    private func captureWithTimeout(seconds: Double) async throws -> ScreenCapture.CaptureResult {
        try await withThrowingTaskGroup(of: ScreenCapture.CaptureResult.self) { group in
            group.addTask { try await self.screenshot(format: .jpeg) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DisplayError.captureFailed("frame capture timed out after \(Int(seconds))s (likely no Screen Recording grant)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DisplayError.captureFailed("frame capture produced no result")
            }
            return first
        }
    }

    /// Self-heal: if the app's windows never landed on the isolated display at
    /// launch (first window appeared late), try the move again before acting.
    public func ensurePlaced() async -> Bool {
        guard let currentApp = app else { return false }
        if currentApp.windowsPlaced { return true }
        guard let displayID = display?.displayID else { return false }
        let placed = await launcher.retryPlacement(pid: currentApp.pid, displayID: displayID)
        if placed {
            setApp(AppLauncher.LaunchedApp(
                pid: currentApp.pid, bundleID: currentApp.bundleID, appURL: currentApp.appURL,
                displayID: currentApp.displayID, launchedAt: currentApp.launchedAt,
                ownsProcess: currentApp.ownsProcess, windowsPlaced: true
            ))
        }
        return placed
    }

    private func setApp(_ updated: AppLauncher.LaunchedApp) {
        lock.lock()
        defer { lock.unlock() }
        self.app = updated
    }

    /// Get the full action log.
    public var actions: [ActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return actionLog
    }

    /// Export action log as JSON.
    public func exportLog() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(actionLog)
    }

    // MARK: - Private

    private func logAction(_ action: String, details: String, screenshotPath: String? = nil) {
        let record = ActionRecord(
            timestamp: Date(),
            action: action,
            details: details,
            screenshotPath: screenshotPath
        )
        lock.lock()
        actionLog.append(record)
        let ledger = receipts
        lock.unlock()
        ledger?.append(kind: "action", detail: "\(action): \(details)")
    }

    /// Verify the session's evidence chain (nil = intact, else first broken index).
    public func receiptsFirstBrokenIndex() -> Int? {
        lock.lock(); let ledger = receipts; lock.unlock()
        return ledger?.firstBrokenIndex()
    }

    public var receiptsLedger: SessionReceipts? {
        lock.lock(); defer { lock.unlock() }
        return receipts
    }

    deinit {
        stop()
    }
}

// MARK: - Errors

public enum SessionError: Error, LocalizedError {
    case noActiveSession
    case appNotResponding
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveSession: return "No active test session"
        case .appNotResponding: return "Application is not responding"
        case .timeout(let msg): return "Timeout: \(msg)"
        }
    }
}
