import Foundation

/// Configurable retry policy with exponential backoff.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let backoffMultiplier: Double
    public let maxDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0,
        maxDelay: TimeInterval = 30.0
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.backoffMultiplier = backoffMultiplier
        self.maxDelay = maxDelay
    }

    /// Calculate delay for a given attempt number (0-indexed).
    public func delay(for attempt: Int) -> TimeInterval {
        let computed = initialDelay * pow(backoffMultiplier, Double(attempt))
        return min(computed, maxDelay)
    }

    /// Execute an async operation with retry logic.
    public func execute<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't sleep after the last attempt
                if attempt < maxAttempts - 1 {
                    let sleepDuration = delay(for: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
                }
            }
        }

        throw lastError ?? RetryError.exhausted(maxAttempts)
    }

    /// Convenience: default policy
    public static let `default` = RetryPolicy()

    /// Aggressive retry for transient failures
    public static let aggressive = RetryPolicy(maxAttempts: 5, initialDelay: 0.5, backoffMultiplier: 1.5, maxDelay: 10.0)

    /// Conservative retry for expensive operations
    public static let conservative = RetryPolicy(maxAttempts: 2, initialDelay: 2.0, backoffMultiplier: 3.0, maxDelay: 60.0)
}

public enum RetryError: Error, LocalizedError {
    case exhausted(Int)
    case rateLimited(retryAfter: TimeInterval)
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .exhausted(let attempts): return "All \(attempts) retry attempts exhausted"
        case .rateLimited(let seconds): return "Rate limited, retry after \(Int(seconds))s"
        case .serverError(let code): return "Server error: HTTP \(code)"
        }
    }
}
