import Foundation

/// A status-file failure must not destroy a healthy guarded display and make
/// launchd recreate it. Keep checking display health independently, and limit
/// publication retries (including error logging) while storage is unavailable.
struct WorkspaceStatePublisher {
    static let retryInterval: TimeInterval = 30
    private let save: (WorkspaceMonitor.State) throws -> Void
    private var retryAfter: TimeInterval = 0

    init(save: @escaping (WorkspaceMonitor.State) throws -> Void = WorkspaceMonitor.save) {
        self.save = save
    }

    /// Returns an error only for an attempted write. This deliberately cannot
    /// throw into the host's display-teardown/restart path.
    mutating func publish(_ state: WorkspaceMonitor.State,
                          at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Error? {
        guard uptime >= retryAfter else { return nil }
        do {
            try save(state)
            retryAfter = 0
            return nil
        } catch {
            retryAfter = uptime + Self.retryInterval
            return error
        }
    }
}
