import XCTest

/// 2026-08-25 hardening: macOS may AUTO-MIRROR on CGVirtualDisplay creation
/// (GhostBridge's equivalent code observed creation auto-mirroring its own
/// display). If that ever happens here, the user's REAL panel ends up in a
/// mirror set — a desktop takeover. These tests pin the post-create mirror
/// invariant on every site where it lives, one named assertion per site, so a
/// regression names the exact site that broke.
final class MirrorInvariantTests: XCTestCase {

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

    // MARK: - Site 1: create path runs the mirror check, AFTER corner-pin

    func testCreatePath_runsPostCreateMirrorCheckAfterCornerPin() throws {
        let src = try source(managerPath)
        let pin = src.range(of: "cornerPin(displayID: displayIDValue)")
        let enforce = src.range(of: "try enforcePostCreateMirrorInvariant(virtualDisplayID: displayIDValue)")
        XCTAssertNotNil(pin,
            "VirtualDisplayManager.swift: create path must corner-pin the new virtual display")
        XCTAssertNotNil(enforce,
            "VirtualDisplayManager.swift: create path must run the post-create mirror invariant — "
            + "CGVirtualDisplay creation may auto-mirror the user's real panel")
        if let pin, let enforce {
            XCTAssertLessThan(pin.lowerBound, enforce.lowerBound,
                "VirtualDisplayManager.swift: mirror check must run AFTER corner-pin so it audits "
                + "the final post-create display topology")
        }
    }

    // MARK: - Site 2: happy path emits the greppable clean line

    func testMirrorCheck_happyPathLogsCleanLine() throws {
        let src = try source(managerPath)
        XCTAssertTrue(src.contains("postCreateMirrorCheck=clean"),
            "VirtualDisplayManager.swift: happy path must log 'postCreateMirrorCheck=clean' — "
            + "the live probe greps for exactly this string")
    }

    // MARK: - Site 3: violation path heals in one transaction and logs both outcomes

    func testMirrorCheck_violationPathHealsAndLogs() throws {
        let src = try source(managerPath)
        XCTAssertTrue(src.contains("postCreateMirrorCheck=violation_detected"),
            "VirtualDisplayManager.swift: violation must be logged loudly as "
            + "'postCreateMirrorCheck=violation_detected'")
        XCTAssertTrue(src.contains("postCreateMirrorCheck=violation_healed"),
            "VirtualDisplayManager.swift: successful unmirror must be logged as "
            + "'postCreateMirrorCheck=violation_healed'")
        XCTAssertTrue(codeOnly(src).contains { $0.contains("CGConfigureDisplayMirrorOfDisplay") },
            "VirtualDisplayManager.swift: healing must actually unmirror via "
            + "CGConfigureDisplayMirrorOfDisplay in a display-configuration transaction")
    }

    // MARK: - Site 4: failure path destroys the display and throws, naming gb-restore

    func testMirrorCheck_failurePathDestroysDisplayAndThrows() throws {
        let src = try source(managerPath)
        XCTAssertTrue(src.contains("postCreateMirrorCheck=violation_unhealed"),
            "VirtualDisplayManager.swift: an unhealed mirror must be logged as "
            + "'postCreateMirrorCheck=violation_unhealed'")
        XCTAssertTrue(codeOnly(src).contains { $0.contains("destroyDisplay(id: virtualDisplayID)") },
            "VirtualDisplayManager.swift: an unhealed mirror must tear the new virtual display "
            + "down (destroyDisplay) — a session may never keep the user's panel mirrored")
        XCTAssertTrue(src.contains("gb-restore"),
            "VirtualDisplayManager.swift: the failure error must name gb-restore so the user "
            + "knows how to recover their display layout")
        // The throw must live inside the enforcement function's failure path.
        guard let enforceStart = src.range(of: "private func enforcePostCreateMirrorInvariant") else {
            return XCTFail("VirtualDisplayManager.swift: enforcePostCreateMirrorInvariant missing")
        }
        let enforceBody = String(src[enforceStart.lowerBound...])
        XCTAssertTrue(enforceBody.contains("throw DisplayError.creationFailed"),
            "VirtualDisplayManager.swift: enforcePostCreateMirrorInvariant must throw "
            + "DisplayError.creationFailed when unmirroring fails")
    }

    // MARK: - Site 5: real-vs-virtual discrimination uses the vendor 505 / product 0 stamp

    func testMirrorCheck_identifiesRealDisplaysByVendorStamp() throws {
        let src = try source(managerPath)
        let code = codeOnly(src)
        XCTAssertTrue(code.contains { $0.contains("CGDisplayVendorNumber") && $0.contains("505") },
            "VirtualDisplayManager.swift: 'real display' must mean NOT vendor 505 — "
            + "the stamp our own virtual displays carry")
        XCTAssertTrue(code.contains { $0.contains("CGDisplayModelNumber") },
            "VirtualDisplayManager.swift: vendor check must be paired with the product-0 "
            + "check (CGDisplayModelNumber) so a coincidental vendor match can't hide a real panel")
    }

    // MARK: - Site 6: dead useSecondaryDisplay API is gone

    func testUseSecondaryDisplay_removedFromPublicAPI() throws {
        let code = codeOnly(try source(managerPath))
        XCTAssertFalse(code.contains { $0.contains("useSecondaryDisplay") },
            "VirtualDisplayManager.swift: useSecondaryDisplay() must stay deleted — it could "
            + "register a REAL display (external monitor) as a test surface")
    }
}
