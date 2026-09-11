import Foundation
import XCTest
import IsolatedServerCore
@testable import IsolatedMCPServer

/// Real MCP handlers with an empty manager. Never call the server entry point,
/// create_session, attach_vm_session, permissions, or any input/capture methods.
final class KeyPressProtocolTests: XCTestCase {
    func testSchemaAdvertisesModifiersAsStringArray() throws {
        let handler = MCPToolHandlers(sessionManager: SessionManager())
        let tool = try XCTUnwrap(handler.listTools().first { $0["name"] as? String == "key_press" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["sessionId", "key"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let modifiers = try XCTUnwrap(properties["modifiers"] as? [String: Any])
        XCTAssertEqual(modifiers["type"] as? String, "array")
        XCTAssertEqual((modifiers["items"] as? [String: String])?["type"], "string")
    }

    func testUnknownKeyReturnsMCPErrorNotSuccess() async throws {
        let manager = SessionManager()
        let handler = MCPToolHandlers(sessionManager: manager)
        for key in ["unknownKey", "cmd++c", "", "cmd+shift"] {
            let response = await handler.callTool(name: "key_press", arguments: ["sessionId": "not-live", "key": key])
            XCTAssertTrue(response.isError, key)
            let body = try JSONDecoder().decode(ErrorResponse.self, from: Data(response.result.utf8))
            XCTAssertEqual(body.code, "ERROR")
            XCTAssertTrue(body.error.contains("Invalid request:"))
            XCTAssertFalse(response.result.contains("\"success\""))
        }
        let count = await manager.activeSessionCount
        XCTAssertEqual(count, 0)
    }

    func testBadExplicitModifiersAreNotSilentlyDropped() async throws {
        let handler = MCPToolHandlers(sessionManager: SessionManager())
        for modifiers: Any in ["cmd", ["cmd", 7] as [Any], ["meta"]] {
            let response = await handler.callTool(name: "key_press", arguments: ["key": "c", "modifiers": modifiers])
            XCTAssertTrue(response.isError)
            let body = try JSONDecoder().decode(ErrorResponse.self, from: Data(response.result.utf8))
            XCTAssertTrue(body.error.contains("Invalid request:"))
        }
    }

    func testKnownCombosPassParsingButNeverInventSessionSuccess() async throws {
        let handler = MCPToolHandlers(sessionManager: SessionManager())
        for args: [String: Any] in [["key": "cmd+c"], ["key": "c", "modifiers": ["cmd"]],
                                   ["key": "ctrl+alt+delete"], ["key": "return"]] {
            let response = await handler.callTool(name: "key_press", arguments: args)
            XCTAssertTrue(response.isError)
            let body = try JSONDecoder().decode(ErrorResponse.self, from: Data(response.result.utf8))
            XCTAssertTrue(body.error.contains("Session not found:"), body.error)
        }
    }
}
