import XCTest
import CoreGraphics
@testable import IsolatedTesterKit

final class InputControllerTests: XCTestCase {

    // MARK: - KeyCode Values

    func testKeyCode_specialKeys() {
        XCTAssertEqual(InputController.KeyCode.returnKey, 0x24)
        XCTAssertEqual(InputController.KeyCode.tab, 0x30)
        XCTAssertEqual(InputController.KeyCode.space, 0x31)
        XCTAssertEqual(InputController.KeyCode.delete, 0x33)
        XCTAssertEqual(InputController.KeyCode.escape, 0x35)
    }

    func testKeyCode_arrows() {
        XCTAssertEqual(InputController.KeyCode.leftArrow, 0x7B)
        XCTAssertEqual(InputController.KeyCode.rightArrow, 0x7C)
        XCTAssertEqual(InputController.KeyCode.downArrow, 0x7D)
        XCTAssertEqual(InputController.KeyCode.upArrow, 0x7E)
    }

    func testKeyCode_letters() {
        XCTAssertEqual(InputController.KeyCode.a, 0x00)
        XCTAssertEqual(InputController.KeyCode.c, 0x08)
        XCTAssertEqual(InputController.KeyCode.v, 0x09)
        XCTAssertEqual(InputController.KeyCode.q, 0x0C)
        XCTAssertEqual(InputController.KeyCode.w, 0x0D)
    }

    func testKeyCode_functionKeys() {
        XCTAssertEqual(InputController.KeyCode.f1, 0x7A)
        XCTAssertEqual(InputController.KeyCode.f2, 0x78)
        XCTAssertEqual(InputController.KeyCode.f12, 0x6F)
    }

    func testKeyCode_fromString_letters() {
        XCTAssertEqual(InputController.KeyCode.fromString("a"), InputController.KeyCode.a)
        XCTAssertEqual(InputController.KeyCode.fromString("z"), InputController.KeyCode.z)
        XCTAssertEqual(InputController.KeyCode.fromString("A"), InputController.KeyCode.a) // case insensitive
    }

    func testKeyCode_fromString_digits() {
        XCTAssertEqual(InputController.KeyCode.fromString("0"), InputController.KeyCode.zero)
        XCTAssertEqual(InputController.KeyCode.fromString("5"), InputController.KeyCode.five)
        XCTAssertEqual(InputController.KeyCode.fromString("9"), InputController.KeyCode.nine)
    }

    func testKeyCode_fromString_namedKeys() {
        XCTAssertEqual(InputController.KeyCode.fromString("return"), InputController.KeyCode.returnKey)
        XCTAssertEqual(InputController.KeyCode.fromString("enter"), InputController.KeyCode.returnKey)
        XCTAssertEqual(InputController.KeyCode.fromString("tab"), InputController.KeyCode.tab)
        XCTAssertEqual(InputController.KeyCode.fromString("escape"), InputController.KeyCode.escape)
        XCTAssertEqual(InputController.KeyCode.fromString("esc"), InputController.KeyCode.escape)
        XCTAssertEqual(InputController.KeyCode.fromString("space"), InputController.KeyCode.space)
        XCTAssertEqual(InputController.KeyCode.fromString("delete"), InputController.KeyCode.delete)
        XCTAssertEqual(InputController.KeyCode.fromString("backspace"), InputController.KeyCode.delete)
    }

    func testKeyCode_fromString_functionKeys() {
        XCTAssertEqual(InputController.KeyCode.fromString("f1"), InputController.KeyCode.f1)
        XCTAssertEqual(InputController.KeyCode.fromString("F12"), InputController.KeyCode.f12)
    }

    func testKeyCode_fromString_unknown() {
        XCTAssertNil(InputController.KeyCode.fromString("unknownKey"))
        XCTAssertNil(InputController.KeyCode.fromString(""))
    }

    // MARK: - InputController Init

    func testInputController_init() {
        let controller = InputController(displayID: CGMainDisplayID())
        XCTAssertNotNil(controller)
    }


    // MARK: - 2026-08-04 regression pins (input honesty + placement)

    func testPhysicalModifierKeys_orderAndCodes() {
        // cmd, shift, option, control — press order matters for chords.
        let keys = InputController.physicalModifierKeys(
            for: [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        XCTAssertEqual(keys, [0x37, 0x38, 0x3A, 0x3B])
    }

    func testPhysicalModifierKeys_singleAndEmpty() {
        XCTAssertEqual(InputController.physicalModifierKeys(for: [.maskCommand]), [0x37])
        XCTAssertEqual(InputController.physicalModifierKeys(for: []), [])
    }

    func testTypeText_deadTargetThrowsTargetNotFound() {
        // A "successful" post to a dead process was how input silently
        // vanished — it must throw, never pretend.
        let controller = InputController(displayID: CGMainDisplayID(), targetPID: 999_999)
        XCTAssertThrowsError(try controller.typeText("x")) { error in
            guard case InputError.targetNotFound = error else {
                return XCTFail("expected targetNotFound, got \(error)")
            }
        }
    }

    func testKeyPress_deadTargetThrowsTargetNotFound() {
        let controller = InputController(displayID: CGMainDisplayID(), targetPID: 999_999)
        XCTAssertThrowsError(try controller.keyPress(InputController.KeyCode.returnKey,
                                                     modifiers: .maskCommand)) { error in
            guard case InputError.targetNotFound = error else {
                return XCTFail("expected targetNotFound, got \(error)")
            }
        }
    }

    // MARK: - 2026-08-18 isolation pins (no global input, grounded coordinates)

    func testNoTargetPID_refusesInputInsteadOfGlobalPost() {
        // Without a session-owned PID, input used to fall through to
        // .cghidEventTap — the user's REAL cursor and keyboard. It must refuse.
        let controller = InputController(displayID: CGMainDisplayID())
        XCTAssertThrowsError(try controller.typeText("x")) { error in
            guard case InputError.noTargetProcess = error else {
                return XCTFail("expected noTargetProcess, got \(error)")
            }
        }
        XCTAssertThrowsError(try controller.keyPress(InputController.KeyCode.returnKey)) { error in
            guard case InputError.noTargetProcess = error else {
                return XCTFail("expected noTargetProcess, got \(error)")
            }
        }
    }

    func testHeadlessClick_withoutWindowThrowsInsteadOfAimingAtMainDisplay() {
        // displayID 0 (headless) has no display bounds. Clicks used to resolve
        // against a zero rect — the main display's coordinate space — and miss
        // the off-screen window while reporting success. With no measurable
        // window to ground against, the click must throw, not guess.
        let controller = InputController(displayID: 0,
                                         targetPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertThrowsError(try controller.click(at: CGPoint(x: 10, y: 10))) { error in
            guard case InputError.cannotGroundCoordinates = error else {
                return XCTFail("expected cannotGroundCoordinates, got \(error)")
            }
        }
    }

    func testLargestWindowFrame_bogusPIDReturnsNil() {
        XCTAssertNil(InputController.largestWindowFrame(pid: 999_999))
    }
}
