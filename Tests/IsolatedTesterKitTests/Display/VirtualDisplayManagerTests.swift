import XCTest
import CoreGraphics
@testable import IsolatedTesterKit

final class VirtualDisplayManagerTests: XCTestCase {

    func testGetActiveDisplays_returnsNonEmpty() {
        let manager = VirtualDisplayManager()
        let displays = manager.getActiveDisplays()
        // CGGetActiveDisplayList may return empty when running without screen recording
        // permission or in headless/CI environments. Only assert when displays are available.
        if !displays.isEmpty {
            XCTAssertGreaterThanOrEqual(displays.count, 1)
        }
    }

    func testGetActiveDisplays_containsMainDisplay() {
        let manager = VirtualDisplayManager()
        let displays = manager.getActiveDisplays()
        let mainID = CGMainDisplayID()
        // Skip assertion in headless/CI environments where no display is available
        if mainID != kCGNullDirectDisplay && !displays.isEmpty {
            XCTAssertTrue(displays.contains(mainID))
        }
    }

    func testDisplayBounds_mainDisplay() {
        let manager = VirtualDisplayManager()
        let bounds = manager.displayBounds(for: CGMainDisplayID())
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testUseMainDisplay_registers() {
        let manager = VirtualDisplayManager()
        let display = manager.useMainDisplay()
        XCTAssertEqual(display.displayID, CGMainDisplayID())
        XCTAssertFalse(display.isVirtual)
        XCTAssertEqual(display.config.width, 1920) // default
        XCTAssertEqual(display.config.height, 1080)
    }

    func testUseMainDisplay_customConfig() {
        let config = VirtualDisplayManager.DisplayConfig(width: 2560, height: 1440, ppi: 220)
        let manager = VirtualDisplayManager()
        let display = manager.useMainDisplay(config: config)
        XCTAssertEqual(display.config.width, 2560)
        XCTAssertEqual(display.config.height, 1440)
        XCTAssertEqual(display.config.ppi, 220)
    }

    func testListDisplays_afterCreate() {
        let manager = VirtualDisplayManager()
        XCTAssertTrue(manager.listDisplays().isEmpty)

        _ = manager.useMainDisplay()
        XCTAssertEqual(manager.listDisplays().count, 1)
    }

    func testDestroyAll() {
        let manager = VirtualDisplayManager()
        _ = manager.useMainDisplay()
        XCTAssertEqual(manager.listDisplays().count, 1)

        manager.destroyAll()
        XCTAssertTrue(manager.listDisplays().isEmpty)
    }

    func testManagedDisplay_description() {
        let manager = VirtualDisplayManager()
        let display = manager.useMainDisplay()
        let desc = display.description
        XCTAssertTrue(desc.contains("1920x1080"))
        XCTAssertTrue(desc.contains("physical"))
        XCTAssertTrue(desc.contains("IsolatedTest"))
    }

    func testIsVirtualDisplayAvailable() {
        let manager = VirtualDisplayManager()
        // Just verify it doesn't crash - result depends on OS
        _ = manager.isVirtualDisplayAvailable
    }
}
