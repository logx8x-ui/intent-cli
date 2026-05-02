// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Intent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Intent", targets: ["Intent"]),
        .executable(name: "IntentCoreSpec", targets: ["IntentCoreSpec"]),
        .library(name: "IntentCore", targets: ["IntentCore"])
    ],
    targets: [
        .target(name: "IntentCore"),
        .executableTarget(
            name: "Intent",
            dependencies: ["IntentCore"]
        ),
        .executableTarget(
            name: "IntentCoreSpec",
            dependencies: ["IntentCore"]
        )
    ]
)
