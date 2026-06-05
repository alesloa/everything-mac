// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The test target is wired in only when the Tests directory is present. Tests
// aren't part of the published sources, so a fresh clone builds without them;
// drop the Tests/IndexCoreTests folder back in and `swift test` picks it up.
var targets: [Target] = [
    .target(name: "IndexCore"),
]
if FileManager.default.fileExists(atPath: "Tests/IndexCoreTests") {
    targets.append(.testTarget(name: "IndexCoreTests", dependencies: ["IndexCore"]))
}

let package = Package(
    name: "IndexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IndexCore", targets: ["IndexCore"]),
    ],
    targets: targets
)
