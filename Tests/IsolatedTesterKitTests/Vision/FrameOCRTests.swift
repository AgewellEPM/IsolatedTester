import AppKit
import XCTest
@testable import IsolatedTesterKit

final class FrameOCRTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frameocr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func renderTextImage(_ text: String) throws -> String {
        let size = NSSize(width: 600, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 40, y: 70),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48),
                             .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 1)
        }
        let path = dir.appendingPathComponent("text.png").path
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testRecognizeReadsRenderedText() throws {
        let path = try renderTextImage("HELLO 300")
        let result = try FrameOCR.recognize(path: path)
        let allText = result.observations.map(\.text).joined(separator: " ")
        XCTAssertTrue(allText.localizedCaseInsensitiveContains("HELLO"),
                      "OCR should read the rendered text, got: \(allText)")
        XCTAssertEqual(result.frameSha256.count, 64, "sha256 hex digest expected")
    }

    func testHashMismatchIsRefused() throws {
        let path = try renderTextImage("X")
        XCTAssertThrowsError(try FrameOCR.recognize(path: path, expectedSha256: String(repeating: "0", count: 64))) { error in
            guard case FrameOCR.OCRError.hashMismatch = error else {
                return XCTFail("expected hashMismatch, got \(error)")
            }
        }
    }

    func testMatchingHashIsAccepted() throws {
        let path = try renderTextImage("Y")
        let first = try FrameOCR.recognize(path: path)
        let second = try FrameOCR.recognize(path: path, expectedSha256: first.frameSha256)
        XCTAssertEqual(second.frameSha256, first.frameSha256)
    }

    func testUnreadableFileThrows() {
        XCTAssertThrowsError(try FrameOCR.recognize(path: dir.appendingPathComponent("missing.png").path)) { error in
            guard case FrameOCR.OCRError.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }
}
