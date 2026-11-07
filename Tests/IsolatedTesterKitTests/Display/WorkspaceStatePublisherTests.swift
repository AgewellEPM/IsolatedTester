import CoreGraphics
import XCTest
@testable import IsolatedTesterKit

final class WorkspaceStatePublisherTests: XCTestCase {
    private let state = WorkspaceMonitor.State(displayID: kCGNullDirectDisplay, pointerGuard: true)

    func testDiskFullDoesNotThrowAndRetriesOnlyAfterCooldown() {
        var attempts = 0
        var storageAvailable = false
        var saved: WorkspaceMonitor.State?
        var publisher = WorkspaceStatePublisher { state in
            attempts += 1
            guard storageAvailable else { throw CocoaError(.fileWriteOutOfSpace) }
            saved = state
        }
        let error = publisher.publish(state, at: 100) as? CocoaError
        XCTAssertEqual(error?.code, .fileWriteOutOfSpace)
        for tick in stride(from: 102.0, to: 130, by: 2) {
            XCTAssertNil(publisher.publish(state, at: tick))
        }
        XCTAssertEqual(attempts, 1, "Health ticks must not retry writes or request host teardown")
        storageAvailable = true
        XCTAssertNil(publisher.publish(state, at: 130))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(saved, state, "Publication recovers without restarting the display")
    }

    func testRepeatedStorageFailureHasBoundedAttempts() {
        var attempts = 0
        var publisher = WorkspaceStatePublisher { _ in
            attempts += 1
            throw CocoaError(.fileWriteOutOfSpace)
        }
        for tick in stride(from: 0.0, through: 120, by: 2) {
            _ = publisher.publish(state, at: tick)
        }
        XCTAssertEqual(attempts, 5)
    }

    func testUnchangedStateDoesNotRewriteAndMissingFileIsRestored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitor.json")
        try WorkspaceMonitor.save(state, to: url)
        let marker = Date(timeIntervalSince1970: 1234)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: url.path)
        try WorkspaceMonitor.save(state, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, marker)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try FileManager.default.removeItem(at: url)
        try WorkspaceMonitor.save(state, to: url)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceMonitor.State.self, from: Data(contentsOf: url)), state)

        let changed = WorkspaceMonitor.State(displayID: kCGNullDirectDisplay, pointerGuard: false)
        try WorkspaceMonitor.save(changed, to: url)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceMonitor.State.self, from: Data(contentsOf: url)), changed)
    }
}
