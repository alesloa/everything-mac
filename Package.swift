// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Wire in the test target when regression tests are present. Source distributions
// without Tests/IndexCoreTests still build the library without a test target.
var targets: [Target] = [
    .target(name: "IndexCore"),
    .executableTarget(name: "EverythingCLI", dependencies: ["IndexCore"]),
    .executableTarget(name: "EverythingMCP", dependencies: [
        "IndexCore", .product(name: "MCP", package: "swift-sdk"),
    ]),
]
if FileManager.default.fileExists(atPath: "Tests/IndexCoreTests") {
    targets.append(.testTarget(name: "IndexCoreTests", dependencies: ["IndexCore"]))
}
// Keep source-only distributions usable without the process-fixture test suite.
if FileManager.default.fileExists(atPath: "Tests/EverythingCLITests") {
    targets.append(.testTarget(name: "EverythingCLITests", dependencies: ["IndexCore", "EverythingCLI"]))
}
if FileManager.default.fileExists(atPath: "Tests/EverythingMCPTests") {
    // Process tests exercise the built executable instead of linking its async
    // @main into the Swift Testing runner.
    targets.append(.testTarget(name: "EverythingMCPTests", dependencies: ["IndexCore"]))
}

let package = Package(
    name: "IndexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndexCore", targets: ["IndexCore"]),
        .executable(name: "everything", targets: ["EverythingCLI"]),
        .executable(name: "everything-mcp", targets: ["EverythingMCP"]),
    ],
    dependencies: [
        // The official SDK requires Swift 6.1; pin the protocol implementation.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: targets
)
