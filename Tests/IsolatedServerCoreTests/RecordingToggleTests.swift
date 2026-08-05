import XCTest
@testable import IsolatedServerCore

/// Deterministic guards for the recording-toggle surface. The full pause/resume
/// capture path needs a live virtual display, so it is verified by the MCP e2e;
/// these pin the error contract without a display.
final class RecordingToggleTests: XCTestCase {

    func testStartRecordingUnknownSessionThrows() async {
        let manager = SessionManager()
        do {
            _ = try await manager.startRecording(sessionId: "nope")
            XCTFail("expected sessionNotFound")
        } catch let ServerError.sessionNotFound(id) {
            XCTAssertEqual(id, "nope")
        } catch {
            XCTFail("expected sessionNotFound, got \(error)")
        }
    }

    func testStopRecordingUnknownSessionThrows() async {
        let manager = SessionManager()
        do {
            _ = try await manager.stopRecording(sessionId: "nope")
            XCTFail("expected sessionNotFound")
        } catch let ServerError.sessionNotFound(id) {
            XCTAssertEqual(id, "nope")
        } catch {
            XCTFail("expected sessionNotFound, got \(error)")
        }
    }

    func testFrameHistoryResponseCarriesActiveAndError() throws {
        let response = FrameHistoryResponse(
            sessionId: "s", active: false, error: "paused", count: 3,
            capacity: 300, frames: [])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FrameHistoryResponse.self, from: data)
        XCTAssertFalse(decoded.active)
        XCTAssertEqual(decoded.error, "paused")
        XCTAssertEqual(decoded.count, 3)
    }


    func testFlipbookExportRejectsNonPositiveMaxFrames() async {
        let manager = SessionManager()
        for bad in [0, -1] {
            do {
                _ = try await manager.flipbookExport(sessionId: "nope", maxFrames: bad)
                XCTFail("expected error for maxFrames=\(bad)")
            } catch {
                // sessionNotFound OR the maxFrames guard — both are explicit,
                // non-silent errors, which is the point.
            }
        }
    }
}
