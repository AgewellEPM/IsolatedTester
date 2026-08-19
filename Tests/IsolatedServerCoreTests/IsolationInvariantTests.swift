import XCTest

/// 2026-08-18 incident pins: a hidden `fallbackToMainDisplay` default of TRUE
/// let a failed virtual display silently take over the user's live desktop
/// (windows moved onto the real screen, session input driving it). These tests
/// pin the isolation invariant on EVERY surface where the pattern lived — one
/// assertion per file, so a regression names the exact site that broke.
final class IsolationInvariantTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // IsolatedServerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Source with `//` comment lines removed — the invariants ban CODE, and
    /// comments legitimately name the banned tokens to explain their absence.
    private func codeOnly(_ src: String) -> [String] {
        src.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    // MARK: - Site 1: MCP tool handler

    func testMCPHandler_neverDefaultsToMainDisplay() throws {
        let src = try source("Sources/IsolatedMCPServer/MCPToolHandlers.swift")
        for line in src.split(separator: "\n") where line.contains("fallbackToMainDisplay") {
            XCTAssertFalse(line.contains("?? true"),
                "MCPToolHandlers.swift: fallbackToMainDisplay must never default to true: \(line)")
        }
        XCTAssertTrue(src.contains("fallbackToMainDisplay was removed"),
            "MCPToolHandlers.swift must refuse an explicit fallbackToMainDisplay=true loudly")
    }

    // MARK: - Site 2: HTTP router

    func testHTTPRouter_neverDefaultsToMainDisplay() throws {
        let src = try source("Sources/IsolatedHTTPServer/Router.swift")
        for line in src.split(separator: "\n") where line.contains("fallbackToMainDisplay") {
            XCTAssertFalse(line.contains("?? true"),
                "Router.swift: fallbackToMainDisplay must never default to true: \(line)")
        }
        XCTAssertTrue(src.contains("fallbackToMainDisplay was removed"),
            "Router.swift must refuse an explicit fallbackToMainDisplay=true loudly")
    }

    // MARK: - Site 3: SessionManager

    func testSessionManager_hasNoMainDisplayFallbackParameter() throws {
        let src = try source("Sources/IsolatedServerCore/SessionManager.swift")
        XCTAssertFalse(src.contains("fallbackToMainDisplay"),
            "SessionManager.swift must not carry a main-display fallback parameter at all")
    }

    // MARK: - Site 4: TestSession

    func testTestSession_startHasNoMainDisplayFallback() throws {
        let code = codeOnly(try source("Sources/IsolatedTesterKit/Session/TestSession.swift"))
        XCTAssertFalse(code.contains { $0.contains("fallbackToMainDisplay") },
            "TestSession.swift: start() must not offer a main-display fallback — "
            + "isolation degrades to headless, never the user's screen")
    }

    // MARK: - Site 5: InputController

    func testInputController_hasNoGlobalTapPath() throws {
        let src = try source("Sources/IsolatedTesterKit/Input/InputController.swift")
        let code = codeOnly(src)
        XCTAssertFalse(code.contains { $0.contains("cghidEventTap") || $0.contains("post(tap") },
            "InputController.swift must never post to the global HID tap — "
            + "that drives the user's real cursor and keyboard")
        XCTAssertTrue(src.contains("noTargetProcess"),
            "InputController.swift must refuse input without a session-owned target PID")
    }

    // MARK: - Site 6: CLI

    func testCLI_mainDisplayOnlyBehindExplicitFlag() throws {
        let src = try source("Sources/CLI/IsolatedCommand.swift")
        let callLines = src.split(separator: "\n")
            .filter { $0.contains("startOnMainDisplay(") && !$0.contains("//") }
        XCTAssertFalse(callLines.isEmpty, "expected guarded startOnMainDisplay call sites in the CLI")
        for line in callLines {
            XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("?"),
                "IsolatedCommand.swift: startOnMainDisplay must only run behind the explicit "
                + "--on-main-display ternary, found unguarded call: \(line)")
        }
    }

    // MARK: - Site 7: VirtualDisplayManager

    func testVirtualDisplay_isCornerPinned() throws {
        let src = try source("Sources/IsolatedTesterKit/Display/VirtualDisplayManager.swift")
        XCTAssertTrue(src.contains("CGConfigureDisplayOrigin"),
            "VirtualDisplayManager.swift must corner-pin the virtual display so the user's "
            + "cursor cannot slide off a shared edge into invisible space")
    }
}
