import XCTest
@testable import IsolatedServerCore

final class AuditLogTests: XCTestCase {

    func testRecordEntry() async {
        let log = AuditLog()
        let entry = AuditLog.Entry(
            requestId: "req-1",
            action: "create_session",
            sessionId: "sess-1",
            outcome: "success",
            durationMs: 42
        )
        await log.record(entry)
        let recent = await log.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].requestId, "req-1")
        XCTAssertEqual(recent[0].action, "create_session")
        XCTAssertEqual(recent[0].outcome, "success")
        XCTAssertEqual(recent[0].durationMs, 42)
    }

    func testRecentLimit() async {
        let log = AuditLog()
        for i in 0..<10 {
            await log.record(AuditLog.Entry(requestId: "req-\(i)", action: "test", outcome: "success"))
        }
        let recent = await log.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
        // Should be the last 3 entries
        XCTAssertEqual(recent[0].requestId, "req-7")
        XCTAssertEqual(recent[2].requestId, "req-9")
    }

    func testRingBufferEviction() async {
        let log = AuditLog(maxEntries: 5)
        for i in 0..<10 {
            await log.record(AuditLog.Entry(requestId: "req-\(i)", action: "test", outcome: "success"))
        }
        let count = await log.count()
        XCTAssertEqual(count, 5)
        let recent = await log.recent()
        XCTAssertEqual(recent[0].requestId, "req-5")
        XCTAssertEqual(recent[4].requestId, "req-9")
    }

    func testEntryCodable() throws {
        let entry = AuditLog.Entry(
            requestId: "req-1",
            action: "screenshot",
            sessionId: "sess-1",
            outcome: "error",
            detail: "Display not found",
            durationMs: 100
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AuditLog.Entry.self, from: data)
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.action, "screenshot")
        XCTAssertEqual(decoded.sessionId, "sess-1")
        XCTAssertEqual(decoded.outcome, "error")
        XCTAssertEqual(decoded.detail, "Display not found")
        XCTAssertFalse(decoded.timestamp.isEmpty)
    }

    func testEmptyLog() async {
        let log = AuditLog()
        let recent = await log.recent()
        XCTAssertEqual(recent.count, 0)
        let count = await log.count()
        XCTAssertEqual(count, 0)
    }
}
