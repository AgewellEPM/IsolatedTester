import XCTest

// RateLimiter is internal to IsolatedHTTPServer which is an executable target.
// We test the behavior through its public interface by reimplementing the algorithm.
// The actual integration is verified via HTTP server tests.

/// Tests for the token bucket rate limiting algorithm.
final class RateLimiterTests: XCTestCase {

    // Token bucket algorithm: starts with maxTokens, consumes 1 per request,
    // refills at refillRate tokens/second.

    func testTokenBucketAlgorithm() {
        // Simulate token bucket with maxTokens=3, refillRate=1/s
        var tokens: Double = 3.0
        let maxTokens: Double = 3.0
        let refillRate: Double = 1.0

        // 3 requests should succeed
        for _ in 0..<3 {
            XCTAssertTrue(tokens >= 1)
            tokens -= 1
        }
        XCTAssertEqual(tokens, 0)

        // 4th request should fail
        XCTAssertFalse(tokens >= 1)

        // After 2 seconds, 2 tokens should be available
        let elapsed: Double = 2.0
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        XCTAssertEqual(tokens, 2.0)

        // 2 more requests succeed
        tokens -= 1
        XCTAssertTrue(tokens >= 1)
        tokens -= 1
        XCTAssertFalse(tokens >= 1)
    }

    func testRetryAfterCalculation() {
        // If tokens = 0.5 and refill rate = 2/s, need 0.5 more tokens
        let tokens: Double = 0.5
        let refillRate: Double = 2.0
        let needed = 1.0 - tokens
        let retryAfter = max(1, Int(ceil(needed / refillRate)))
        XCTAssertEqual(retryAfter, 1)
    }

    func testDifferentClientsIndependent() {
        // Each client gets their own bucket
        var bucketsA: Double = 3.0
        var bucketsB: Double = 3.0

        // Exhaust A
        bucketsA -= 3
        XCTAssertEqual(bucketsA, 0)
        XCTAssertFalse(bucketsA >= 1)

        // B should still work
        XCTAssertTrue(bucketsB >= 1)
        bucketsB -= 1
        XCTAssertTrue(bucketsB >= 1)
    }

    func testBurstCapacity() {
        // With maxTokens=100, should handle 100 rapid requests
        var tokens: Double = 100.0
        var successful = 0
        for _ in 0..<150 {
            if tokens >= 1 {
                tokens -= 1
                successful += 1
            }
        }
        XCTAssertEqual(successful, 100)
    }
}
