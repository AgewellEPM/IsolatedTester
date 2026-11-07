import CoreGraphics
import Darwin
import Foundation

/// A login-scoped display, owned by the workspace host rather than an MCP
/// connection. Test sessions borrow it; closing a test never removes it.
public enum WorkspaceMonitor {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".isolated-tester/workspace", isDirectory: true)
    public static let stateURL = directory.appendingPathComponent("monitor.json")

    public struct State: Codable, Equatable, Sendable {
        public let ownerPID: Int32
        public let displayID: UInt32
        public let width: Int
        public let height: Int
        public let x: Int
        public let y: Int
        public let pointerGuard: Bool

        public init(displayID: UInt32, pointerGuard: Bool) {
            self.ownerPID = getpid()
            self.displayID = displayID
            let bounds = CGDisplayBounds(displayID)
            self.width = Int(bounds.width)
            self.height = Int(bounds.height)
            self.x = Int(bounds.minX)
            self.y = Int(bounds.minY)
            self.pointerGuard = pointerGuard
        }
    }

    public static func current() throws -> State {
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        guard state.ownerPID > 1, kill(state.ownerPID, 0) == 0,
              AppLauncher.executablePath(for: state.ownerPID)?.hasSuffix("/isolated-mcp") == true,
              state.pointerGuard,
              CGDisplayIsOnline(state.displayID) != 0,
              CGDisplayIsMain(state.displayID) == 0,
              CGDisplayVendorNumber(state.displayID) == 505,
              CGDisplayModelNumber(state.displayID) == 0,
              CGDisplayIsInMirrorSet(state.displayID) == 0 else {
            throw DisplayError.creationFailed("AI workspace monitor is unavailable; restore the workspace LaunchAgent. Host input is refused.")
        }
        return state
    }

    public static func save(_ state: State) throws {
        try save(state, to: stateURL)
    }

    static func save(_ state: State, to url: URL) throws {
        // This is a state record, not a heartbeat. Rewriting it every health
        // tick creates needless filesystem work and can fail on a full disk.
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(State.self, from: data), existing == state {
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Kernel-held lease: separate MCP processes cannot create overlapping tests.
/// The descriptor is released by the kernel on crash as well as normal cleanup.
public final class WorkspaceLease: @unchecked Sendable {
    private let descriptor: Int32

    public init(name: String) throws {
        try FileManager.default.createDirectory(at: WorkspaceMonitor.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = WorkspaceMonitor.directory.appendingPathComponent(name + ".lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DisplayError.creationFailed("Cannot open workspace lease") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw DisplayError.creationFailed("AI workspace already has an active \(name); reuse it instead of launching another.")
        }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
