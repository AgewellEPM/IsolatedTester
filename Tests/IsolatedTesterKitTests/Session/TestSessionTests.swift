import XCTest
@testable import IsolatedTesterKit

final class TestSessionTests: XCTestCase {

    func testSessionID_format() {
        let session = TestSession()
        XCTAssertEqual(session.id.count, 8, "Session ID should be 8 hex chars")
        XCTAssertTrue(session.id.allSatisfy { $0.isHexDigit })
    }

    func testSessionID_custom() {
        let session = TestSession(id: "testid01")
        XCTAssertEqual(session.id, "testid01")
    }

    func testSessionID_unique() {
        let ids = (0..<100).map { _ in TestSession().id }
        let unique = Set(ids)
        XCTAssertEqual(unique.count, 100, "All session IDs should be unique")
    }

    func testState_initial() {
        let session = TestSession()
        let state = session.state
        XCTAssertEqual(state.sessionID, session.id)
        XCTAssertEqual(state.displayID, 0)
        XCTAssertNil(state.appPID)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.actionCount, 0)
    }

    func testActions_initiallyEmpty() {
        let session = TestSession()
        XCTAssertTrue(session.actions.isEmpty)
    }

    func testExportLog_emptySession() throws {
        let session = TestSession()
        let data = try session.exportLog()
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?.count, 0)
    }

    func testActionRecord_codable() throws {
        let record = TestSession.ActionRecord(
            timestamp: Date(),
            action: "click",
            details: "(100, 200)",
            screenshotPath: nil
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TestSession.ActionRecord.self, from: data)
        XCTAssertEqual(decoded.action, "click")
        XCTAssertEqual(decoded.details, "(100, 200)")
        XCTAssertNil(decoded.screenshotPath)
    }

    func testSessionState_codable() {
        // SessionState is not Codable, but verify its properties
        let session = TestSession(id: "abc12345")
        let state = session.state
        XCTAssertEqual(state.sessionID, "abc12345")
    }
}
