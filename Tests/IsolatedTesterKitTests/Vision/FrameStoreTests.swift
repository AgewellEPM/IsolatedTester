import XCTest
@testable import IsolatedTesterKit

final class FrameStoreTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("framestore-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRingCapsAtCapacityWithFIFOEviction() throws {
        let store = try FrameStore(directory: dir, capacity: 300)
        for i in 0..<305 {
            try store.record(Data("frame \(i)".utf8), width: 2, height: 2)
        }
        XCTAssertEqual(store.count, 300, "ring must hold exactly capacity after overflow")
        let history = store.history(last: 300)
        XCTAssertEqual(history.first?.ordinal, 5, "ordinals 0-4 must be evicted FIFO")
        XCTAssertEqual(history.last?.ordinal, 304)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("frame-000000.jpg").path),
            "evicted frame files must be deleted from disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.last!.path))
    }

    func testSha256MatchesKnownDigest() throws {
        let store = try FrameStore(directory: dir, capacity: 5)
        let frame = try store.record(Data("hello".utf8), width: 1, height: 1)
        // sha256("hello")
        XCTAssertEqual(frame.sha256,
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testHistoryIsNewestLastAndLookupByOrdinal() throws {
        let store = try FrameStore(directory: dir, capacity: 10)
        for i in 0..<4 {
            try store.record(Data("f\(i)".utf8), width: 1, height: 1)
        }
        let lastTwo = store.history(last: 2)
        XCTAssertEqual(lastTwo.map(\.ordinal), [2, 3])
        XCTAssertNotNil(store.frame(ordinal: 0))
        XCTAssertNil(store.frame(ordinal: 99))
    }

    func testPurgeRemovesFilesAndClearsRing() throws {
        let store = try FrameStore(directory: dir, capacity: 10)
        let frame = try store.record(Data("x".utf8), width: 1, height: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: frame.path))
        store.purge()
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: frame.path))
    }


    func testInvalidCapacityThrowsInsteadOfCrashing() {
        // Codex P2 (2026-08-04): a bad IST_FRAME_CAPACITY must be a recoverable
        // error, never a precondition crash that kills the server.
        for bad in [0, -5, 10_001] {
            XCTAssertThrowsError(try FrameStore(directory: dir, capacity: bad)) { error in
                guard case FrameStore.StoreError.invalidCapacity = error else {
                    return XCTFail("expected invalidCapacity, got \(error)")
                }
            }
        }
    }
}
