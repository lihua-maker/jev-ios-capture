// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChatCapture",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "ChatCapture", targets: ["ChatCapture"]),
        .library(name: "JudgeClient", targets: ["JudgeClient"]),
        .library(name: "CopilotKit", targets: ["CopilotKit"]),
    ],
    targets: [
        // Capture stage: screenshot line boxes -> ordered chat transcript. Ships in the app.
        .target(name: "ChatCapture", path: "Sources/ChatCapture"),
        // Decision stage: configurable routes, typed judgments, drafting and ranking. Ships in the app.
        .target(name: "JudgeClient", path: "Sources/JudgeClient"),
        // App-level composition: settings + keychain + local knowledge + the analysis handoff.
        // Platform-neutral (takes a CGImage), so it is testable on a macOS runner.
        // The bundled self-test resources (a native 3x corpus render + its recorded expected output)
        // let an installed app answer "does the pipeline work on THIS device" without screenshots.
        .target(name: "CopilotKit", dependencies: ["ChatCapture", "JudgeClient"],
                path: "Sources/CopilotKit",
                resources: [.copy("Resources/selftest")]),
        // Measurement harness (macOS only): Apple's recogniser over a folder of screenshots.
        .executableTarget(name: "visionlines", dependencies: ["ChatCapture"],
                          path: "Sources/visionlines"),
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
        .testTarget(
            name: "CopilotKitTests",
            dependencies: ["CopilotKit", "JudgeClient", "ChatCapture"],
            path: "Tests/CopilotKitTests"
        ),
    ]
)