import CoreGraphics
import XCTest
@testable import IsolatedTesterKit

/// Pure parsing only: never construct InputController, a session, or CGEvent.
final class KeyCombinationTests: XCTestCase {
    func testAllExistingSingleKeysRetainTheirCodesAndNoModifiers() throws {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=[];'\\,./` ").map(String.init)
        let names = ["return", "enter", "tab", "space", "delete", "backspace", "forwarddelete",
                     "fwddelete", "escape", "esc", "up", "down", "left", "right", "home", "end",
                     "pageup", "pagedown"] + (1...12).map { "f\($0)" }
        for name in characters + names + names.map({ $0.uppercased() }) {
            let expected = try XCTUnwrap(InputController.KeyCode.fromString(name), name)
            let parsed = try KeyCombination.parse(key: name)
            XCTAssertEqual(parsed.keyCode, expected, name)
            XCTAssertEqual(parsed.modifiers, [], name)
        }
    }

    func testAdvertisedCommandCAndWindowsStyleControlC() throws {
        let command = try KeyCombination.parse(key: "cmd+c")
        XCTAssertEqual(command.keyCode, InputController.KeyCode.c)
        XCTAssertEqual(command.modifiers, .maskCommand)
        let control = try KeyCombination.parse(key: "ctrl+c")
        XCTAssertEqual(control.keyCode, InputController.KeyCode.c)
        XCTAssertEqual(control.modifiers, .maskControl)
    }

    func testAllModifierAliasesCaseInsensitiveAndMerged() throws {
        for (name, expected) in [("cmd", CGEventFlags.maskCommand), ("command", .maskCommand),
                                 ("shift", .maskShift), ("alt", .maskAlternate),
                                 ("option", .maskAlternate), ("ctrl", .maskControl), ("control", .maskControl)] {
            let parsed = try KeyCombination.parse(key: "\(name.uppercased())+TAB", modifiers: [name])
            XCTAssertEqual(parsed.keyCode, InputController.KeyCode.tab)
            XCTAssertEqual(parsed.modifiers, expected)
        }
        let parsed = try KeyCombination.parse(key: " command + shift + c ", modifiers: ["CMD", "alt", "control", "option"])
        XCTAssertEqual(parsed.modifiers, [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        XCTAssertEqual(InputController.physicalModifierKeys(for: parsed.modifiers), [0x37, 0x38, 0x3A, 0x3B])
    }

    func testPunctuationAndSpaceCombination() throws {
        XCTAssertEqual(try KeyCombination.parse(key: "shift+=").keyCode, InputController.KeyCode.fromString("="))
        XCTAssertEqual(try KeyCombination.parse(key: "cmd+space").keyCode, InputController.KeyCode.space)
        XCTAssertEqual(try KeyCombination.parse(key: " ", modifiers: ["ctrl"]).modifiers, .maskControl)
    }

    func testInvalidKeysFailInsteadOfFallingBackToA() {
        for key in [nil, "", "  ", "\n", "unknownKey", "☃", "cmd", "shift", "cmd+", "+c",
                    "cmd++c", "c+cmd", "c+v", "cmd+shift", "meta+c", "+", "cmd++", "ctrl+unknown"] as [String?] {
            XCTAssertThrowsError(try KeyCombination.parse(key: key), "\(String(describing: key))") { error in
                XCTAssertTrue(error is KeyCombinationError)
            }
        }
    }

    func testInvalidExplicitModifiersFailClosed() {
        for modifier in ["", " ", "meta", "win", "fn", "cmd+shift", "c", "ctrl\n"] {
            XCTAssertThrowsError(try KeyCombination.parse(key: "c", modifiers: ["cmd", modifier]), modifier)
        }
    }

    func testParsingBounds() {
        XCTAssertThrowsError(try KeyCombination.parse(key: String(repeating: "c", count: 129)))
        XCTAssertThrowsError(try KeyCombination.parse(key: "c", modifiers: Array(repeating: "cmd", count: 17)))
        XCTAssertThrowsError(try KeyCombination.parse(key: String(repeating: "cmd+", count: 17) + "c"))
        XCTAssertNoThrow(try KeyCombination.parse(key: "c", modifiers: Array(repeating: "cmd", count: 16)))
    }
}
