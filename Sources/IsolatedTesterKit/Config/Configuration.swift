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
