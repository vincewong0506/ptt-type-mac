// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PTTMacVoiceApp",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "PTTMacVoiceApp", targets: ["PTTMacVoiceApp"]),
        .library(name: "PTTMacVoiceCore", targets: ["PTTMacVoiceCore"])
    ],
    dependencies: [
        // Pinned to a specific revision (rather than `branch: "main"`) so a
        // checkout of this repo always builds against the same speech-swift
        // we test against. Bump deliberately when picking up upstream
        // changes; never silently retrack `main`.
        .package(url: "https://github.com/soniqo/speech-swift", revision: "e5f766987890a9ba91de1e47057295cf7ec50f18")
    ],
    targets: [
        .target(
            name: "LTSBCDecoder",
            path: "Sources/LTSBCDecoder",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("oi/include"),
                .headerSearchPath("shim")
            ]
        ),
        .target(
            name: "PTTMacVoiceCore",
            dependencies: [
                "LTSBCDecoder",
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift")
            ],
            path: "Sources/PTTMacVoiceCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PTTMacVoiceApp",
            dependencies: ["PTTMacVoiceCore"],
            path: "Sources/PTTMacVoiceApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
