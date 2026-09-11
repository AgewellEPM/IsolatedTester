import AVFoundation
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

    /// Start a test session with an isolated virtual display. If display
    /// creation fails, the session runs fully headless — there is NO path from
    /// here to the user's real display.
    public func start(
        appURL: URL,
        displayConfig: VirtualDisplayManager.DisplayConfig = .init()
    ) async throws -> SessionState {
        // HEADLESS MODEL (the console's isolation, for native apps): the app is
        // launched non-activating + moved off every physical display, and we
        // read its pixels by WINDOW capture — so it never touches the user's
        // desktop. A virtual display is best-effort (some apps render nicer with
        // one) but NOT required. The former fallbackToMainDisplay option was
        // removed after it silently hijacked the live desktop (2026-08-18):
        // isolation degrades to headless, never to the user's screen.
        var displayID: CGDirectDisplayID = 0
        do {
            let managedDisplay = try await displayManager.createDisplay(config: displayConfig)
            self.display = managedDisplay
            displayID = managedDisplay.displayID
            ISTLogger.session.info("Created virtual display: \(displayID)")
        } catch {
            ISTLogger.session.info("No virtual display (\(error.localizedDescription)); running fully headless via window capture")
        }

        let launchedApp = try await launcher.launchApp(at: appURL, displayID: displayID)
        self.app = launchedApp

        self.input = InputController(displayID: displayID, targetPID: launchedApp.pid)

        // Wait for the app's first window to exist (so capture + off-screen move land).
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

    /// End the session: quiesce recording, seal evidence, tear down. Idempotent
    /// — a second call is a no-op so shutdown can't double-seal.
    public func stop() async {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let recorder = videoRecorder
        lock.unlock()
        // Await the capture loop's exit FIRST so no frame can append after the
        // seal snapshot — the seal must be the true terminal ledger entry.
        await stopFrameHistory()
        // Finalize the movie (metadata was stamped at first frame), then seal +
        // index so the footage is reviewable and queryable.
        let videoPath = await recorder?.finish()
        lock.lock(); sealedVideoPath = videoPath; lock.unlock()
        if let ledger = receipts {
            _ = try? ledger.seal(frames: frameHistoryStore?.history(last: Int.max) ?? [])
        }
        writeSessionIndex(videoPath: videoPath)
        teardownResources()
    }

    public var sealedVideo: String? {
        lock.lock(); defer { lock.unlock() }
        return sealedVideoPath
    }

    /// Terminate the owned app and destroy the display. Shared by stop() and
    /// deinit; does not touch the (already-canceled) capture loop.
    private func teardownResources() {
        if let app, app.ownsProcess {
            launcher.terminateApp(pid: app.pid)
        }
        if let displayID = display?.displayID {
            displayManager.destroyDisplay(id: displayID)
        }
        app = nil
        display = nil
        input = nil
    }

    // MARK: - Reviewable footage: metadata + queryable index

    /// A one-line auto-description of what the session did, from its action log
    /// (the deterministic "what it is" that's always present; a richer AI
    /// caption can be layered on later without changing this).
    private func autoSummary() -> String {
        lock.lock()
        let objectiveText = objective
        let actions = actionLog
        let appName = app?.appURL.deletingPathExtension().lastPathComponent
        lock.unlock()
        let verbs = actions.map { $0.action }
        var counts: [String: Int] = [:]
        for v in verbs { counts[v, default: 0] += 1 }
        let breakdown = counts.sorted { $0.value > $1.value }
            .map { "\($0.value)× \($0.key)" }.joined(separator: ", ")
        let head = objectiveText ?? (appName.map { "Session driving \($0)" } ?? "Isolated-tester session")
        return actions.isEmpty ? head : "\(head) — \(actions.count) actions (\(breakdown))"
    }

    /// mp4 metadata documenting what this footage is, why it exists, and the
    /// task performed — so a reviewer opening the file knows its provenance.
    private func buildVideoMetadata() -> [AVMetadataItem] {
        lock.lock()
        let objectiveText = objective
        let appName = app?.appURL.deletingPathExtension().lastPathComponent ?? "unknown app"
        let chainHead = receipts?.chainHead ?? ""
        let actionCount = actionLog.count
        lock.unlock()
        let summary = autoSummary()
        let purpose = "IsolatedTester session recording. Purpose: tamper-evident VIDEO PROOF that "
            + "an AI agent's automated work ran inside an isolated virtual display — reviewable "
            + "confirmation of headless runs. Task: \(objectiveText ?? "(app: \(appName))"). "
            + "Every frame + action is hash-chained (evidence chainHead \(chainHead.prefix(16))…)."
        var items: [AVMetadataItem] = [
            SessionVideoRecorder.item(.commonKeyTitle, "IsolatedTester \(id): \(objectiveText ?? appName)"),
            SessionVideoRecorder.item(.commonKeyDescription, summary),
            SessionVideoRecorder.item(.commonKeySoftware, "IsolatedTester \(IsolatedTesterVersion.current)"),
            SessionVideoRecorder.userItem("session_id", id),
            SessionVideoRecorder.userItem("objective", objectiveText ?? ""),
            SessionVideoRecorder.userItem("app", appName),
            SessionVideoRecorder.userItem("action_count", String(actionCount)),
            SessionVideoRecorder.userItem("evidence_chain_head", chainHead),
            SessionVideoRecorder.userItem("purpose", purpose),
        ]
        if let objectiveText { items.append(SessionVideoRecorder.item(.commonKeySubject, objectiveText)) }
        return items
    }

    /// Write a per-session record and append to a global JSONL index so every
    /// session's footage is queryable (id, video path, objective, actions,
    /// outcome, evidence head) with one `grep`/`jq` over index.jsonl.
    private func writeSessionIndex(videoPath: String?) {
        lock.lock()
        let objectiveText = objective
        let appName = app?.appURL.deletingPathExtension().lastPathComponent ?? ""
        let chainHead = receipts?.chainHead ?? ""
        let actions = actionLog.map { ["at": ISO8601DateFormatter().string(from: $0.timestamp),
                                       "action": $0.action, "details": $0.details] }
        let sessionDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".isolated-tester/sessions/\(id)", isDirectory: true)
        lock.unlock()

        let record: [String: Any] = [
            "sessionID": id,
            "objective": objectiveText ?? "",
            "app": appName,
            "summary": autoSummary(),
            "video": videoPath ?? "",
            "actionCount": actions.count,
            "actions": actions,
            "evidenceChainHead": chainHead,
            "sealJSON": sessionDir.appendingPathComponent("seal.json").path,
        ]
        // Per-session detail file.
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) {
            let url = sessionDir.appendingPathComponent("session.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        // One-line-per-session global index (queryable across all footage).
        let indexRecord: [String: Any] = [
            "sessionID": id, "objective": objectiveText ?? "", "app": appName,
            "summary": autoSummary(), "video": videoPath ?? "", "actionCount": actions.count,
            "evidenceChainHead": chainHead,
        ]
        if let line = try? JSONSerialization.data(withJSONObject: indexRecord, options: [.sortedKeys]),
           let text = String(data: line, encoding: .utf8) {
            let indexURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".isolated-tester/sessions/index.jsonl")
            let data = Data((text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: indexURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: indexURL, options: .atomic)
            }
        }
    }

    // MARK: - Actions

    /// Take a screenshot of the current state.
    public func screenshot(format: ScreenCapture.ImageFormat = .png) async throws -> ScreenCapture.CaptureResult {
        // Headless: capture the app's WINDOW directly (works off-screen), so we
        // never depend on a visible display. Fall back to display capture only
        // if a display was actually established and there's no app pid.
        if let pid = app?.pid {
            return try await capture.captureWindow(pid: pid, format: format)
        }
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
        logAction("keyPress", details: "key=\(keyCode) modifiers=\(modifiers.rawValue)")
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
    private var videoRecorder: SessionVideoRecorder?
    private var sealedVideoPath: String?
    private var stopped = false
    private var objective: String?   // what this session is for — stamped into the video + index

    /// Set/replace the session's task objective (documented in the movie
    /// metadata and the reviewable session index).
    public func setObjective(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        objective = text
        receipts?.append(kind: "objective", detail: text)
    }

    public var currentObjective: String? {
        lock.lock(); defer { lock.unlock() }
        return objective
    }

    /// Continuous ~1fps capture into a bounded on-disk ring (default 300
    /// frames ≈ 5 minutes). Fails safe: five consecutive capture failures
    /// (e.g. no Screen Recording grant) stop the loop with a recorded error
    /// instead of spinning forever.
    public func startFrameHistory(intervalSeconds: Double = 1.0, capacity: Int = 300) throws {
        lock.lock()
        let alreadyRunning = frameHistoryTask != nil
        let existingStore = frameStore
        let existingLedger = receipts
        lock.unlock()
        guard !alreadyRunning else { return }

        let store: FrameStore
        let ledger: SessionReceipts
        if let existingStore, let existingLedger {
            // Resume: keep the same ring + evidence chain so pause/resume is a
            // continuous, gap-marked recording rather than a fresh ledger that
            // would clobber the chain.
            store = existingStore
            ledger = existingLedger
            ledger.append(kind: "recording-resumed", detail: "capacity=\(store.capacity)")
        } else {
            let sessionDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".isolated-tester/sessions/\(id)", isDirectory: true)
            store = try FrameStore(directory: sessionDir.appendingPathComponent("frames", isDirectory: true),
                                   capacity: capacity)
            ledger = try SessionReceipts(sessionID: id, directory: sessionDir)
            store.onRecord = { frame in
                ledger.append(kind: "frame", detail: "ordinal=\(frame.ordinal)",
                              sha256: frame.sha256, atUptime: frame.capturedAtUptime)
            }
            store.onEvict = { frame in
                ledger.append(kind: "eviction", detail: "ordinal=\(frame.ordinal)", sha256: frame.sha256)
            }
            // Movie recorder: encodes the WHOLE run (frames are appended at
            // capture time, before the ring can evict them) to session.mp4.
            // IST_VIDEO=0 disables; IST_VIDEO_FPS sets playback cadence.
            let env = ProcessInfo.processInfo.environment
            let recorder: SessionVideoRecorder?
            if env["IST_VIDEO"] == "0" {
                recorder = nil
            } else {
                let fps = env["IST_VIDEO_FPS"].flatMap(Int.init) ?? 6
                let rec = SessionVideoRecorder(
                    url: sessionDir.appendingPathComponent("session.mp4"), fps: fps)
                rec.metadataProvider = { [weak self] in self?.buildVideoMetadata() ?? [] }
                recorder = rec
            }
            // If an objective was set before capture started, mark it now that
            // the ledger exists.
            if let objectiveText = currentObjective {
                ledger.append(kind: "objective", detail: objectiveText)
            }
            lock.lock()
            frameStore = store
            receipts = ledger
            videoRecorder = recorder
            lock.unlock()
        }

        lock.lock()
        frameHistoryError = nil
        lock.unlock()

        let task = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self else { break }
                // Fail FAST on a missing Screen Recording grant: preflight is a
                // cheap non-blocking check, so we report the honest reason (and
                // where to fix it) instead of hanging on the consent picker.
                guard CGPreflightScreenCaptureAccess() else {
                    self.setFrameHistoryError(
                        "Screen Recording is not granted — frame history is paused. "
                        + "Call request_permissions (or System Settings → Privacy & Security "
                        + "→ Screen Recording), enable IsolatedTester, then start a new session.")
                    break
                }
                do {
                    // Even with the grant, race a deadline so a transient
                    // ScreenCaptureKit stall can't wedge the loop.
                    let shot = try await self.captureWithTimeout(seconds: 10)
                    _ = try store.record(shot.imageData, width: shot.width, height: shot.height)
                    // Encode into the movie at capture time (before eviction) so
                    // session.mp4 is the WHOLE run, not just the ring window.
                    self.videoRecorder?.append(imageData: shot.imageData)
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

    /// Pause capture. The ring and evidence chain are retained so a later
    /// startFrameHistory() resumes the same recording. Async so callers that
    /// need a quiescent ledger (e.g. seal on teardown) can await the in-flight
    /// capture cycle finishing before they snapshot — otherwise a frame could
    /// append AFTER the seal and leave the manifest missing its final frames.
    public func stopFrameHistory() async {
        lock.lock()
        let task = frameHistoryTask
        frameHistoryTask = nil
        let ledger = receipts
        lock.unlock()
        if task != nil { ledger?.append(kind: "recording-paused", detail: "") }
        task?.cancel()
        await task?.value   // wait for the loop to actually exit before returning
    }

    /// Synchronous fire-and-forget cancel for non-async teardown paths (deinit).
    /// Prefer the async stopFrameHistory() when the ledger must be quiescent.
    private func cancelFrameHistory() {
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
        // Best-effort last resort for a session dropped without `await stop()`.
        // deinit cannot await, so it can't wait for the capture loop to exit —
        // but it cancels the loop and SYNCHRONOUSLY seals whatever frames exist,
        // so the evidence chain is closed rather than left dangling. Guarded by
        // `stopped` so a session already stopped via stop() is never re-sealed.
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let ledger = receipts
        lock.unlock()
        cancelFrameHistory()
        if !alreadyStopped, let ledger {
            _ = try? ledger.seal(frames: frameHistoryStore?.history(last: Int.max) ?? [])
        }
        teardownResources()
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
