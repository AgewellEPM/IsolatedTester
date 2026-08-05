import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Encodes a session's captured frames into a real H.264 .mp4 as they arrive —
/// the whole run, not just the frames still in the ring — so a headless run
/// leaves a watchable video artifact proving what happened. AVAssetWriter /
/// VideoToolbox encode without a window (safe headless).
///
/// Frames are appended on the single capture task, so appends are already
/// serialized; the lock only guards against a finish() racing an append.
public final class SessionVideoRecorder: @unchecked Sendable {

    private let url: URL
    private let fps: Int32
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var width = 0
    private var height = 0
    private var frameCount: Int64 = 0
    private var finished = false
    private let lock = NSLock()

    public var outputPath: String { url.path }
    public var writtenFrames: Int { lock.lock(); defer { lock.unlock() }; return Int(frameCount) }

    /// Called once, when the writer lazily starts on the first frame, to stamp
    /// mp4 metadata (AVAssetWriter requires metadata set BEFORE writing starts).
    public var metadataProvider: (@Sendable () -> [AVMetadataItem])?

    public init(url: URL, fps: Int = 6) {
        self.url = url
        // Playback cadence for the timelapse. 1fps capture × 6fps playback ≈ a
        // 5-minute run compressed to ~50s — watchable confirmation.
        self.fps = Int32(max(1, min(60, fps)))
    }

    /// Append one captured frame (JPEG/PNG bytes from the ring). Lazily starts
    /// the writer on the first frame using that frame's dimensions.
    public func append(imageData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let image = Self.decode(imageData) else { return }
        if writer == nil {
            start(width: image.width, height: image.height)
        }
        guard let input, let adaptor, let pool = adaptor.pixelBufferPool else { return }
        // At ~1fps the input is effectively always ready; skip a frame rather
        // than block if the encoder momentarily isn't.
        guard input.isReadyForMoreMediaData else { return }
        guard let buffer = Self.pixelBuffer(from: image, pool: pool, width: width, height: height) else { return }
        adaptor.append(buffer, withPresentationTime: CMTime(value: frameCount, timescale: fps))
        frameCount += 1
    }

    /// Finalize the movie (metadata was stamped at start via metadataProvider).
    /// Returns the file path if a non-empty video was written, else nil. Safe to
    /// call more than once.
    @discardableResult
    public func finish() async -> String? {
        lock.lock()
        if finished {
            let hadFrames = frameCount > 0
            lock.unlock()
            return hadFrames ? url.path : nil
        }
        finished = true
        guard let writer, let input, frameCount > 0 else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url.path : nil
    }

    /// Build an mp4 metadata item for a common key (title/description/etc).
    public static func item(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataItem.identifier(forKey: key.rawValue, keySpace: .common)
        item.keySpace = .common
        item.key = key.rawValue as NSString
        item.value = value as NSString
        return item
    }

    /// Build a custom user-data metadata item (queryable custom fields).
    public static func userItem(_ key: String, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeUserData
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    // MARK: - Private

    private func start(width: Int, height: Int) {
        // H.264 requires even dimensions.
        self.width = width - (width % 2)
        self.height = height - (height % 2)
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
        ]
        let adapt = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: attrs)
        guard w.canAdd(inp) else { return }
        w.add(inp)
        // Metadata MUST be set before writing starts.
        if let items = metadataProvider?(), !items.isEmpty { w.metadata = items }
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        self.writer = w
        self.input = inp
        self.adaptor = adapt
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool,
                                    width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
