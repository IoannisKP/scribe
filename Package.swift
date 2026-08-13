// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "ModelManager", targets: ["ModelManager"]),
        .library(name: "SpeechPipeline", targets: ["SpeechPipeline"]),
        .library(name: "SessionStore", targets: ["SessionStore"]),
        .library(name: "Intelligence", targets: ["Intelligence"]),
        .executable(
            name: "ProviderEndpointProbe",
            targets: ["ProviderEndpointProbe"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
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
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/SpeechPipeline",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "SessionStore",
            dependencies: [
                "AudioCapture",
                "SpeechPipeline",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SessionStore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(
            name: "Intelligence",
            path: "Sources/Intelligence",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ProviderEndpointProbe",
            dependencies: ["Intelligence"],
            path: "Sources/ProviderEndpointProbe",
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
            dependencies: ["SpeechPipeline", "AudioCapture", "ModelManager"],
            path: "Tests/SpeechPipelineTests",
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "SessionStoreTests",
            dependencies: ["SessionStore", "AudioCapture", "SpeechPipeline"],
            path: "Tests/SessionStoreTests",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "IntelligenceTests",
            dependencies: ["Intelligence"],
            path: "Tests/IntelligenceTests",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
