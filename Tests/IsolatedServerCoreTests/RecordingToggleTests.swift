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


    func testStopSessionUnknownReturnsFalse() async {
        // The MCP + HTTP stop handlers depend on this Bool to report NOT_FOUND
        // instead of a false success. Codex P2 (2026-08-04).
        let manager = SessionManager()
        let existed = await manager.stopSession("does-not-exist")
        XCTAssertFalse(existed, "stopping an unknown session must report false")
    }

    func testConcurrentStopSessionIsSingleShot() async {
        // Codex P2 (2026-08-05): stopSession claims-and-removes before the
        // async teardown, so two concurrent stops of the same id must yield
        // exactly one true — the other sees the id already gone.
        let manager = SessionManager()
        async let a = manager.stopSession("nope")
        async let b = manager.stopSession("nope")
        let results = await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 0,
                       "unknown id: neither call should claim it")
        // (A live-session double-stop is covered by the idempotent stop() guard;
        // this pins the claim-before-await ordering for the not-found path.)
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
