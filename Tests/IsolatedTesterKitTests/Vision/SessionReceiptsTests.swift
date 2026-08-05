import XCTest
@testable import IsolatedTesterKit

final class SessionReceiptsTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipts-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testChainVerifiesEndToEnd() throws {
        let ledger = try SessionReceipts(sessionID: "s1", directory: dir)
        ledger.append(kind: "frame", detail: "ordinal=0", sha256: "aa")
        ledger.append(kind: "action", detail: "click: (10, 20)")
        ledger.append(kind: "frame", detail: "ordinal=1", sha256: "bb")
        XCTAssertNil(ledger.firstBrokenIndex(), "an untouched chain must verify")
        XCTAssertEqual(ledger.count, 3)
    }

    func testTamperedLedgerFileBreaksVerification() throws {
        let ledger = try SessionReceipts(sessionID: "s2", directory: dir)
        ledger.append(kind: "frame", detail: "ordinal=0", sha256: "aa")
        ledger.append(kind: "frame", detail: "ordinal=1", sha256: "bb")
        ledger.append(kind: "frame", detail: "ordinal=2", sha256: "cc")

        // Reload the on-disk ledger, corrupt the middle entry's detail, and
        // verify the chain now breaks exactly there.
        let lines = try String(contentsOf: dir.appendingPathComponent("receipts.jsonl"))
            .split(separator: "\n").map(String.init)
        var entries = try lines.map { try JSONDecoder().decode(SessionReceipts.Entry.self, from: Data($0.utf8)) }
        let victim = entries[1]
        entries[1] = SessionReceipts.Entry(
            index: victim.index, kind: victim.kind, detail: "TAMPERED",
            sha256: victim.sha256, atUptime: victim.atUptime,
            prevHash: victim.prevHash, entryHash: victim.entryHash)

        // Recompute verification the same way SessionReceipts does.
        func firstBroken(_ es: [SessionReceipts.Entry]) -> Int? {
            var expectedPrev = String(repeating: "0", count: 64)
            for e in es {
                let pre = "\(e.index)|\(e.kind)|\(e.detail)|\(e.sha256)|\(String(format: "%.6f", e.atUptime))|\(e.prevHash)"
                if e.prevHash != expectedPrev { return e.index }
                if sha256Hex(pre) != e.entryHash { return e.index }
                expectedPrev = e.entryHash
            }
            return nil
        }
        XCTAssertEqual(firstBroken(entries), 1, "tampered entry must break the chain at its index")
    }

    func testConcurrentAppendsProduceUncorruptedOrderedLedgerFile() throws {
        // Codex P2 (2026-08-04): the frame task and action logging append
        // concurrently; the on-disk JSONL must stay byte-intact and in chain
        // order, or firstBrokenIndex would flag corruption it can't recover.
        let ledger = try SessionReceipts(sessionID: "race", directory: dir)
        let total = 400
        DispatchQueue.concurrentPerform(iterations: total) { i in
            ledger.append(kind: i % 2 == 0 ? "frame" : "action",
                          detail: "n=\(i)", sha256: String(format: "%064x", i))
        }
        XCTAssertNil(ledger.firstBrokenIndex(), "in-memory chain must verify")
        XCTAssertEqual(ledger.count, total)

        // Re-read the persisted ledger: exactly `total` well-formed lines, each
        // decodes, and the chain links + hashes verify in FILE order.
        let raw = try String(contentsOf: dir.appendingPathComponent("receipts.jsonl"))
        let lines = raw.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, total, "no line lost or interleaved on disk")
        var expectedPrev = String(repeating: "0", count: 64)
        for (i, line) in lines.enumerated() {
            let entry = try JSONDecoder().decode(SessionReceipts.Entry.self, from: Data(line.utf8))
            XCTAssertEqual(entry.index, i, "file order must equal chain order")
            XCTAssertEqual(entry.prevHash, expectedPrev, "broken link at file line \(i)")
            let pre = "\(entry.index)|\(entry.kind)|\(entry.detail)|\(entry.sha256)|\(String(format: "%.6f", entry.atUptime))|\(entry.prevHash)"
            XCTAssertEqual(sha256Hex(pre), entry.entryHash, "recomputed hash mismatch at \(i)")
            expectedPrev = entry.entryHash
        }
    }

    func testSealWritesManifestAndTerminalEntry() throws {
        let ledger = try SessionReceipts(sessionID: "s3", directory: dir)
        ledger.append(kind: "frame", detail: "ordinal=0", sha256: "aa")
        let frames = [FrameStore.Frame(ordinal: 0, path: "/tmp/f0.jpg", sha256: "aa",
                                       bytes: 10, width: 4, height: 4, capturedAtUptime: 1.0)]
        let seal = try ledger.seal(frames: frames)
        XCTAssertEqual(seal.frameCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seal.path))
        XCTAssertNil(ledger.firstBrokenIndex(), "chain must still verify after sealing")
        XCTAssertEqual(seal.chainHead, ledger.chainHead)
    }
}

import CryptoKit
private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
