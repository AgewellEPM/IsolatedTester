import Foundation

/// Loads configuration from YAML or JSON files.
/// Search order: explicit path > .isolatedtester.yml in cwd > ~/.isolatedtester.yml > defaults
public struct ConfigLoader {

    public static func load(explicitPath: String? = nil) throws -> Configuration {
        // 1. Try explicit path
        if let path = explicitPath {
            return try loadFromFile(path)
        }

        // 2. Try .isolatedtester.yml in current directory
        let cwdConfig = FileManager.default.currentDirectoryPath + "/.isolatedtester.yml"
        if FileManager.default.fileExists(atPath: cwdConfig) {
            return try loadFromFile(cwdConfig)
        }

        // 3. Try .isolatedtester.json in current directory (alternative format)
        let cwdJSON = FileManager.default.currentDirectoryPath + "/.isolatedtester.json"
        if FileManager.default.fileExists(atPath: cwdJSON) {
            return try loadFromFile(cwdJSON)
        }

        // 4. Try home directory
        let homeConfig = NSHomeDirectory() + "/.isolatedtester.yml"
        if FileManager.default.fileExists(atPath: homeConfig) {
            return try loadFromFile(homeConfig)
        }

        let homeJSON = NSHomeDirectory() + "/.isolatedtester.json"
        if FileManager.default.fileExists(atPath: homeJSON) {
            return try loadFromFile(homeJSON)
        }

        // 5. Return defaults
        return .default
    }

    private static func loadFromFile(_ path: String) throws -> Configuration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        if path.hasSuffix(".json") {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Configuration.self, from: data)
        }

        // For YAML, try to parse as JSON first (YAML is a superset of JSON)
        // If Yams is available, use it; otherwise fall back to JSON-compatible YAML
        if let config = try? JSONDecoder().decode(Configuration.self, from: data) {
            return config
        }

        // Simple YAML parser for flat key-value configs
        // For full YAML support, Yams dependency is needed
        return try parseSimpleYAML(data)
    }

    /// Basic YAML parser that handles the most common config patterns.
    /// For full YAML support, use the Yams library.
    private static func parseSimpleYAML(_ data: Data) throws -> Configuration {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidFormat("Cannot read config file as UTF-8")
        }

        var config = Configuration.default
        var currentSection = ""

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Check for section header (no leading spaces, ends with colon, no value)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasSuffix(":") && !trimmed.contains(": ") {
                currentSection = String(trimmed.dropLast())
                continue
            }

            // Parse key: value
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch (currentSection, key) {
            case ("", "provider"): config.provider = value
            case ("", "model"): config.model = value
            case ("", "api_key"): config.apiKey = value
            case ("", "max_steps"): config.maxSteps = Int(value) ?? config.maxSteps
            case ("", "action_delay"): config.actionDelay = Double(value) ?? config.actionDelay
            case ("", "screenshot_format"): config.screenshotFormat = value
            case ("display", "width"): config.display.width = Int(value) ?? config.display.width
            case ("display", "height"): config.display.height = Int(value) ?? config.display.height
            case ("display", "ppi"): config.display.ppi = Int(value) ?? config.display.ppi
            case ("display", "use_virtual"): config.display.useVirtual = value == "true"
            case ("display", "fallback_to_main"): config.display.fallbackToMain = value == "true"
            case ("retry", "max_retries"): config.retry.maxRetries = Int(value) ?? config.retry.maxRetries
            case ("retry", "retry_delay"): config.retry.retryDelay = Double(value) ?? config.retry.retryDelay
            case ("retry", "screenshot_retries"): config.retry.screenshotRetries = Int(value) ?? config.retry.screenshotRetries
            case ("retry", "backoff_multiplier"): config.retry.backoffMultiplier = Double(value) ?? config.retry.backoffMultiplier
            case ("retry", "max_delay"): config.retry.maxDelay = Double(value) ?? config.retry.maxDelay
            case ("timeouts", "api_call"): config.timeouts.apiCall = Double(value) ?? config.timeouts.apiCall
            case ("timeouts", "app_launch"): config.timeouts.appLaunch = Double(value) ?? config.timeouts.appLaunch
            case ("timeouts", "session_total"): config.timeouts.sessionTotal = Double(value) ?? config.timeouts.sessionTotal
            case ("output", "format"): config.output.format = value
            case ("output", "path"): config.output.path = value
            case ("output", "save_screenshots"): config.output.saveScreenshots = value == "true"
            case ("output", "screenshot_dir"): config.output.screenshotDir = value
            case ("logging", "level"): config.logging.level = value
            default: break
            }
        }

        return config
    }
}

public enum ConfigError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidFormat(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "Config file not found: \(path)"
        case .invalidFormat(let msg): return "Invalid config format: \(msg)"
        case .parseError(let msg): return "Config parse error: \(msg)"
        }
    }
}
