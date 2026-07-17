// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Intent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Intent", targets: ["Intent"]),
        .executable(name: "IntentApp", targets: ["IntentApp"]),
        .executable(name: "IntentNativeHost", targets: ["IntentNativeHost"]),
        .executable(name: "IntentCoreSpec", targets: ["IntentCoreSpec"]),
        .library(name: "IntentCore", targets: ["IntentCore"]),
        .library(name: "IntentLock", targets: ["IntentLock"])
    ],
    targets: [
        .target(name: "IntentCore"),
        .target(
            name: "IntentLock",
            dependencies: ["IntentCore"]
        ),
        .executableTarget(
            name: "Intent",
            dependencies: ["IntentCore", "IntentLock"]
        ),
        .executableTarget(
            name: "IntentApp",
            dependencies: ["IntentCore", "IntentLock"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "IntentNativeHost",
            dependencies: ["IntentCore"]
        ),
        .executableTarget(
            name: "IntentCoreSpec",
            dependencies: ["IntentCore", "IntentLock"]
        )
    ]
)
