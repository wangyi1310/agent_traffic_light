// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexTrafficLight",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CodexTrafficLightCore", targets: ["CodexTrafficLightCore"]),
        .executable(name: "CodexTrafficLightApp", targets: ["CodexTrafficLightApp"]),
        .executable(
            name: "CodexTrafficLightCoreTests",
            targets: ["CodexTrafficLightCoreTests"]
        ),
    ],
    targets: [
        .target(name: "CodexTrafficLightCore"),
        .executableTarget(
            name: "CodexTrafficLightApp",
            dependencies: ["CodexTrafficLightCore"]
        ),
        .executableTarget(
            name: "CodexTrafficLightCoreTests",
            dependencies: ["CodexTrafficLightCore"],
            path: "Tests/CodexTrafficLightCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
