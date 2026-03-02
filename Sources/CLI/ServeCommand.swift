import ArgumentParser
import Foundation
import IsolatedTesterKit

/// The `isolated serve` subcommand starts the editor integration server.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the editor integration server (MCP or HTTP)"
    )

    @Option(name: .long, help: "HTTP port (default: 7100)")
    var port: Int = 7100

    @Flag(name: .long, help: "Run as MCP server on stdio (for AI editors)")
    var mcp: Bool = false

    @Option(name: .long, help: "Bearer token for HTTP auth (optional)")
    var token: String?

    func run() async throws {
        if mcp {
            // MCP mode: run the MCP server binary
            // In practice, editors spawn `isolated-mcp` directly,
            // but this provides a convenience wrapper
            FileHandle.standardError.write(Data("Starting MCP server on stdio...\n".utf8))
            FileHandle.standardError.write(Data("Configure your editor to use: isolated serve --mcp\n".utf8))

            // Import and run MCP transport inline
            // For now, delegate to the isolated-mcp binary
            // Use URL to replace only the last path component (binary name), not the
            // entire path string, so directory names containing "isolated" are untouched.
            let selfURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            let mcpBinary = selfURL.lastPathComponent
                .replacingOccurrences(of: "isolated", with: "isolated-mcp")
            let mcpPath = selfURL.deletingLastPathComponent()
                .appendingPathComponent(mcpBinary).path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: mcpPath)
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                FileHandle.standardError.write(Data("MCP binary not found at \(mcpPath). Build with: swift build\n".utf8))
                FileHandle.standardError.write(Data("Or run directly: isolated-mcp\n".utf8))
            }
        } else {
            // HTTP mode
            FileHandle.standardError.write(Data("Starting HTTP server on http://127.0.0.1:\(port)\n".utf8))
            FileHandle.standardError.write(Data("Press Ctrl+C to stop\n".utf8))

            // Delegate to the isolated-http binary
            // Same fix: replace only the filename component, not the full path string.
            let selfURLForHTTP = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            let httpBinary = selfURLForHTTP.lastPathComponent
                .replacingOccurrences(of: "isolated", with: "isolated-http")
            let httpPath = selfURLForHTTP.deletingLastPathComponent()
                .appendingPathComponent(httpBinary).path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: httpPath)
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            var env = ProcessInfo.processInfo.environment
            env["IST_PORT"] = "\(port)"
            if let token = token { env["IST_TOKEN"] = token }
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                FileHandle.standardError.write(Data("HTTP server binary not found at \(httpPath). Build with: swift build\n".utf8))
                FileHandle.standardError.write(Data("Or run directly: IST_PORT=\(port) isolated-http\n".utf8))
            }
        }
    }
}
