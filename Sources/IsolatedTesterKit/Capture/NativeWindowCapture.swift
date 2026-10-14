import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Native window-only fallback for a stalled ScreenCaptureKit image callback.
/// Uses the same macOS screenshot utility as TinkyVision. It cannot widen the
/// target to the desktop, and missing permission remains an error.
enum NativeWindowCapture {
    static func capture(pid: pid_t) async throws -> CGImage {
        guard pid > 0, kill(pid, 0) == 0 else {
            throw DisplayError.captureFailed("Native capture target PID \(pid) is unavailable")
        }
        guard let window = InputController.largestWindow(pid: pid) else {
            throw DisplayError.captureFailed("No native window found for PID \(pid)")
        }
        return try await capture(windowID: window.id)
    }

    static func capture(windowID: CGWindowID) async throws -> CGImage {
        try Task.checkCancellation()
        guard windowID != kCGNullWindowID, CGPreflightScreenCaptureAccess() else {
            throw DisplayError.captureFailed("Native window capture requires a valid window and Screen Recording permission")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isolated-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("window.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowID), "-t", "png", imageURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let status = try await CaptureDeadline<Int32>.wait(seconds: 10, operationName: "Native window capture") { completion in
            process.terminationHandler = { completion(.success($0.terminationStatus)) }
            do { try process.run() }
            catch { completion(.failure(error)) }
        }
        try Task.checkCancellation()
        guard status == 0,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              // Decode while the private file still exists. A lazy CGImage can
              // retain its file provider past this function's cleanup.
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw DisplayError.captureFailed("Native capture failed for window \(windowID) (exit \(status)); no frame returned")
        }
        return image
    }
}
