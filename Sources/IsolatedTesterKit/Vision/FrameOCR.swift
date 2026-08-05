import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// Frame-BOUND OCR: reads the frame file once, hashes the exact bytes it read,
/// and runs Apple Vision text recognition on those same bytes. The returned
/// sha256 is the digest of what was actually OCR'd — no frame can be swapped
/// between capture and recognition (the Perslis VMVision discipline,
/// reimplemented natively; no Perslis source is shared).
public enum FrameOCR {

    public struct TextObservation: Codable, Sendable {
        public let text: String
        public let confidence: Float
        /// Vision-normalized bounding box [x, y, width, height], origin bottom-left.
        public let bounds: [Double]
    }

    public struct Result: Codable, Sendable {
        public let frameSha256: String
        public let width: Int
        public let height: Int
        public let observations: [TextObservation]
    }

    public enum OCRError: Error, LocalizedError {
        case unreadable(String)
        case notAnImage(String)
        case hashMismatch(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Cannot read frame file: \(path)"
            case .notAnImage(let path): return "Frame file is not a decodable image: \(path)"
            case .hashMismatch(let expected, let actual):
                return "Frame bytes changed since capture (expected sha256 \(expected.prefix(12))…, got \(actual.prefix(12))…) — refusing to OCR a swapped frame"
            }
        }
    }

    /// OCR a frame file. When `expectedSha256` is given, refuse to proceed if
    /// the bytes on disk no longer match — evidence must bind to exact bytes.
    public static func recognize(path: String, expectedSha256: String? = nil) throws -> Result {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw OCRError.unreadable(path)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expected = expectedSha256, expected.lowercased() != digest {
            throw OCRError.hashMismatch(expected: expected.lowercased(), actual: digest)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.notAnImage(path)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations: [TextObservation] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: [box.origin.x, box.origin.y, box.size.width, box.size.height]
            )
        }

        return Result(
            frameSha256: digest,
            width: image.width,
            height: image.height,
            observations: observations
        )
    }
}
