import Foundation
import IsolatedTesterKit

/// Manages zero-config discovery so editors can find IsolatedTester.
/// Writes a JSON file to ~/.isolated-tester/server.json on startup.
public struct DiscoveryService {
    public static let discoveryDir = NSHomeDirectory() + "/.isolated-tester"
    public static let discoveryFile = discoveryDir + "/server.json"

    public struct ServerInfo: Codable, Sendable {
        public let version: String
        public let httpPort: Int?
        public let mcpBinaryPath: String?
        public let pid: Int32
        public let startedAt: Date

        public init(version: String = IsolatedTesterVersion.current, httpPort: Int? = nil, mcpBinaryPath: String? = nil) {
            self.version = version
            self.httpPort = httpPort
            self.mcpBinaryPath = mcpBinaryPath
            self.pid = ProcessInfo.processInfo.processIdentifier
            self.startedAt = Date()
        }
    }

    /// Write the discovery file.
    public static func advertise(info: ServerInfo) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: discoveryDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(info)
        try data.write(to: URL(fileURLWithPath: discoveryFile))
    }

    /// Remove the discovery file (on shutdown).
    public static func remove() {
        try? FileManager.default.removeItem(atPath: discoveryFile)
    }

    /// Read existing discovery info (for clients).
    public static func discover() -> ServerInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: discoveryFile)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerInfo.self, from: data)
    }
}
