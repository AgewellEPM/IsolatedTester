import AVFoundation
import AppKit
import XCTest
@testable import IsolatedTesterKit

final class SessionVideoRecorderTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func solidJPEG(_ color: NSColor, w: Int = 320, h: Int = 240) throws -> Data {
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            throw NSError(domain: "test", code: 1)
        }
        return jpeg
    }

    func testProducesPlayableMp4WithMetadata() async throws {
        let url = dir.appendingPathComponent("session.mp4")
        let recorder = SessionVideoRecorder(url: url, fps: 6)
        recorder.metadataProvider = {
            [
                SessionVideoRecorder.item(.commonKeyTitle, "IsolatedTester test"),
                SessionVideoRecorder.item(.commonKeyDescription, "12-frame synthetic run"),
                SessionVideoRecorder.userItem("session_id", "test123"),
                SessionVideoRecorder.userItem("objective", "prove the recorder works"),
            ]
        }
        for i in 0..<12 {
            let color: NSColor = i % 2 == 0 ? .systemBlue : .systemRed
            recorder.append(imageData: try solidJPEG(color))
        }
        let path = await recorder.finish()
        XCTAssertNotNil(path, "a non-empty recording must return a path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // The file must be a real, non-zero-duration movie.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "movie must have real duration")

        // Metadata must be embedded and readable.
        let items = try await asset.load(.commonMetadata)
        let title = items.first { $0.commonKey == .commonKeyTitle }
        XCTAssertNotNil(title, "title metadata must survive into the mp4")
    }

    func testEmptyRecorderReturnsNil() async {
        let recorder = SessionVideoRecorder(url: dir.appendingPathComponent("empty.mp4"))
        let path = await recorder.finish()
        XCTAssertNil(path, "no frames → no video file claimed")
    }

    func testFinishIsIdempotent() async throws {
        let recorder = SessionVideoRecorder(url: dir.appendingPathComponent("once.mp4"), fps: 6)
        for _ in 0..<4 { recorder.append(imageData: try solidJPEG(.green)) }
        let first = await recorder.finish()
        let second = await recorder.finish()
        XCTAssertEqual(first, second, "second finish returns the same path, no crash")
    }
}
