import XCTest
@testable import IsolatedServerCore
import IsolatedTesterKit

/// Regression tests for the narrow self-substrate keystroke guard (gap #1).
/// Pins that the guard refuses input to a window literally showing a Kist
/// self-restart, and — critically — leaves ordinary "continue" prompts alone
/// so it can't block legitimate work (false-positive avoidance).
final class SubstrateGuardTests: XCTestCase {

    // MARK: matcher — must REFUSE

    func testRefusesLaunchctlKickstartOfConsole() {
        let t = "Would you like to run: launchctl kickstart -k gui/501/com.kist.desktop-vision-console"
        XCTAssertNotNil(SubstrateGuard.selfRestartReason(inWindowText: t))
    }

    func testRefusesBootoutAndUnloadAndKill() {
        for cmd in [
            "launchctl bootout gui/501/com.kist.desktop-vision-console",
            "launchctl unload ~/Library/LaunchAgents/com.kist.runtime.plist",
            "pkill -f desktop-vision-console",
            "killall com.kist.runtime",
            "lsof -ti:8765 | xargs kill -9",
            "fuser -k 8765/tcp",
        ] {
            XCTAssertNotNil(SubstrateGuard.selfRestartReason(inWindowText: cmd), "should refuse: \(cmd)")
        }
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(SubstrateGuard.selfRestartReason(
            inWindowText: "LAUNCHCTL KICKSTART -K COM.KIST.DESKTOP-VISION-CONSOLE"))
    }

    // MARK: matcher — must ALLOW (no false positives)

    func testAllowsOrdinaryContinuePrompts() {
        for t in [
            "Do you want to continue? [y/N]",
            "Press enter to confirm or esc to cancel",
            "git push origin main? (y)",
            "launchctl list",                                   // read-only
            "launchctl print gui/501/com.kist.runtime",         // read-only introspection
            "launchctl kickstart -k gui/501/com.apple.Dock",    // not a com.kist.* target
            "npm run build && restart the dev server",          // 'restart' but no substrate target
        ] {
            XCTAssertNil(SubstrateGuard.selfRestartReason(inWindowText: t), "should allow: \(t)")
        }
    }

    // MARK: flatten — pulls text from label/value/identifier across the tree

    func testFlattenCollectsNestedText() {
        let tree = AXElement(
            role: "AXWindow", label: "Terminal",
            children: [
                AXElement(role: "AXStaticText", value: "Would you like to run the following command?"),
                AXElement(role: "AXStaticText",
                          value: "launchctl kickstart -k gui/501/com.kist.desktop-vision-console"),
            ]
        )
        let text = SubstrateGuard.flatten(tree)
        XCTAssertTrue(text.contains("com.kist.desktop-vision-console"))
        XCTAssertNotNil(SubstrateGuard.selfRestartReason(inWindowText: text),
                        "flattened tree text must trip the guard")
    }

    func testFlattenOfBenignTreeIsAllowed() {
        let tree = AXElement(
            role: "AXWindow", label: "Notes",
            children: [AXElement(role: "AXStaticText", value: "Continue writing the report?")]
        )
        XCTAssertNil(SubstrateGuard.selfRestartReason(inWindowText: SubstrateGuard.flatten(tree)))
    }
}
