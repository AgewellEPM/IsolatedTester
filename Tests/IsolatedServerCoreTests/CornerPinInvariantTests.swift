import XCTest

/// 2026-08-25 live-fire hardening: cornerPin() used to pin the new virtual
/// display relative to CGMainDisplayID()'s bounds and never verified the
/// result. Two real failures followed the same day:
///   (1) With the GhostBridge half-screen workspace active (its virtual
///       display main at (0,0), physical panel parked at (960,0)), the pin
///       landed inside/adjacent to the parked panel's slot and the resulting
///       reconfiguration killed the workspace.
///   (2) On the normal desktop the tester display landed EDGE-adjacent at
///       (1920,0) instead of the corner (1920,1080) — silently normalized by
///       WindowServer — recreating the exact "cursor slides in and vanishes"
///       bug the pin exists to prevent.
/// These tests pin the fix on every behavior, one named assertion per site,
/// so a regression names the exact behavior that broke.
final class CornerPinInvariantTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // IsolatedServerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    private let managerPath = "Sources/IsolatedTesterKit/Display/VirtualDisplayManager.swift"

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Source with `//` comment lines removed — invariants that ban tokens must
    /// not be tripped (or satisfied) by comments that merely mention them.
    private func codeOnly(_ src: String) -> [String] {
        src.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// The corner-pin machinery: cornerPin() plus its applyOrigin helper,
    /// bounded by the next MARK so assertions can't be satisfied (or tripped)
    /// by unrelated code elsewhere in the file.
    private func cornerPinBody() throws -> String {
        let src = try source(managerPath)
        guard let start = src.range(of: "private func cornerPin"),
              let end = src.range(of: "// MARK: - Post-create mirror invariant"),
              start.lowerBound < end.lowerBound else {
            XCTFail("VirtualDisplayManager.swift: cornerPin machinery not found before the "
                + "post-create-mirror MARK — the pin may have been moved or deleted")
            return ""
        }
        return String(src[start.lowerBound..<end.lowerBound])
    }

    // MARK: - Site 1: pin target is the union of ALL online displays

    func testCornerPin_pinsAgainstUnionOfAllOnlineDisplays() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("onlineDisplays()"),
            "cornerPin must census ALL online displays (CGGetOnlineDisplayList via "
            + "onlineDisplays()) — parked/mirrored panels occupy arrangement space too")
        XCTAssertTrue(body.contains("{ $0 != displayID }"),
            "cornerPin's union must EXCLUDE the new virtual display itself — including it "
            + "would drag the union corner onto the display being pinned")
        XCTAssertTrue(body.contains(".union(CGDisplayBounds("),
            "cornerPin must union CGDisplayBounds of every other display — the pin corner is "
            + "diagonal to the ENTIRE arrangement, not any single display")
    }

    // MARK: - Site 2: main-display bounds are banned from the pin computation

    func testCornerPin_doesNotPinRelativeToMainDisplayBounds() throws {
        let code = codeOnly(try cornerPinBody())
        XCTAssertFalse(code.contains { $0.contains("CGMainDisplayID") },
            "cornerPin must NOT reference CGMainDisplayID — pinning relative to the main "
            + "display landed the tester display inside the GhostBridge workspace's parked "
            + "panel slot and killed the workspace (live-fire 2026-08-25)")
        XCTAssertFalse(code.contains { $0.contains("mainBounds") },
            "cornerPin must NOT compute mainBounds — the old single-display pin variable "
            + "must stay deleted")
    }

    // MARK: - Site 3: target is the union's bottom-right corner

    func testCornerPin_targetsUnionMaxCorner() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("union.maxX") && body.contains("union.maxY"),
            "cornerPin must target (union.maxX, union.maxY) — corner-diagonal to the whole "
            + "arrangement, sharing no edge with ANY display")
    }

    // MARK: - Site 4: pin is verified by re-reading bounds, never trusted

    func testCornerPin_verifiesPinByRereadingDisplayBounds() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("CGDisplayBounds(displayID).origin"),
            "cornerPin must re-read CGDisplayBounds(displayID) after committing — "
            + "WindowServer silently normalized (1920,1080) to edge-adjacent (1920,0) live")
        XCTAssertTrue(body.contains("<= 1"),
            "cornerPin's verify must compare within a 1pt tolerance, not exact equality")
    }

    // MARK: - Site 5: mismatch retries exactly once

    func testCornerPin_retriesOnceOnVerifyMismatch() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("for attempt in 1...2"),
            "cornerPin must retry exactly ONCE on a verify mismatch (two attempts total) — "
            + "no retry hides normalization; unbounded retry fights WindowServer forever")
    }

    // MARK: - Site 6: applied pin logs the greppable line

    func testCornerPin_logsGreppableAppliedToken() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("cornerPin=applied origin=("),
            "cornerPin success must log 'cornerPin=applied origin=(x,y)' — greppable")
        XCTAssertTrue(body.contains("union=(") && body.contains("displays=\\("),
            "cornerPin's applied line must include union=(WxH) and displays=N so the log "
            + "tells the whole arrangement story")
    }

    // MARK: - Site 7: unverified pin logs loudly with the greppable token

    func testCornerPin_logsGreppableUnverifiedToken() throws {
        let body = try cornerPinBody()
        XCTAssertTrue(body.contains("cornerPin=unverified origin=("),
            "cornerPin must log 'cornerPin=unverified origin=...' when the pin did not stick "
            + "after the retry — the log must tell the truth about edge adjacency")
        XCTAssertTrue(body.contains("requested=("),
            "cornerPin's unverified line must include requested=(x,y) so the delta from the "
            + "intended corner is visible in the log")
        XCTAssertTrue(codeOnly(try cornerPinBody()).contains { $0.contains("ISTLogger.display.error") },
            "cornerPin's failure paths must log at error level (ISTLogger.display.error), "
            + "not info/debug — this is how a silent normalization becomes visible")
    }

    // MARK: - Site 8: an unverified pin must NOT fail the session

    func testCornerPin_unverifiedPinDoesNotThrow() throws {
        let code = codeOnly(try cornerPinBody())
        XCTAssertFalse(code.contains { $0.contains("throw ") },
            "cornerPin must never throw — visibility over refusal: an unverified pin is "
            + "logged loudly, the session survives, and the mirror invariant still guards "
            + "against takeover")
    }
}
