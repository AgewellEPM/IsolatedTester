import os
import Foundation

/// Centralized logging for IsolatedTester using os.Logger + stderr console output.
public enum ISTLogger {
    private static let subsystem = "com.isolatedtester"

    public static let agent = Logger(subsystem: subsystem, category: "agent")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let input = Logger(subsystem: subsystem, category: "input")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let launcher = Logger(subsystem: subsystem, category: "launcher")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let server = Logger(subsystem: subsystem, category: "server")

    public enum Verbosity: Int, Comparable, Sendable {
        case quiet = 0
        case normal = 1
        case verbose = 2

        public static func < (lhs: Verbosity, rhs: Verbosity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Current verbosity for CLI console output. Thread-safe via nonisolated(unsafe).
    nonisolated(unsafe) public static var verbosity: Verbosity = .normal

    /// Print to stderr for CLI use (doesn't pollute stdout which may be used for JSON/MCP).
    /// Respects the current verbosity level — messages below the threshold are suppressed.
    public static func console(_ message: String, level: Verbosity = .normal) {
        guard level <= verbosity else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Log a debug message to stderr (only shown with --verbose).
    public static func debug(_ message: String) {
        console(message, level: .verbose)
    }

    /// Log an info message to stderr (shown by default, suppressed with --quiet).
    public static func info(_ message: String) {
        console(message, level: .normal)
    }

    /// Log an error message to stderr (always shown, even with --quiet).
    /// Uses .quiet level so it's never filtered out.
    public static func error(_ message: String) {
        // Errors always print regardless of verbosity
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
