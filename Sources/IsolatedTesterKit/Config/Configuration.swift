import Foundation

/// Complete configuration for IsolatedTester, loadable from YAML config files.
/// CLI flags override config file values.
public struct Configuration: Codable, Sendable {
    public var provider: String
    public var model: String?
    public var apiKey: String?
    public var maxSteps: Int
    public var actionDelay: Double
    public var screenshotFormat: String

    public var display: DisplayConfig
    public var retry: RetryConfig
    public var timeouts: TimeoutConfig
    public var output: OutputConfig
    public var logging: LoggingConfig

    public struct DisplayConfig: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var ppi: Int
        public var useVirtual: Bool
        public var fallbackToMain: Bool

        public init(width: Int = 1920, height: Int = 1080, ppi: Int = 144,
                     useVirtual: Bool = true, fallbackToMain: Bool = true) {
            self.width = width
            self.height = height
            self.ppi = ppi
            self.useVirtual = useVirtual
            self.fallbackToMain = fallbackToMain
        }
    }

    public struct RetryConfig: Codable, Sendable {
        public var maxRetries: Int
        public var retryDelay: Double
        public var screenshotRetries: Int
        public var backoffMultiplier: Double
        public var maxDelay: Double

        public init(maxRetries: Int = 3, retryDelay: Double = 1.0,
                     screenshotRetries: Int = 3, backoffMultiplier: Double = 2.0,
                     maxDelay: Double = 30.0) {
            self.maxRetries = maxRetries
            self.retryDelay = retryDelay
            self.screenshotRetries = screenshotRetries
            self.backoffMultiplier = backoffMultiplier
            self.maxDelay = maxDelay
        }
    }

    public struct TimeoutConfig: Codable, Sendable {
        public var apiCall: Double
        public var appLaunch: Double
        public var sessionTotal: Double

        public init(apiCall: Double = 60, appLaunch: Double = 10, sessionTotal: Double = 600) {
            self.apiCall = apiCall
            self.appLaunch = appLaunch
            self.sessionTotal = sessionTotal
        }
    }

    public struct OutputConfig: Codable, Sendable {
        public var format: String  // "json", "junit", "both"
        public var path: String
        public var saveScreenshots: Bool
        public var screenshotDir: String

        public init(format: String = "json", path: String = "./reports/",
                     saveScreenshots: Bool = false, screenshotDir: String = "./screenshots/") {
            self.format = format
            self.path = path
            self.saveScreenshots = saveScreenshots
            self.screenshotDir = screenshotDir
        }
    }

    public struct LoggingConfig: Codable, Sendable {
        public var level: String  // "debug", "info", "warning", "error"

        public init(level: String = "info") {
            self.level = level
        }
    }

    public init(
        provider: String = "anthropic",
        model: String? = nil,
        apiKey: String? = nil,
        maxSteps: Int = 25,
        actionDelay: Double = 0.5,
        screenshotFormat: String = "jpeg",
        display: DisplayConfig = .init(),
        retry: RetryConfig = .init(),
        timeouts: TimeoutConfig = .init(),
        output: OutputConfig = .init(),
        logging: LoggingConfig = .init()
    ) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.maxSteps = maxSteps
        self.actionDelay = actionDelay
        self.screenshotFormat = screenshotFormat
        self.display = display
        self.retry = retry
        self.timeouts = timeouts
        self.output = output
        self.logging = logging
    }

    public static let `default` = Configuration()

    /// Validate configuration values are within acceptable bounds.
    /// Call this at startup to catch misconfigurations early.
    public func validate() throws {
        let validProviders = ["anthropic", "openai", "claude-code", "claudecode"]
        guard validProviders.contains(provider.lowercased()) else {
            throw ConfigError.parseError("Unknown provider '\(provider)'. Valid: \(validProviders.joined(separator: ", "))")
        }
        guard maxSteps >= 1 && maxSteps <= 500 else {
            throw ConfigError.parseError("maxSteps must be 1-500, got \(maxSteps)")
        }
        guard actionDelay >= 0 && actionDelay <= 30 else {
            throw ConfigError.parseError("actionDelay must be 0-30, got \(actionDelay)")
        }
        let validFormats = ["png", "jpeg"]
        guard validFormats.contains(screenshotFormat.lowercased()) else {
            throw ConfigError.parseError("screenshotFormat must be png or jpeg, got '\(screenshotFormat)'")
        }
        guard display.width >= 320 && display.width <= 7680 else {
            throw ConfigError.parseError("display.width must be 320-7680, got \(display.width)")
        }
        guard display.height >= 320 && display.height <= 7680 else {
            throw ConfigError.parseError("display.height must be 320-7680, got \(display.height)")
        }
        guard display.ppi >= 72 && display.ppi <= 600 else {
            throw ConfigError.parseError("display.ppi must be 72-600, got \(display.ppi)")
        }
        guard retry.maxRetries >= 0 && retry.maxRetries <= 100 else {
            throw ConfigError.parseError("retry.maxRetries must be 0-100, got \(retry.maxRetries)")
        }
        guard retry.retryDelay >= 0 && retry.retryDelay <= 60 else {
            throw ConfigError.parseError("retry.retryDelay must be 0-60, got \(retry.retryDelay)")
        }
        guard timeouts.apiCall >= 1 && timeouts.apiCall <= 600 else {
            throw ConfigError.parseError("timeouts.apiCall must be 1-600, got \(timeouts.apiCall)")
        }
        guard timeouts.appLaunch >= 1 && timeouts.appLaunch <= 120 else {
            throw ConfigError.parseError("timeouts.appLaunch must be 1-120, got \(timeouts.appLaunch)")
        }
        guard timeouts.sessionTotal >= 10 && timeouts.sessionTotal <= 86400 else {
            throw ConfigError.parseError("timeouts.sessionTotal must be 10-86400, got \(timeouts.sessionTotal)")
        }
    }

    /// Merge CLI overrides on top of config file values. Non-nil CLI values win.
    public func merging(
        provider: String? = nil,
        model: String? = nil,
        apiKey: String? = nil,
        maxSteps: Int? = nil,
        actionDelay: Double? = nil,
        screenshotFormat: String? = nil,
        outputFormat: String? = nil,
        verbose: Bool = false,
        quiet: Bool = false
    ) -> Configuration {
        var merged = self
        if let p = provider { merged.provider = p }
        if let m = model { merged.model = m }
        if let k = apiKey { merged.apiKey = k }
        if let s = maxSteps { merged.maxSteps = s }
        if let d = actionDelay { merged.actionDelay = d }
        if let f = screenshotFormat { merged.screenshotFormat = f }
        if let o = outputFormat { merged.output.format = o }
        if verbose { merged.logging.level = "debug" }
        if quiet { merged.logging.level = "error" }
        return merged
    }
}
