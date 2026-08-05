import CryptoKit
import Foundation

/// Rolling frame history for a session: a bounded FIFO ring on disk.
///
/// Single rolling frames (frame.png-style capture) forget everything the
/// moment the next frame lands. The ring retains the last `capacity` frames
/// (~5 minutes at 1fps with the default 300) with a content hash per frame,
/// so downstream consumers — OCR, receipts, flipbooks — can bind evidence
/// to the exact bytes they analyzed.
public final class FrameStore: @unchecked Sendable {

    public struct Frame: Codable, Sendable {
        public let ordinal: Int
        public let path: String
        public let sha256: String
        public let bytes: Int
        public let width: Int
        public let height: Int
        /// Monotonic clock (systemUptime) — safe for ordering and deltas even
        /// across wall-clock changes.
        public let capturedAtUptime: TimeInterval
    }

    public let capacity: Int
    public let directory: URL

    private var frames: [Frame] = []
    private var nextOrdinal = 0
    private let lock = NSLock()

    public enum StoreError: Error, LocalizedError {
        case invalidCapacity(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidCapacity(let value):
                return "FrameStore capacity must be 1...10000, got \(value)"
            }
        }
    }

    public init(directory: URL, capacity: Int = 300) throws {
        // A bad IST_FRAME_CAPACITY must surface as a recoverable error, never
        // a precondition crash that takes the whole server down.
        guard (1...10_000).contains(capacity) else {
            throw StoreError.invalidCapacity(capacity)
        }
        self.capacity = capacity
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Record one frame: hash the exact bytes, persist, append to the ring,
    /// evict (and delete) the oldest frames beyond capacity.
    @discardableResult
    public func record(_ data: Data, width: Int, height: Int, fileExtension: String = "jpg") throws -> Frame {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        lock.lock()
        let ordinal = nextOrdinal
        nextOrdinal += 1
        lock.unlock()

        let url = directory.appendingPathComponent(
            "frame-\(String(format: "%06d", ordinal)).\(fileExtension)")
        try data.write(to: url, options: .atomic)

        let frame = Frame(
            ordinal: ordinal,
            path: url.path,
            sha256: digest,
            bytes: data.count,
            width: width,
            height: height,
            capturedAtUptime: ProcessInfo.processInfo.systemUptime
        )

        var evicted: [Frame] = []
        lock.lock()
        frames.append(frame)
        while frames.count > capacity {
            evicted.append(frames.removeFirst())
        }
        lock.unlock()

        for old in evicted {
            try? FileManager.default.removeItem(atPath: old.path)
        }
        return frame
    }

    /// Newest-last slice of the ring.
    public func history(last: Int = 50) -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return Array(frames.suffix(max(0, last)))
    }

    public func frame(ordinal: Int) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first { $0.ordinal == ordinal }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Delete every retained frame file and clear the ring.
    public func purge() {
        lock.lock()
        let all = frames
        frames.removeAll()
        lock.unlock()
        for frame in all {
            try? FileManager.default.removeItem(atPath: frame.path)
        }
    }
}
