import Foundation
import IsolatedServerCore
import IsolatedTesterKit

@main
struct IsolatedMCPServer {
    static func main() async {
        // Inventory and protocol startup require no UI permissions. Consent is
        // requested explicitly through request_permissions, never before stdin
        // is serviced (a macOS consent dialog can wait indefinitely).

        // Advertise this MCP server process so editors can discover it automatically.
        // The discovery file is removed on exit via the defer block below.
        let binaryPath = CommandLine.arguments.first
        let info = DiscoveryService.ServerInfo(
            version: IsolatedTesterVersion.current,
            httpPort: nil,
            mcpBinaryPath: binaryPath
        )
        do {
            try DiscoveryService.advertise(info: info)
        } catch {
            // Write to stderr; stdout must stay clean for the JSON-RPC stream
            FileHandle.standardError.write(
                Data("IsolatedMCPServer: discovery advertise failed: \(error)\n".utf8)
            )
        }

        // Remove the discovery file when the process exits for any reason
        defer { DiscoveryService.remove() }

        // Install SIGTERM / SIGINT handlers so the defer above fires on signal-based shutdown
        signal(SIGTERM) { _ in DiscoveryService.remove(); exit(0) }
        signal(SIGINT)  { _ in DiscoveryService.remove(); exit(0) }

        let manager = SessionManager()
        let transport = MCPTransport(sessionManager: manager)
        await transport.run()
        await manager.stopAll()
    }
}
