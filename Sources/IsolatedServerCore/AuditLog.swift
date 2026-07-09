import Foundation

/// Records all significant actions for compliance and debugging.
/// Thread-safe via actor isolation. Ring buffer capped at maxEntries.
public actor AuditLog {
    public struct Entry: Codable, Sendable {
        public let timestamp: String
        public let requestId: String
        public let action: String
        public let sessionId: String?
        public let outcome: String  // "success", "error", "denied"
        public let detail: String?
        public let durationMs: Int?

        public init(requestId: String, action: String, sessionId: String? = nil,
                    outcome: String, detail: String? = nil, durationMs: Int? = nil) {
            self.timestamp = ISO8601DateFormatter().string(from: Date())
            self.requestId = requestId
            self.action = action
            self.sessionId = sessionId
            self.outcome = outcome
            self.detail = detail
            self.durationMs = durationMs
        }
    }

    private var entries: [Entry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 10_000) {
        self.maxEntries = maxEntries
    }

    public func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func recent(limit: Int = 100) -> [Entry] {
        let count = min(limit, entries.count)
        return Array(entries.suffix(count))
    }

    public func count() -> Int {
        entries.count
    }
}
