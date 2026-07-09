// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "IsolatedTester",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "isolated", targets: ["CLI"]),
        .executable(name: "isolated-mcp", targets: ["IsolatedMCPServer"]),
        .executable(name: "isolated-http", targets: ["IsolatedHTTPServer"]),
        .library(name: "IsolatedTesterKit", targets: ["IsolatedTesterKit"]),
        .library(name: "IsolatedServerCore", targets: ["IsolatedServerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // CLI binary
        .executableTarget(
            name: "CLI",
            dependencies: [
                "IsolatedTesterKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Core testing library
        .target(
            name: "IsolatedTesterKit",
            dependencies: []
        ),
        // Server core (shared by MCP + HTTP)
        .target(
            name: "IsolatedServerCore",
            dependencies: ["IsolatedTesterKit"]
        ),
        // MCP server binary
        .executableTarget(
            name: "IsolatedMCPServer",
            dependencies: ["IsolatedServerCore", "IsolatedTesterKit"]
        ),
        // HTTP server binary
        .executableTarget(
            name: "IsolatedHTTPServer",
            dependencies: [
                "IsolatedServerCore",
                "IsolatedTesterKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        // Tests
        .testTarget(
            name: "IsolatedTesterKitTests",
            dependencies: ["IsolatedTesterKit"]
        ),
        .testTarget(
            name: "IsolatedServerCoreTests",
            dependencies: ["IsolatedServerCore", "IsolatedTesterKit"]
        ),
        .testTarget(
            name: "IsolatedHTTPServerTests",
            dependencies: [
                "IsolatedServerCore",
                "IsolatedTesterKit",
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
