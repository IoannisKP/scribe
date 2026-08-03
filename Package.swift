// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "ModelManager", targets: ["ModelManager"]),
        .library(name: "SpeechPipeline", targets: ["SpeechPipeline"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        )
    ],
    targets: [
        .target(
            name: "CAudioRingBuffer",
            path: "Sources/CAudioRingBuffer",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AudioCapture",
            dependencies: ["CAudioRingBuffer"],
            path: "Sources/AudioCapture",
            exclude: ["AudioCapture-Bridging-Header.h"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "ModelManager",
            path: "Sources/ModelManager",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "SpeechPipeline",
            dependencies: [
                "AudioCapture",
                "ModelManager",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/SpeechPipeline",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture"],
            path: "Tests/AudioCaptureTests",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "ModelManagerTests",
            dependencies: ["ModelManager"],
            path: "Tests/ModelManagerTests",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "SpeechPipelineTests",
            dependencies: ["SpeechPipeline", "AudioCapture"],
            path: "Tests/SpeechPipelineTests",
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
