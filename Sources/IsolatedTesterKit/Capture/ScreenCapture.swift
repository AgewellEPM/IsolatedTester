import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures screenshots from a specific display using ScreenCaptureKit (macOS 14+).
/// This is the Apple-recommended replacement for CGDisplayCreateImage.
public final class ScreenCapture: @unchecked Sendable {

    public enum ImageFormat: String, Sendable {
        case png
        case jpeg
    }

    public struct CaptureResult: Sendable {
        public let displayID: CGDirectDisplayID
        public let imageData: Data
        public let width: Int
        public let height: Int
        public let format: ImageFormat
        public let capturedAt: Date

        public var sizeKB: Int { imageData.count / 1024 }
    }

    public init() {}

    // MARK: - ScreenCaptureKit Capture

    /// Capture a single screenshot from the specified display using ScreenCaptureKit.
    public func capture(
        displayID: CGDirectDisplayID,
        format: ImageFormat = .png,
        jpegQuality: CGFloat = 0.85
    ) async throws -> CaptureResult {
        ISTLogger.capture.debug("Capturing display \(displayID) as \(format.rawValue)")
        // Get the SCDisplay matching our displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DisplayError.captureFailed("Display \(displayID) not found in ScreenCaptureKit")
        }

        // Configure the capture
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = scDisplay.width
        config.height = scDisplay.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        // Capture a single frame
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let data = try encodeImage(image, format: format, quality: jpegQuality)

        return CaptureResult(
            displayID: displayID,
            imageData: data,
            width: image.width,
            height: image.height,
            format: format,
            capturedAt: Date()
        )
    }

    /// Save a capture to disk.
    public func saveToDisk(_ result: CaptureResult, path: String) throws {
        let url = URL(fileURLWithPath: path)
        try result.imageData.write(to: url)
    }

    // MARK: - Encoding

    private func encodeImage(_ image: CGImage, format: ImageFormat, quality: CGFloat) throws -> Data {
        let data = NSMutableData()

        let utType: CFString = switch format {
        case .png: UTType.png.identifier as CFString
        case .jpeg: UTType.jpeg.identifier as CFString
        }

        guard let destination = CGImageDestinationCreateWithData(data, utType, 1, nil) else {
            throw DisplayError.captureFailed("Failed to create image destination")
        }

        let options: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality]
            : [:]

        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw DisplayError.captureFailed("Failed to finalize image")
        }

        return data as Data
    }
}
