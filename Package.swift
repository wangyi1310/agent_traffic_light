// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTrafficLight",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CodexTrafficLightCore", targets: ["CodexTrafficLightCore"]),
        .executable(
            name: "CodexTrafficLightCoreTests",
            targets: ["CodexTrafficLightCoreTests"]
        ),
    ],
    targets: [
        .target(name: "CodexTrafficLightCore"),
        .executableTarget(
            name: "CodexTrafficLightCoreTests",
            dependencies: ["CodexTrafficLightCore"],
            path: "Tests/CodexTrafficLightCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
