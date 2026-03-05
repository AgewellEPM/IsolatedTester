import XCTest
@testable import IsolatedTesterKit

final class CircuitBreakerTests: XCTestCase {

    func testStartsClosed() async {
        let cb = CircuitBreaker(name: "test", threshold: 3, resetTimeout: 1)
        let state = await cb.currentState
        XCTAssertEqual(state, .closed)
    }

    func testSuccessKeepsClosed() async throws {
        let cb = CircuitBreaker(name: "test", threshold: 3, resetTimeout: 1)
        let result = try await cb.execute { return 42 }
        XCTAssertEqual(result, 42)
        let state = await cb.currentState
        XCTAssertEqual(state, .closed)
    }

    func testOpensAfterThresholdFailures() async {
        let cb = CircuitBreaker(name: "test", threshold: 3, resetTimeout: 60)

        for _ in 0..<3 {
            _ = try? await cb.execute { throw NSError(domain: "test", code: 1) }
        }

        let state = await cb.currentState
        XCTAssertEqual(state, .open)
    }

    func testOpenCircuitRejectsRequests() async {
        let cb = CircuitBreaker(name: "test", threshold: 2, resetTimeout: 60)

        // Open the circuit
        for _ in 0..<2 {
            _ = try? await cb.execute { throw NSError(domain: "test", code: 1) }
        }

        // Subsequent requests should be rejected immediately
        do {
            _ = try await cb.execute { return "should not reach" }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Circuit breaker"))
        }
    }

    func testSuccessResetsClosed() async throws {
        let cb = CircuitBreaker(name: "test", threshold: 3, resetTimeout: 0.1)

        // Partial failures (not enough to open)
        _ = try? await cb.execute { throw NSError(domain: "test", code: 1) }
        _ = try? await cb.execute { throw NSError(domain: "test", code: 1) }

        // Success resets
        let result = try await cb.execute { return "ok" }
        XCTAssertEqual(result, "ok")

        let state = await cb.currentState
        XCTAssertEqual(state, .closed)
    }

    func testHalfOpenRecovery() async throws {
        let cb = CircuitBreaker(name: "test", threshold: 2, resetTimeout: 0.1)

        // Open the circuit
        for _ in 0..<2 {
            _ = try? await cb.execute { throw NSError(domain: "test", code: 1) }
        }

        // Wait for reset timeout
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        // Next request should go through (half-open)
        let result = try await cb.execute { return "recovered" }
        XCTAssertEqual(result, "recovered")

        let state = await cb.currentState
        XCTAssertEqual(state, .closed)
    }
}
