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
            managedDisplay = try displayManager.createDisplay(config: displayConfig)
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

    /// End the session: terminate app, destroy display.
    public func stop() {
        if let pid = app?.pid {
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
            startedAt: app?.launchedAt ?? Date()
        )
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
        lock.unlock()
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
