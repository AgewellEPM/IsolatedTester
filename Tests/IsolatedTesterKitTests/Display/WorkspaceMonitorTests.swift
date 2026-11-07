import XCTest
import CoreGraphics
@testable import IsolatedTesterKit

final class WorkspaceMonitorTests: XCTestCase {
    func testWorkspaceGoesLeftOfEveryDisplayIncludingParkedPanels() {
        let displays = [CGRect(x: 0, y: 0, width: 3440, height: 1440),
                        CGRect(x: -1920, y: -400, width: 1920, height: 1080)]
        let origin = VirtualDisplayManager.workspaceOrigin(existing: displays, width: 1440)
        XCTAssertEqual(origin, CGPoint(x: -3360, y: -400))
        let workspace = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
        XCTAssertFalse(displays.contains { $0.intersects(workspace) })
    }

    @MainActor
    func testPhysicalPointerStaysOnHostAfterWorkspaceCrossing() {
        let desktop = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        XCTAssertEqual(WorkspaceHost.allowedPoint(CGPoint(x: -700, y: 200), displays: [desktop]),
                       CGPoint(x: 0, y: 200))
        XCTAssertEqual(WorkspaceHost.allowedPoint(CGPoint(x: 3439, y: 1400), displays: [desktop]),
                       CGPoint(x: 3439, y: 1400))
    }

    func testLeasePreventsConcurrentProcessesAndReleasesForNextSession() throws {
        let name = "unit-" + UUID().uuidString
        var first: WorkspaceLease? = try WorkspaceLease(name: name)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try WorkspaceLease(name: name))
        first = nil
        XCTAssertNoThrow(try WorkspaceLease(name: name))
        try FileManager.default.removeItem(at: WorkspaceMonitor.directory.appendingPathComponent(name + ".lock"))
    }

    func testWorkspaceInputRefusesHostWindowBeforeDispatch() {
        let controller = InputController(displayID: CGMainDisplayID(),
                                         targetPID: ProcessInfo.processInfo.processIdentifier,
                                         windowRelative: true, requireWorkspace: true)
        XCTAssertThrowsError(try controller.typeText("must not reach desktop"))
    }
}
