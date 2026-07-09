import XCTest
@testable import IsolatedTesterKit

final class RetryPolicyTests: XCTestCase {

    func testDefaultRetryPolicy() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.initialDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 30.0)
        XCTAssertEqual(policy.backoffMultiplier, 2.0)
    }

    func testCustomRetryPolicy() {
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: 0.5, backoffMultiplier: 3.0, maxDelay: 10.0)
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.initialDelay, 0.5)
        XCTAssertEqual(policy.maxDelay, 10.0)
        XCTAssertEqual(policy.backoffMultiplier, 3.0)
    }

    func testDelayCalculation() {
        let policy = RetryPolicy(maxAttempts: 5, initialDelay: 1.0, backoffMultiplier: 2.0, maxDelay: 30.0)
        // Attempt 0: 1.0 * 2^0 = 1.0s
        XCTAssertEqual(policy.delay(for: 0), 1.0, accuracy: 0.01)
        // Attempt 1: 1.0 * 2^1 = 2.0s
        XCTAssertEqual(policy.delay(for: 1), 2.0, accuracy: 0.01)
        // Attempt 2: 1.0 * 2^2 = 4.0s
        XCTAssertEqual(policy.delay(for: 2), 4.0, accuracy: 0.01)
        // Attempt 3: 1.0 * 2^3 = 8.0s
        XCTAssertEqual(policy.delay(for: 3), 8.0, accuracy: 0.01)
    }

    func testDelayClampedToMax() {
        let policy = RetryPolicy(maxAttempts: 10, initialDelay: 1.0, backoffMultiplier: 10.0, maxDelay: 5.0)
        // Attempt 1: min(10.0, 5.0) = 5.0
        XCTAssertEqual(policy.delay(for: 1), 5.0, accuracy: 0.01)
        // Attempt 5: should still be clamped
        XCTAssertEqual(policy.delay(for: 5), 5.0, accuracy: 0.01)
    }

    func testAggressivePolicy() {
        let policy = RetryPolicy.aggressive
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.initialDelay, 0.5)
    }

    func testConservativePolicy() {
        let policy = RetryPolicy.conservative
        XCTAssertEqual(policy.maxAttempts, 2)
        XCTAssertEqual(policy.initialDelay, 2.0)
    }

    func testRetryErrorDescriptions() {
        let exhausted = RetryError.exhausted(3)
        XCTAssertTrue(exhausted.localizedDescription.contains("3"))

        let rateLimited = RetryError.rateLimited(retryAfter: 30)
        XCTAssertTrue(rateLimited.localizedDescription.contains("30"))

        let serverError = RetryError.serverError(503)
        XCTAssertTrue(serverError.localizedDescription.contains("503"))
    }

    func testExecuteSucceedsOnFirstTry() async throws {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 0.01)
        var attempts = 0
        let result = try await policy.execute {
            attempts += 1
            return "success"
        }
        XCTAssertEqual(result, "success")
        XCTAssertEqual(attempts, 1)
    }

    func testExecuteRetriesOnFailure() async throws {
        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 0.01)
        var attempts = 0
        let result = try await policy.execute {
            attempts += 1
            if attempts < 3 {
                throw NSError(domain: "test", code: 1)
            }
            return "success on third try"
        }
        XCTAssertEqual(result, "success on third try")
        XCTAssertEqual(attempts, 3)
    }

    func testExecuteExhaustsRetries() async {
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: 0.01)
        do {
            _ = try await policy.execute {
                throw NSError(domain: "test", code: 1)
            }
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }
}
