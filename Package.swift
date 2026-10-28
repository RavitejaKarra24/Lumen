// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Lumen", targets: ["Lumen"]),
        .library(name: "LumenKit", targets: ["LumenKit"]),
    ],
    targets: [
        // All application code. A library target so the test harness can import
        // and exercise it directly — SwiftPM cannot link one executable against
        // another.
        .target(
            name: "LumenKit",
            path: "Sources/LumenKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "Lumen",
            dependencies: ["LumenKit"],
            path: "Sources/Lumen"
        ),
    ]
)
