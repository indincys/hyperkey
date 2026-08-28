// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hyper",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "HyperKeyBrokerSupport",
            path: "Sources/HyperKeyBrokerSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HyperKeyBroker",
            dependencies: ["HyperKeyBrokerSupport"],
            path: "Sources/HyperKeyBroker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Hyper",
            dependencies: ["HyperKeyBrokerSupport"],
            path: "Sources/Hyper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HyperTests",
            dependencies: ["Hyper", "HyperKeyBrokerSupport"],
            path: "Tests/HyperTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
