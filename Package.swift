// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "visionlines",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "visionlines", path: "Sources/visionlines")
    ]
)