import CoreGraphics
import XCTest
@testable import IsolatedTesterKit

final class AppLauncherPlacementTests: XCTestCase {
    private let workspace = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    private let pid: pid_t = 77

    private func window(_ frame: CGRect, visible: Bool? = nil, owner: pid_t = 77) -> [String: Any] {
        var row: [String: Any] = [kCGWindowOwnerPID as String: owner,
                                 kCGWindowLayer as String: 0,
                                 kCGWindowBounds as String: frame.dictionaryRepresentation]
        if let visible { row[kCGWindowIsOnscreen as String] = visible }
        return row
    }

    func testHiddenSafariHelpersDoNotRejectPlacedVisibleWindow() {
        // Bounds/visibility observed in an actual failed Safari launch. Helper
        // windows omit IsOnscreen, while the placed browser window is true.
        let rows = [window(CGRect(x: 0, y: 1440, width: 844, height: 16)),
                    window(CGRect(x: -1424, y: 32, width: 1408, height: 852), visible: true),
                    window(CGRect(x: 0, y: 940, width: 500, height: 500))]
        XCTAssertTrue(AppLauncher.visibleWindowsAreWithinBounds(rows, pid: pid, bounds: workspace))
    }

    func testNewlyVisibleHostWindowImmediatelyBlocksInput() {
        var rows = [window(CGRect(x: -1424, y: 32, width: 1408, height: 852), visible: true)]
        rows.append(window(CGRect(x: 0, y: 940, width: 500, height: 500), visible: true))
        XCTAssertFalse(AppLauncher.visibleWindowsAreWithinBounds(rows, pid: pid, bounds: workspace))
    }

    func testHiddenOnlyOrOtherProcessWindowCannotEstablishIsolation() {
        let rows = [window(CGRect(x: -1424, y: 32, width: 800, height: 600), visible: false),
                    window(CGRect(x: -1424, y: 32, width: 800, height: 600), visible: true, owner: 88)]
        XCTAssertFalse(AppLauncher.visibleWindowsAreWithinBounds(rows, pid: pid, bounds: workspace))
    }

    func testPartlyOverlappingVisibleWindowIsNotIsolated() {
        let rows = [window(CGRect(x: -300, y: 32, width: 800, height: 600), visible: true)]
        XCTAssertFalse(AppLauncher.visibleWindowsAreWithinBounds(rows, pid: pid, bounds: workspace))
    }
}
