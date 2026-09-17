// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BigIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BigIsland",
            path: "Sources/BigIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
