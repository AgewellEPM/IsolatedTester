import ApplicationServices
import CoreGraphics
import Foundation

/// Launches applications on a specific virtual display.
/// Manages app lifecycle: launch, activate, terminate, force-quit.
public final class AppLauncher: @unchecked Sendable {

    public struct LaunchedApp: Sendable {
        public let pid: pid_t
        public let bundleID: String?
        public let appURL: URL
        public let displayID: CGDirectDisplayID
        public let launchedAt: Date
    }

    private var launchedApps: [pid_t: LaunchedApp] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Launch

    /// Launch an app bundle (.app) targeted at a specific display.
    public func launchApp(
        at appURL: URL,
        displayID: CGDirectDisplayID,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> LaunchedApp {
        // Use /usr/bin/open which works reliably from CLI without NSApplication run loop
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Use standardizedFileURL to resolve symlinks, then .path for the actual filesystem path
        let resolvedPath = appURL.standardizedFileURL.path
        var args = ["-g", "-a", resolvedPath]
        if !arguments.isEmpty {
            args.append("--args")
            args.append(contentsOf: arguments)
        }
        process.arguments = args
        ISTLogger.launcher.debug("Launching app via /usr/bin/open: \(resolvedPath)")

        // Merge environment if needed
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        // Use async-safe process execution — set handler before run to avoid race.
        // Capture any launch error via the continuation's return value so it can be
        // re-thrown after the continuation completes (withCheckedContinuation cannot
        // itself be throwing, so we smuggle the error out as an optional).
        let launchError: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            process.terminationHandler = { _ in
                // Process exited normally; no launch error.
                continuation.resume(returning: nil)
            }
            do {
                try process.run()
            } catch {
                // Resume immediately with the error; the termination handler will
                // never fire for a process that never started.
                continuation.resume(returning: error)
            }
        }

        if let error = launchError {
            throw AppLaunchError.launchFailed("Failed to execute /usr/bin/open: \(error.localizedDescription)")
        }

        // Get bundle ID from the app's Info.plist
        var bundleID: String?
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            bundleID = plist["CFBundleIdentifier"] as? String
        }

        // Find the running process using pgrep
        let appName = appURL.deletingPathExtension().lastPathComponent
        var pid: pid_t = 0

        for attempt in 0..<30 { // 3 second timeout
            // -n = newest process, -x = exact match — avoids picking wrong PID when multiple instances exist
            let foundPID = await runProcess("/usr/bin/pgrep", arguments: ["-n", "-x", appName])
            if let parsed = pid_t(foundPID), parsed > 0 {
                pid = parsed
                break
            }

            try? await Task.sleep(nanoseconds: attempt == 0 ? 200_000_000 : 100_000_000)
        }

        guard pid != 0 else {
            throw AppLaunchError.launchFailed("App launched but process '\(appName)' not found after 3 seconds")
        }
        ISTLogger.launcher.info("App launched, PID: \(pid)")

        let launched = LaunchedApp(
            pid: pid,
            bundleID: bundleID,
            appURL: appURL,
            displayID: displayID,
            launchedAt: Date()
        )

        lock.lock()
        launchedApps[pid] = launched
        lock.unlock()

        // Move app window to virtual display (best effort)
        await moveAppToDisplay(pid: pid, displayID: displayID)

        return launched
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
    private func moveAppToDisplay(pid: pid_t, displayID: CGDirectDisplayID) async {
        ISTLogger.launcher.debug("Moving app \(pid) to display \(displayID)")
        // Wait for the app to create its first window (best effort, 3s timeout)
        for _ in 0..<30 {
            if let windows = getWindows(for: pid), !windows.isEmpty {
                let displayBounds = CGDisplayBounds(displayID)

                for window in windows {
                    moveWindow(window, to: displayBounds.origin)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        // App launched but no windows found — not an error, continue anyway
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

    private func moveWindow(_ window: [String: Any], to origin: CGPoint) {
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return }

        // Use Accessibility API to move the window
        let axApp = AXUIElementCreateApplication(pid)

        var axWindows: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)

        guard let windows = axWindows as? [AXUIElement], !windows.isEmpty else { return }

        for axWindow in windows {
            var position = origin
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }
        }
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
            terminateApp(pid: pid)
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
