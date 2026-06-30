// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CBar", targets: ["ClaudeBar"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBar",
            path: "Sources/ClaudeBar",
            swiftSettings: [
                // Keep Swift 5 concurrency semantics — this is a tiny single-actor UI app
                // and strict Swift 6 concurrency buys us nothing but friction here.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ClaudeBarTests",
            dependencies: ["ClaudeBar"],
            path: "Tests/ClaudeBarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
