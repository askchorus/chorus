// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chorus",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Chorus",
            path: "Sources/Chorus"
        )
    ],
    swiftLanguageVersions: [.v5]
)
