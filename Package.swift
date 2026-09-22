// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChatCapture",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ChatCapture", targets: ["ChatCapture"]),
        .library(name: "JudgeClient", targets: ["JudgeClient"]),
    ],
    targets: [
        // Capture stage: screenshot line boxes -> ordered chat transcript.
        .target(name: "ChatCapture", path: "Sources/ChatCapture"),
        // Decision stage: configurable routes, typed judgments, drafting and ranking.
        .target(name: "JudgeClient", path: "Sources/JudgeClient"),
        // Measurement harness: Apple's recogniser over a folder of screenshots, on a macOS runner.
        .executableTarget(name: "visionlines", path: "Sources/visionlines"),
        .testTarget(
            name: "ChatCaptureTests",
            dependencies: ["ChatCapture"],
            path: "Tests/ChatCaptureTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "JudgeClientTests",
            dependencies: ["JudgeClient"],
            path: "Tests/JudgeClientTests"
        ),
    ]
)