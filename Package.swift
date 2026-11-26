// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ghost",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Ghost",
            path: "Sources/Ghost",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
