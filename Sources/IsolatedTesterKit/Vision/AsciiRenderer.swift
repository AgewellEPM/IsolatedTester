import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Vision for models that have none: renders a frame into a character grid a
/// text-only model can actually SEE — global shape from luminance glyphs, plus
/// the frame's OCR'd text stamped at its true grid position. The grid carries
/// its own pixel scale, so "the button at row 12, col 40" converts straight
/// back to a clickable coordinate: x = (col + 0.5) * pixelsPerCol.
public enum AsciiRenderer {

    public struct Grid: Codable, Sendable {
        public let cols: Int
        public let rows: Int
        /// Source-image pixels covered by one character cell.
        public let pixelsPerCol: Double
        public let pixelsPerRow: Double
        public let frameSha256: String
        public let width: Int
        public let height: Int
        /// The grid itself, rows top-to-bottom joined with newlines.
        public let text: String
    }

    public enum RenderError: Error, LocalizedError {
        case unreadable(String)
        case notAnImage(String)
        case invalidCols(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Cannot read frame file: \(path)"
            case .notAnImage(let path): return "Frame file is not a decodable image: \(path)"
            case .invalidCols(let cols): return "cols must be 20...400, got \(cols)"
            }
        }
    }

    /// Light → dark glyph ramp.
    private static let ramp: [Character] = Array(" .:-=+*#%@")

    /// Render a frame file to an ASCII grid.
    /// - Parameters:
    ///   - cols: grid width in characters (rows follow the image aspect with a
    ///     0.5 correction for terminal cell shape).
    ///   - ocrOverlay: text observations (Vision-normalized, bottom-left
    ///     origin) stamped onto the grid at their true positions, so exact
    ///     strings survive what luminance alone would blur away.
    ///   - invert: flip the ramp (useful when a dark-themed screen would
    ///     otherwise render as a wall of dense glyphs).
    public static func render(
        path: String,
        cols: Int = 160,
        ocrOverlay: [FrameOCR.TextObservation]? = nil,
        invert: Bool = false
    ) throws -> Grid {
        guard (20...400).contains(cols) else { throw RenderError.invalidCols(cols) }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw RenderError.unreadable(path)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderError.notAnImage(path)
        }

        let width = image.width
        let height = image.height
        let rows = max(1, Int((Double(cols) * Double(height) / Double(width)) * 0.5))

        // Downsample into a grayscale cols×rows bitmap: one byte per cell.
        guard let context = CGContext(
            data: nil, width: cols, height: rows,
            bitsPerComponent: 8, bytesPerRow: cols,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw RenderError.notAnImage(path)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let buffer = context.data else { throw RenderError.notAnImage(path) }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: cols * rows)

        var grid: [[Character]] = []
        grid.reserveCapacity(rows)
        for row in 0..<rows {
            // CGContext row 0 is the bottom — emit top-first.
            let contextRow = rows - 1 - row
            var line: [Character] = []
            line.reserveCapacity(cols)
            for col in 0..<cols {
                var luminance = Double(pixels[contextRow * cols + col]) / 255.0
                if invert { luminance = 1.0 - luminance }
                // dark → dense glyph
                let index = Int((1.0 - luminance) * Double(ramp.count - 1) + 0.5)
                line.append(ramp[max(0, min(ramp.count - 1, index))])
            }
            grid.append(line)
        }

        // Stamp OCR text at its true grid position (top-left origin).
        for observation in ocrOverlay ?? [] {
            guard observation.bounds.count >= 4 else { continue }
            let normX = observation.bounds[0]
            let normY = observation.bounds[1]
            let normH = observation.bounds[3]
            let row = Int((1.0 - normY - normH / 2.0) * Double(rows))
            let col = Int(normX * Double(cols))
            guard row >= 0, row < rows else { continue }
            var cursor = max(0, col)
            for char in observation.text {
                guard cursor < cols else { break }
                grid[row][cursor] = char
                cursor += 1
            }
        }

        return Grid(
            cols: cols,
            rows: rows,
            pixelsPerCol: Double(width) / Double(cols),
            pixelsPerRow: Double(height) / Double(rows),
            frameSha256: digest,
            width: width,
            height: height,
            text: grid.map { String($0) }.joined(separator: "\n")
        )
    }
}
