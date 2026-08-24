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
        .executable(name: "IntentAccountSpec", targets: ["IntentAccountSpec"]),
        .executable(name: "PurposeMatcherSpec", targets: ["PurposeMatcherSpec"]),
        .library(name: "IntentCore", targets: ["IntentCore"]),
        .library(name: "IntentLock", targets: ["IntentLock"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/supabase/supabase-swift.git",
            exact: "2.49.0"
        ),
        // Supabase 2.49 supports Swift 5.10, but its open dependency range can
        // otherwise resolve to a Swift 6-only IssueReporting release.
        .package(
            url: "https://github.com/pointfreeco/xctest-dynamic-overlay.git",
            exact: "1.7.0"
        )
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
            dependencies: [
                "IntentCore",
                "IntentLock",
                .product(name: "Supabase", package: "supabase-swift")
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "IntentNativeHost",
            dependencies: ["IntentCore"]
        ),
        .executableTarget(
            name: "IntentCoreSpec",
            dependencies: ["IntentCore", "IntentLock"]
        ),
        .executableTarget(
            name: "IntentAccountSpec",
            dependencies: [
                "IntentCore",
                .product(name: "XCTestDynamicOverlay", package: "xctest-dynamic-overlay")
            ]
        ),
        .executableTarget(
            name: "PurposeMatcherSpec",
            dependencies: ["IntentCore"]
        )
    ]
)
