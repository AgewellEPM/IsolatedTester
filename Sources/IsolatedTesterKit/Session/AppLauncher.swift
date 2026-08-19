import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Launches applications HEADLESS — non-activating and off every physical
/// display — so they never touch the user's desktop (the console's isolation
/// model, applied to native macOS apps). Pixels are read via window capture,
/// so the app never needs to be visible.
public final class AppLauncher: @unchecked Sendable {

    /// A coordinate beyond any realistic display arrangement. Windows moved here
    /// are composited by the window server (so window-capture still works) but
    /// are never on a screen the user sees.
    static let offscreenOrigin = CGPoint(x: 200_000, y: 200_000)

    public struct LaunchedApp: Sendable {
        public let pid: pid_t
        public let bundleID: String?
        public let appURL: URL
        public let displayID: CGDirectDisplayID
        public let launchedAt: Date
        public let ownsProcess: Bool
        /// True only when at least one of the app's windows was actually moved
        /// onto the target display. A session whose app never landed on the
        /// isolated display is NOT isolated — callers must surface this.
        public let windowsPlaced: Bool
    }

    private var launchedApps: [pid_t: LaunchedApp] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Launch

    /// Launch an app bundle (.app) HEADLESS: non-activating (never steals focus
    /// or switches the user's Space) and moved off every physical display.
    public func launchApp(
        at appURL: URL,
        displayID: CGDirectDisplayID,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> LaunchedApp {
        // Record the user's frontmost app so we can PROVE we never stole focus.
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false            // never bring to the foreground / switch Space
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = false
        if !arguments.isEmpty { config.arguments = arguments }
        if !environment.isEmpty { config.environment = environment }

        let runningApp: NSRunningApplication = try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                if let app {
                    cont.resume(returning: app)
                } else {
                    cont.resume(throwing: AppLaunchError.launchFailed(
                        "NSWorkspace.openApplication failed: \(error?.localizedDescription ?? "no app returned")"))
                }
            }
        }

        let pid = runningApp.processIdentifier
        guard pid > 0 else {
            throw AppLaunchError.launchFailed("Launched app has no valid PID")
        }
        ISTLogger.launcher.info("App launched headless, PID: \(pid)")

        // Prefer a real isolated display. If this host cannot create one,
        // displayID is zero and the window is moved beyond every physical
        // display while direct window capture keeps it observable.
        let placed = displayID == 0
            ? await moveWindowsOffscreen(pid: pid)
            : await moveAppToDisplay(pid: pid, displayID: displayID)
        if !placed {
            ISTLogger.launcher.error("App \(pid) never landed on display \(displayID) — session is NOT isolated")
        }

        let launched = LaunchedApp(
            pid: pid,
            bundleID: runningApp.bundleIdentifier,
            appURL: appURL,
            displayID: displayID,
            launchedAt: Date(),
            ownsProcess: true,
            windowsPlaced: placed
        )
        store(launched)

        // Belt-and-suspenders: if the app somehow grabbed focus despite
        // activates:false, hand focus straight back to where it was.
        if let frontmostBefore,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let prior = NSRunningApplication(processIdentifier: frontmostBefore) {
            prior.activate()
            ISTLogger.launcher.info("Restored focus to prior frontmost app after headless launch")
        }

        return launched
    }

    private func store(_ launched: LaunchedApp) {
        lock.lock()
        defer { lock.unlock() }
        launchedApps[launched.pid] = launched
    }

    /// Retry placing an app's windows on its display (self-heal for apps whose
    /// first window appeared after launch-time placement gave up). Returns the
    /// updated placement state and records it.
    public func retryPlacement(pid: pid_t, displayID: CGDirectDisplayID) async -> Bool {
        let placed = displayID == 0
            ? await moveWindowsOffscreen(pid: pid, maxWaitTicks: 20)
            : await moveAppToDisplay(pid: pid, displayID: displayID, maxWaitTicks: 20)
        if placed { markPlaced(pid: pid) }
        return placed
    }

    private func markPlaced(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = launchedApps[pid] {
            launchedApps[pid] = LaunchedApp(
                pid: existing.pid, bundleID: existing.bundleID, appURL: existing.appURL,
                displayID: existing.displayID, launchedAt: existing.launchedAt,
                ownsProcess: existing.ownsProcess, windowsPlaced: true
            )
        }
    }

    /// Attach an already-running QEMU VM to an isolated display without taking
    /// ownership of the VM process. The executable allowlist keeps this narrow:
    /// this API cannot be used to move arbitrary host applications.
    public func attachExistingVM(
        pid: pid_t,
        displayID: CGDirectDisplayID
    ) async throws -> LaunchedApp {
        guard pid > 1, isRunning(pid: pid) else {
            throw AppLaunchError.launchFailed("QEMU process \(pid) is not running")
        }
        guard let executablePath = Self.executablePath(for: pid),
              Self.isAllowedVMExecutable(path: executablePath) else {
            throw AppLaunchError.launchFailed(
                "Process \(pid) is not an allowed qemu-system-* virtual machine")
        }

        let moved = await moveAppToDisplay(pid: pid, displayID: displayID)
        guard moved else {
            throw AppLaunchError.windowMoveFailed(
                "Could not move QEMU PID \(pid) to display \(displayID). Grant Accessibility to isolated-mcp/Kist and keep the QEMU window visible.")
        }

        return LaunchedApp(
            pid: pid,
            bundleID: nil,
            appURL: URL(fileURLWithPath: executablePath),
            displayID: displayID,
            launchedAt: Date(),
            ownsProcess: false,
            windowsPlaced: true  // attachExistingVM throws when the move fails
        )
    }

    public static func isAllowedVMExecutable(path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        return resolved.lastPathComponent.hasPrefix("qemu-system-")
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }

    public static func executablePath(for pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import on every SDK.
        // Darwin defines it as four times MAXPATHLEN (4096 bytes).
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Move all of a process's windows off every physical display (best effort,
    /// up to ~15s for the first window to appear).
    private func moveWindowsOffscreen(pid: pid_t, maxWaitTicks: Int = 150) async -> Bool {
        for _ in 0..<maxWaitTicks {
            if let windows = getWindows(for: pid), !windows.isEmpty {
                return windows.reduce(false) { moved, window in
                    moveWindow(window, to: Self.offscreenOrigin) || moved
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Launch an app by bundle identifier.
    public func launchApp(
        bundleID: String,
        displayID: CGDirectDisplayID
    ) async throws -> LaunchedApp {
        let output = await runProcess("/usr/bin/mdfind", arguments: ["kMDItemCFBundleIdentifier == '\(bundleID)'"])
        guard let appPath = output.split(separator: "\n").first.map(String.init), !appPath.isEmpty else {
            throw AppLaunchError.appNotFound(bundleID)
        }
        return try await launchApp(at: URL(fileURLWithPath: appPath), displayID: displayID)
    }

    // MARK: - Async Process Helper

    /// Run a process and return its stdout, without blocking the async executor.
    private func runProcess(_ path: String, arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Window Management

    /// Move all windows of a process to the specified display.
    /// Waits up to maxWaitTicks × 100ms for the first window (default 15s —
    /// cold launches with session restore routinely exceed the old 3s).
    private func moveAppToDisplay(
        pid: pid_t,
        displayID: CGDirectDisplayID,
        maxWaitTicks: Int = 150
    ) async -> Bool {
        ISTLogger.launcher.debug("Moving app \(pid) to display \(displayID)")
        for _ in 0..<maxWaitTicks {
            if let windows = getWindows(for: pid), !windows.isEmpty {
                let displayBounds = CGDisplayBounds(displayID)

                return windows.reduce(false) { moved, window in
                    moveWindow(window, to: displayBounds.origin) || moved
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        // App launched but no windows found.
        return false
    }

    private func getWindows(for pid: pid_t) -> [[String: Any]]? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let filtered = windowList.filter { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return ownerPID == pid
        }

        return filtered.isEmpty ? nil : filtered
    }

    private func moveWindow(_ window: [String: Any], to origin: CGPoint) -> Bool {
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }

        // Use Accessibility API to move the window
        let axApp = AXUIElementCreateApplication(pid)

        var axWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows) == .success else {
            return false
        }

        guard let windows = axWindows as? [AXUIElement], !windows.isEmpty else { return false }

        var moved = false
        for axWindow in windows {
            var position = origin
            if let posValue = AXValueCreate(.cgPoint, &position) {
                if AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue) == .success {
                    moved = true
                }
            }
        }
        return moved
    }

    // MARK: - Lifecycle

    /// Terminate an app gracefully (SIGTERM).
    public func terminateApp(pid: pid_t) {
        kill(pid, SIGTERM)

        lock.lock()
        launchedApps.removeValue(forKey: pid)
        lock.unlock()
    }

    /// Force-quit an app (SIGKILL).
    public func forceQuit(pid: pid_t) {
        kill(pid, SIGKILL)

        lock.lock()
        launchedApps.removeValue(forKey: pid)
        lock.unlock()
    }

    /// Terminate all launched apps.
    public func terminateAll() {
        lock.lock()
        let pids = Array(launchedApps.keys)
        lock.unlock()

        for pid in pids {
            lock.lock()
            let owned = launchedApps[pid]?.ownsProcess == true
            lock.unlock()
            if owned { terminateApp(pid: pid) }
        }
    }

    /// Check if an app is still running.
    public func isRunning(pid: pid_t) -> Bool {
        // Use kill(pid, 0) — sends no signal but checks if process exists
        kill(pid, 0) == 0
    }

    /// Get all launched apps.
    public func listApps() -> [LaunchedApp] {
        lock.lock()
        defer { lock.unlock() }
        return Array(launchedApps.values)
    }

    deinit {
        terminateAll()
    }
}

// MARK: - Errors

public enum AppLaunchError: Error, LocalizedError {
    case appNotFound(String)
    case launchFailed(String)
    case windowMoveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        case .windowMoveFailed(let msg): return "Window move failed: \(msg)"
        }
    }
}
