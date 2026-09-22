// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChatCapture",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ChatCapture", targets: ["ChatCapture"])
    ],
    targets: [
        // The capture stage: screenshot line boxes -> ordered chat transcript.
        .target(name: "ChatCapture", path: "Sources/ChatCapture"),
        // Measurement harness: runs Apple's recogniser over a folder of screenshots on a macOS
        // runner so the rules can be validated without owning a Mac.
        .executableTarget(name: "visionlines", path: "Sources/visionlines"),
        .testTarget(
            name: "ChatCaptureTests",
            dependencies: ["ChatCapture"],
            path: "Tests/ChatCaptureTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)