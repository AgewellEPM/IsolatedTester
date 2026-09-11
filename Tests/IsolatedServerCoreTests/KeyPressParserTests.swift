import CoreGraphics
import XCTest
@testable import IsolatedServerCore

/// JSON and actor validation only; the manager remains empty throughout.
final class KeyPressParserTests: XCTestCase {
    func testMCPArgumentsKeepExplicitModifiers() throws {
        let data = Data(#"{"key":"cmd+c","modifiers":["shift","command"]}"#.utf8)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let action = try KeyPressParser.action(arguments: args)
        XCTAssertEqual(action.action, "keyPress")
        XCTAssertEqual(action.key, "cmd+c")
        XCTAssertEqual(action.modifiers, ["shift", "command"])
        let parsed = try KeyPressParser.parse(key: action.key, modifiers: action.modifiers)
        XCTAssertEqual(parsed.keyCode, 0x08)
        XCTAssertEqual(parsed.modifiers, [.maskCommand, .maskShift])
    }

    func testMCPArgumentsRejectWrongTypesAndUnknownModifiers() {
        for args: [String: Any] in [[:], ["key": 7], ["key": NSNull()],
                                   ["key": "c", "modifiers": "cmd"],
                                   ["key": "c", "modifiers": ["cmd", 7]],
                                   ["key": "c", "modifiers": ["meta"]]] {
            XCTAssertThrowsError(try KeyPressParser.action(arguments: args)) { error in
                guard case ServerError.invalidRequest = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
    }

    func testOptionalNullMatchesCodableBehavior() throws {
        XCTAssertNil(try KeyPressParser.action(arguments: ["key": "return", "modifiers": NSNull()]).modifiers)
        let json = Data(#"{"action":"keyPress","key":"return","modifiers":null}"#.utf8)
        let action = try JSONDecoder().decode(ActionRequest.self, from: json)
        XCTAssertNil(action.modifiers)
        XCTAssertNoThrow(try RequestValidator.validate(action))
    }

    func testHTTPJSONUsesSameParserAndRejectsMalformedRequests() throws {
        for json in [#"{"action":"keyPress","key":"ctrl+alt+delete"}"#,
                     #"{"action":"keyPress","key":"c","modifiers":["cmd"]}"#] {
            let action = try JSONDecoder().decode(ActionRequest.self, from: Data(json.utf8))
            XCTAssertNoThrow(try RequestValidator.validate(action))
        }
        for json in [#"{"action":"keyPress","key":"unknownKey"}"#,
                     #"{"action":"keyPress","key":"cmd++c"}"#,
                     #"{"action":"keyPress","key":"c","modifiers":["unknown"]}"#] {
            let action = try JSONDecoder().decode(ActionRequest.self, from: Data(json.utf8))
            XCTAssertThrowsError(try RequestValidator.validate(action))
        }
        let malformed = Data(#"{"action":"keyPress","key":"c","modifiers":"cmd"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ActionRequest.self, from: malformed))
    }

    func testManagerRejectsInvalidKeyBeforeSessionLookupOrPlacement() async {
        let manager = SessionManager()
        for action in [ActionRequest(action: "keyPress", key: "unknownKey"),
                       ActionRequest(action: "keyPress", key: "c", modifiers: ["unknown"]),
                       ActionRequest(action: "keyPress")] {
            do {
                try await manager.performAction(sessionId: "no-session", action: action)
                XCTFail("Invalid key must not report success")
            } catch {
                guard case ServerError.invalidRequest = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        let count = await manager.activeSessionCount
        XCTAssertEqual(count, 0)
    }
}
