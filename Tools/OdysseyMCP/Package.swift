// swift-tools-version: 6.0
import PackageDescription

// Claude's MCP server for Odyssey Finance (docs/decisions.md D13). Reads the snapshot the
// app writes to its iCloud Drive container and answers with the app's own CoreLogic.
let package = Package(
    name: "OdysseyMCP",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "OdysseyMCP", targets: ["OdysseyMCP"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
        // Pre-1.0: minor versions may break the API.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
    ],
    targets: [
        .target(
            name: "OdysseyMCPCore",
            dependencies: [
                .product(name: "CoreBridge", package: "Core"),
                .product(name: "CoreLogic", package: "Core"),
                .product(name: "CoreModel", package: "Core"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "OdysseyMCP", dependencies: ["OdysseyMCPCore"]),
        // Depends on the executable so the stdio test can launch the built server.
        .testTarget(
            name: "OdysseyMCPCoreTests",
            dependencies: [
                "OdysseyMCPCore", "OdysseyMCP",
                .product(name: "CoreBridge", package: "Core"),
                .product(name: "CoreLogic", package: "Core"),
                .product(name: "CoreModel", package: "Core"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
