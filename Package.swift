// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Lumen",
            path: "Sources/Lumen",
            resources: [
                .process("Resources"),
            ]
        )
    ]
)
