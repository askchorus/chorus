// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chorus",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Auto-update for direct (non-MAS) distribution.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Chorus",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Chorus"
        ),
        .testTarget(
            name: "ChorusTests",
            dependencies: ["Chorus"],
            path: "Tests/ChorusTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
