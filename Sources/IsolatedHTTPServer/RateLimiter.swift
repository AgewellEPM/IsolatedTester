import Foundation

/// Token bucket rate limiter for HTTP API.
/// Limits requests per client IP using a configurable token bucket algorithm.
final class RateLimiter: @unchecked Sendable {
    struct Bucket {
        var tokens: Double
        var lastRefill: Date
    }

    private var buckets: [String: Bucket] = [:]
    private let lock = NSLock()
    private let maxTokens: Double
    private let refillRate: Double  // tokens per second

    init(maxTokens: Double = 100, refillRate: Double = 10) {
        self.maxTokens = maxTokens
        self.refillRate = refillRate
    }

    /// Check if a request from the given client IP should be allowed.
    /// Returns true if allowed, false if rate limited.
    func allow(clientIP: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        if var bucket = buckets[clientIP] {
            // Refill tokens based on elapsed time
            let elapsed = now.timeIntervalSince(bucket.lastRefill)
            bucket.tokens = min(maxTokens, bucket.tokens + elapsed * refillRate)
            bucket.lastRefill = now

            if bucket.tokens >= 1 {
                bucket.tokens -= 1
                buckets[clientIP] = bucket
                return true
            } else {
                buckets[clientIP] = bucket
                return false
            }
        } else {
            // New client, start with full bucket minus 1
            buckets[clientIP] = Bucket(tokens: maxTokens - 1, lastRefill: now)
            return true
        }
    }

    /// Seconds until the next token is available for a given client.
    func retryAfter(clientIP: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard let bucket = buckets[clientIP] else { return 0 }
        if bucket.tokens >= 1 { return 0 }
        let needed = 1.0 - bucket.tokens
        return max(1, Int(ceil(needed / refillRate)))
    }

    /// Periodically clean up stale buckets to prevent memory growth.
    func cleanup(olderThan seconds: TimeInterval = 300) {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-seconds)
        buckets = buckets.filter { $0.value.lastRefill > cutoff }
    }
}
