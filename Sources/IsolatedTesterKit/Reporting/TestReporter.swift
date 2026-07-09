import Foundation

/// Orchestrates saving test reports in multiple formats.
public struct TestReporter: Sendable {
    public let outputDir: URL
    public let formatters: [any ReportFormatter]
    public let saveScreenshots: Bool
    public let screenshotDir: URL

    public init(
        outputDir: URL = URL(fileURLWithPath: "./reports/"),
        formatters: [any ReportFormatter] = [JSONReportFormatter(), JUnitFormatter()],
        saveScreenshots: Bool = false,
        screenshotDir: URL = URL(fileURLWithPath: "./screenshots/")
    ) {
        self.outputDir = outputDir
        self.formatters = formatters
        self.saveScreenshots = saveScreenshots
        self.screenshotDir = screenshotDir
    }

    /// Save a test report in all configured formats. Returns paths to saved files.
    public func save(report: TestReportData) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var savedFiles: [URL] = []

        for formatter in formatters {
            let data = try formatter.format(report: report)
            let filename = "report-\(report.sessionId).\(formatter.fileExtension)"
            let fileURL = outputDir.appendingPathComponent(filename)
            try data.write(to: fileURL)
            savedFiles.append(fileURL)
        }

        // Save screenshots if requested
        if saveScreenshots, !report.screenshots.isEmpty {
            try fm.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
            for (index, screenshotData) in report.screenshots {
                let ext = report.screenshotFormat
                let filename = "\(report.sessionId)-step\(index).\(ext)"
                let fileURL = screenshotDir.appendingPathComponent(filename)
                try screenshotData.write(to: fileURL)
                savedFiles.append(fileURL)
            }
        }

        return savedFiles
    }

    /// Create a reporter from a Configuration's output settings.
    public static func fromConfig(_ config: OutputConfiguration) -> TestReporter {
        var formatters: [any ReportFormatter] = []
        switch config.format.lowercased() {
        case "junit": formatters = [JUnitFormatter()]
        case "both": formatters = [JSONReportFormatter(), JUnitFormatter()]
        default: formatters = [JSONReportFormatter()]
        }

        return TestReporter(
            outputDir: URL(fileURLWithPath: config.path),
            formatters: formatters,
            saveScreenshots: config.saveScreenshots,
            screenshotDir: URL(fileURLWithPath: config.screenshotDir)
        )
    }
}

/// Configuration subset for output settings. Matches Configuration.OutputConfig fields.
public struct OutputConfiguration: Sendable {
    public let format: String
    public let path: String
    public let saveScreenshots: Bool
    public let screenshotDir: String

    public init(format: String = "json", path: String = "./reports/",
                saveScreenshots: Bool = false, screenshotDir: String = "./screenshots/") {
        self.format = format
        self.path = path
        self.saveScreenshots = saveScreenshots
        self.screenshotDir = screenshotDir
    }
}

/// Data structure for report generation. Maps from AITestAgent.TestReport.
public struct TestReportData: Sendable, Codable {
    public let sessionId: String
    public let objective: String
    public let success: Bool
    public let summary: String
    public let stepCount: Int
    public let duration: TimeInterval
    public let steps: [StepData]
    public let appPath: String?
    public let provider: String?
    public let model: String?
    public let startedAt: Date
    public let completedAt: Date
    public let screenshotFormat: String
    // Not Codable - stored separately
    public var screenshots: [(Int, Data)] = []

    public struct StepData: Sendable, Codable {
        public let step: Int
        public let action: String
        public let reasoning: String
        public let timestamp: Date?

        public init(step: Int, action: String, reasoning: String, timestamp: Date? = nil) {
            self.step = step
            self.action = action
            self.reasoning = reasoning
            self.timestamp = timestamp
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, objective, success, summary, stepCount, duration
        case steps, appPath, provider, model, startedAt, completedAt, screenshotFormat
    }

    public init(
        sessionId: String, objective: String, success: Bool, summary: String,
        stepCount: Int, duration: TimeInterval, steps: [StepData],
        appPath: String? = nil, provider: String? = nil, model: String? = nil,
        startedAt: Date = Date(), completedAt: Date = Date(),
        screenshotFormat: String = "jpeg", screenshots: [(Int, Data)] = []
    ) {
        self.sessionId = sessionId
        self.objective = objective
        self.success = success
        self.summary = summary
        self.stepCount = stepCount
        self.duration = duration
        self.steps = steps
        self.appPath = appPath
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.screenshotFormat = screenshotFormat
        self.screenshots = screenshots
    }
}

/// Protocol for report formatters.
public protocol ReportFormatter: Sendable {
    func format(report: TestReportData) throws -> Data
    var fileExtension: String { get }
}

/// JSON report formatter with pretty printing.
public struct JSONReportFormatter: ReportFormatter, Sendable {
    public init() {}

    public func format(report: TestReportData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public var fileExtension: String { "json" }
}
