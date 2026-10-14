import Foundation

enum CaptureDeadlineError: Error, LocalizedError {
    case timedOut(String, TimeInterval)
    var errorDescription: String? {
        switch self {
        case let .timedOut(operation, seconds):
            return "\(operation) timed out after \(seconds)s; verify capture permission and the target window."
        }
    }
}

/// Bounds a callback API even when it never calls back or observes cancellation.
/// A task-group race cannot do this: leaving the group waits for every child.
final class CaptureDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var timer: DispatchWorkItem?
    private let operationName: String

    private init(operationName: String) { self.operationName = operationName }

    static func wait(
        seconds: TimeInterval = 10,
        operationName: String = "ScreenCaptureKit",
        operation: (@escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let deadline = CaptureDeadline<Value>(operationName: operationName)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if deadline.start(continuation, seconds: seconds) {
                    operation { deadline.complete($0) }
                }
            }
        } onCancel: {
            deadline.complete(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<Value, Error>, seconds: TimeInterval) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return false
        }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in
            self?.complete(.failure(CaptureDeadlineError.timedOut(self?.operationName ?? "ScreenCaptureKit", seconds)))
        }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
        return true
    }

    private func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
