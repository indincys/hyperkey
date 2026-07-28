// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hyper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Hyper",
            path: "Sources/Hyper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
