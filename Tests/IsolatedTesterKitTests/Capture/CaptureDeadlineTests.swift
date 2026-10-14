import XCTest
@testable import IsolatedTesterKit

final class CaptureDeadlineTests: XCTestCase {
    private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: ((Result<Int, Error>) -> Void)?
        func store(_ callback: @escaping (Result<Int, Error>) -> Void) {
            lock.lock(); defer { lock.unlock() }
            self.callback = callback
        }
        func complete(_ result: Result<Int, Error>) {
            lock.lock(); let callback = self.callback; lock.unlock()
            callback?(result)
        }
    }

    func testMissingCallbackTimesOutAndLateCallbackIsIgnored() async {
        let callback = Callback()
        let finished = expectation(description: "deadline returns without a framework callback")
        let task = Task {
            defer { finished.fulfill() }
            return await Result { try await CaptureDeadline<Int>.wait(seconds: 0.03, operation: callback.store) }
        }
        await fulfillment(of: [finished], timeout: 2)
        // Also releases a regressed implementation after the assertion fails.
        callback.complete(.success(42))
        switch await task.value {
        case .success: XCTFail("a stalled callback must not report success")
        case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        callback.complete(.success(43)) // Must not resume the continuation twice.
    }

    func testCancellationDoesNotWaitForCallbackOrDeadline() async {
        let callback = Callback()
        let started = expectation(description: "callback registered")
        let finished = expectation(description: "cancelled capture returns")
        let task = Task {
            defer { finished.fulfill() }
            return await Result {
                try await CaptureDeadline<Int>.wait(seconds: 60) {
                    callback.store($0)
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        callback.complete(.success(42))
        switch await task.value {
        case .success: XCTFail("cancelled capture must not return a frame")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testImmediateSuccessAndFailureArePreserved() async throws {
        let value = try await CaptureDeadline<Int>.wait(seconds: 1) { $0(.success(7)) }
        XCTAssertEqual(value, 7)
        do {
            _ = try await CaptureDeadline<Int>.wait(seconds: 1) { $0(.failure(CancellationError())) }
            XCTFail("expected the original failure")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAlreadyCancelledTaskNeverStartsCapture() async {
        let gate = expectation(description: "task started")
        let callback = Callback()
        let task = Task {
            _ = await Result {
                try await CaptureDeadline<Int>.wait(seconds: 60) {
                    callback.store($0)
                    gate.fulfill()
                }
            }
            return await Result {
                try await CaptureDeadline<Int>.wait(seconds: 1) { _ in
                    XCTFail("an already cancelled task must not start another capture")
                }
            }
        }
        await fulfillment(of: [gate], timeout: 2)
        task.cancel()
        switch await task.value {
        case .success: XCTFail("expected cancellation")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        callback.complete(.success(42))
    }
}

private extension Result where Failure == Error {
    init(catching operation: () async throws -> Success) async {
        do { self = .success(try await operation()) }
        catch { self = .failure(error) }
    }
}
