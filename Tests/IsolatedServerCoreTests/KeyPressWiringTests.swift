import XCTest

/// Source invariants supplement pure protocol tests without posting UI events.
final class KeyPressWiringTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testManagerValidatesBeforePlacementAndUsesResolvedModifiers() throws {
        let text = try source("Sources/IsolatedServerCore/SessionManager.swift")
        let start = try XCTUnwrap(text.range(of: "public func performAction("))
        let body = String(text[start.lowerBound...])
        let parse = try XCTUnwrap(body.range(of: "try KeyPressParser.parse("))
        let placement = try XCTUnwrap(body.range(of: "await session.ensurePlaced()"))
        XCTAssertLessThan(parse.lowerBound, placement.lowerBound)
        XCTAssertTrue(body.contains("try session.keyPress(keyPress.keyCode, modifiers: keyPress.modifiers)"))
        XCTAssertFalse(body.contains("InputController.KeyCode.fromString(keyName)"))
    }

    func testAgentUsesSameParserWithNoUnknownKeyFallback() throws {
        let text = try source("Sources/IsolatedTesterKit/Agent/AITestAgent.swift")
        XCTAssertTrue(text.contains("let keyPress = try KeyCombination.parse(key: key)"))
        XCTAssertTrue(text.contains("try session.keyPress(keyPress.keyCode, modifiers: keyPress.modifiers)"))
        XCTAssertFalse(text.contains("resolveKeyCode("))
        XCTAssertFalse(text.contains("defaulting to 0"))
    }

    func testLedgerRecordsResolvedModifiersOnlyAfterInputReturns() throws {
        let text = try source("Sources/IsolatedTesterKit/Session/TestSession.swift")
        let input = try XCTUnwrap(text.range(of: "try input.keyPress(keyCode, modifiers: modifiers)"))
        let ledger = try XCTUnwrap(text.range(of: #"logAction("keyPress", details: "key=\(keyCode) modifiers=\(modifiers.rawValue)")"#))
        XCTAssertLessThan(input.lowerBound, ledger.lowerBound)
    }
}
