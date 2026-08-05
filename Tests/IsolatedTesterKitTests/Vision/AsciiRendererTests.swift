import AppKit
import XCTest
@testable import IsolatedTesterKit

final class AsciiRendererTests: XCTestCase {

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascii-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Left half black, right half white → dense glyphs left, spaces right.
    private func renderHalfImage() throws -> String {
        let size = NSSize(width: 400, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSColor.white.setFill()
        NSRect(x: 200, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 1)
        }
        let path = dir.appendingPathComponent("half.png").path
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLuminanceMapping_darkIsDenseLightIsSpace() throws {
        let grid = try AsciiRenderer.render(path: renderHalfImage(), cols: 40)
        let lines = grid.text.split(separator: "\n")
        XCTAssertEqual(lines.count, grid.rows)
        let middle = Array(lines[lines.count / 2])
        XCTAssertEqual(middle[2], "@", "black region must render as the densest glyph")
        XCTAssertEqual(middle[grid.cols - 3], " ", "white region must render as space")
    }

    func testGridGeometryAndScale() throws {
        let grid = try AsciiRenderer.render(path: renderHalfImage(), cols: 40)
        XCTAssertEqual(grid.cols, 40)
        // 400x200 image, 0.5 cell-aspect correction → rows = 40 * (200/400) * 0.5 = 10
        XCTAssertEqual(grid.rows, 10)
        XCTAssertEqual(grid.pixelsPerCol, 10.0, accuracy: 0.001)
        XCTAssertEqual(grid.pixelsPerRow, 20.0, accuracy: 0.001)
        // Round-trip: grid center cell → source-pixel center
        let x = (Double(grid.cols / 2) + 0.5) * grid.pixelsPerCol
        XCTAssertEqual(x, 205.0, accuracy: 0.001)
    }

    func testOcrOverlayStampsTextAtTruePosition() throws {
        // Observation centered at normalized (0.5, 0.5) with height 0.1
        let observation = FrameOCR.TextObservation(
            text: "OK", confidence: 1.0, bounds: [0.5, 0.45, 0.1, 0.1])
        let grid = try AsciiRenderer.render(
            path: renderHalfImage(), cols: 40, ocrOverlay: [observation])
        let lines = grid.text.split(separator: "\n").map(String.init)
        // row = (1 - 0.45 - 0.05) * 10 = 5 ; col = 0.5 * 40 = 20
        XCTAssertTrue(lines[5].dropFirst(20).hasPrefix("OK"),
                      "OCR text must land at its true grid position, row 5: \(lines[5])")
    }

    func testInvalidColsThrows() throws {
        let path = try renderHalfImage()
        XCTAssertThrowsError(try AsciiRenderer.render(path: path, cols: 5))
        XCTAssertThrowsError(try AsciiRenderer.render(path: path, cols: 999))
    }

    func testUnreadableThrows() {
        XCTAssertThrowsError(try AsciiRenderer.render(
            path: dir.appendingPathComponent("nope.png").path))
    }


    /// Manual harness: ASCII_DEMO_PATH=<png> swift test --filter testDemoRenderFromEnvPath
    /// Renders a real screenshot through the full OCR+ASCII path to /tmp/ascii-demo.txt.
    func testDemoRenderFromEnvPath() throws {
        guard let path = ProcessInfo.processInfo.environment["ASCII_DEMO_PATH"] else {
            throw XCTSkip("set ASCII_DEMO_PATH to render a demo grid")
        }
        let ocr = try FrameOCR.recognize(path: path)
        let grid = try AsciiRenderer.render(path: path, cols: 150, ocrOverlay: ocr.observations)
        try grid.text.write(toFile: "/tmp/ascii-demo.txt", atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(grid.rows, 0)
    }
}
