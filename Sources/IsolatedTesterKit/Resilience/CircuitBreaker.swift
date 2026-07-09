import Foundation

/// Circuit breaker for AI provider API calls.
/// Prevents cascading failures when a provider is down by failing fast
/// after consecutive failures, then periodically probing for recovery.
public actor CircuitBreaker {
    public enum State: String, Sendable {
        case closed    // Normal operation, requests pass through
        case open      // Failing fast, no requests allowed
        case halfOpen  // Testing if provider has recovered
    }

    public enum CircuitBreakerError: Error, LocalizedError {
        case circuitOpen(provider: String, retryAfter: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .circuitOpen(let provider, let retryAfter):
                return "Circuit breaker open for \(provider). Retry after \(Int(retryAfter)) seconds."
            }
        }
    }

    private var state: State = .closed
    private var failureCount = 0
    private var lastFailure: Date?
    private var lastStateChange: Date = Date()
    private let threshold: Int
    private let resetTimeout: TimeInterval
    private let name: String

    public init(name: String = "default", threshold: Int = 5, resetTimeout: TimeInterval = 30) {
        self.name = name
        self.threshold = threshold
        self.resetTimeout = resetTimeout
    }

    public var currentState: State { state }

    public func execute<T>(_ operation: () async throws -> T) async throws -> T {
        // Check if circuit is open
        switch state {
        case .open:
            if shouldAttemptReset() {
                state = .halfOpen
                lastStateChange = Date()
            } else {
                let retryAfter = resetTimeout - Date().timeIntervalSince(lastFailure ?? Date())
                throw CircuitBreakerError.circuitOpen(provider: name, retryAfter: max(0, retryAfter))
            }
        case .closed, .halfOpen:
            break
        }

        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }

    private func shouldAttemptReset() -> Bool {
        guard let lastFail = lastFailure else { return true }
        return Date().timeIntervalSince(lastFail) >= resetTimeout
    }

    private func recordSuccess() {
        failureCount = 0
        if state != .closed {
            state = .closed
            lastStateChange = Date()
        }
    }

    private func recordFailure() {
        failureCount += 1
        lastFailure = Date()
        if failureCount >= threshold && state != .open {
            state = .open
            lastStateChange = Date()
            ISTLogger.error("Circuit breaker '\(name)' opened after \(failureCount) consecutive failures")
        }
    }
}
