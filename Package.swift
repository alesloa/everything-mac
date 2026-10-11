// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Wire in the test target when regression tests are present. Source distributions
// without Tests/IndexCoreTests still build the library without a test target.
var targets: [Target] = [
    .target(name: "IndexCore"),
    .executableTarget(name: "EverythingCLI", dependencies: ["IndexCore"]),
]
if FileManager.default.fileExists(atPath: "Tests/IndexCoreTests") {
    targets.append(.testTarget(name: "IndexCoreTests", dependencies: ["IndexCore"]))
}
// Keep source-only distributions usable without the process-fixture test suite.
if FileManager.default.fileExists(atPath: "Tests/EverythingCLITests") {
    targets.append(.testTarget(name: "EverythingCLITests", dependencies: ["IndexCore", "EverythingCLI"]))
}

let package = Package(
    name: "IndexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndexCore", targets: ["IndexCore"]),
        .executable(name: "everything", targets: ["EverythingCLI"]),
    ],
    targets: targets
)
