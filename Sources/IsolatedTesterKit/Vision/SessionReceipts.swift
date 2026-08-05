import CryptoKit
import Foundation

/// Hash-chained evidence ledger for a session. Every captured frame, eviction,
/// and UI action appends an entry whose hash covers the previous entry's hash,
/// so the sequence cannot be reordered or silently edited after the fact — a
/// tampered or removed entry breaks the chain at that point.
///
/// This is the Perslis ReceiptChain / SessionSeal discipline reimplemented
/// natively for isolated-tester; no Perslis source is shared.
public final class SessionReceipts: @unchecked Sendable {

    public struct Entry: Codable, Sendable {
        public let index: Int
        public let kind: String          // "frame" | "eviction" | "action" | "seal"
        public let detail: String
        public let sha256: String        // content digest for this entry (e.g. frame bytes)
        public let atUptime: TimeInterval
        public let prevHash: String      // chain link — hash of the previous entry
        public let entryHash: String     // hash of this entry's canonical fields
    }

    public struct Seal: Codable, Sendable {
        public let sessionID: String
        public let entryCount: Int
        public let chainHead: String     // entryHash of the final entry
        public let frameCount: Int
        public let path: String
    }

    public let sessionID: String
    public let directory: URL
    private let ledgerURL: URL
    private var entries: [Entry] = []
    private let lock = NSLock()

    public init(sessionID: String, directory: URL) throws {
        self.sessionID = sessionID
        self.directory = directory
        self.ledgerURL = directory.appendingPathComponent("receipts.jsonl")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Append one entry, linking it to the current chain head.
    @discardableResult
    public func append(kind: String, detail: String, sha256: String = "",
                       atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Entry {
        // The whole critical section — compute link, append in memory, AND
        // persist — runs under one lock. Two concurrent writers (the 1fps
        // frame task and action logging) therefore can neither interleave
        // bytes in the JSONL nor write lines out of chain order, which would
        // otherwise corrupt the evidence the ledger exists to guarantee.
        lock.lock()
        defer { lock.unlock() }
        let index = entries.count
        let prevHash = entries.last?.entryHash ?? String(repeating: "0", count: 64)
        // Canonical, order-sensitive preimage — prevHash inclusion is the chain.
        let preimage = "\(index)|\(kind)|\(detail)|\(sha256)|\(String(format: "%.6f", atUptime))|\(prevHash)"
        let entryHash = Self.hash(preimage)
        let entry = Entry(index: index, kind: kind, detail: detail, sha256: sha256,
                          atUptime: atUptime, prevHash: prevHash, entryHash: entryHash)
        entries.append(entry)

        if let line = try? JSONEncoder().encode(entry),
           let text = String(data: line, encoding: .utf8) {
            appendLine(text)
        }
        return entry
    }

    /// Must be called with `lock` held (see `append`) so file order matches
    /// chain order and concurrent writers cannot interleave bytes.
    private func appendLine(_ text: String) {
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: ledgerURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: ledgerURL, options: .atomic)
        }
    }

    /// Verify the chain end-to-end: every entry's hash must recompute, and each
    /// prevHash must equal the actual previous entry's hash. Returns the index
    /// of the first broken entry, or nil if the whole chain is intact.
    public func firstBrokenIndex() -> Int? {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        var expectedPrev = String(repeating: "0", count: 64)
        for entry in snapshot {
            let preimage = "\(entry.index)|\(entry.kind)|\(entry.detail)|\(entry.sha256)|\(String(format: "%.6f", entry.atUptime))|\(entry.prevHash)"
            if entry.prevHash != expectedPrev { return entry.index }
            if Self.hash(preimage) != entry.entryHash { return entry.index }
            expectedPrev = entry.entryHash
        }
        return nil
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public var chainHead: String {
        lock.lock(); defer { lock.unlock() }
        return entries.last?.entryHash ?? String(repeating: "0", count: 64)
    }

    /// Seal the session: append a terminal entry and write a manifest naming
    /// the ordered frames, whose shape matches Perslis SessionSeal so a single
    /// verifier can check either system.
    @discardableResult
    public func seal(frames: [FrameStore.Frame]) throws -> Seal {
        let manifestFrames = frames.map {
            ["index": $0.ordinal, "path": $0.path, "sha256": $0.sha256,
             "bytes": $0.bytes, "width": $0.width, "height": $0.height] as [String: Any]
        }
        let sealEntry = append(kind: "seal", detail: "frames=\(frames.count)")
        let manifest: [String: Any] = [
            "sessionID": sessionID,
            "entryCount": count,
            "chainHead": sealEntry.entryHash,
            "frames": manifestFrames,
        ]
        let manifestURL = directory.appendingPathComponent("seal.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: manifestURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        return Seal(sessionID: sessionID, entryCount: count, chainHead: sealEntry.entryHash,
                    frameCount: frames.count, path: manifestURL.path)
    }
}
