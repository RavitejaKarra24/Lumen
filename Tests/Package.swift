// swift-tools-version: 6.2
import PackageDescription

// Keep the CLT-compatible executable harness outside the app's build graph:
// @testable imports need a debug dependency, not a production LumenKit build.
// Run with: swift run --package-path Tests LumenTests
let package = Package(
    name: "LumenRegressionTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Lumen", path: "..")],
    targets: [
        .executableTarget(
            name: "LumenTests",
            dependencies: [.product(name: "LumenKit", package: "Lumen")],
            path: "LumenTests"
        )
    ]
)
