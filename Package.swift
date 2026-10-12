// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowClone",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Whisper on CoreML / Apple Neural Engine (multilingual, on-device).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        // NVIDIA Parakeet TDT on CoreML / Apple Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        // Pure logic (no system permissions needed) so it can be unit tested.
        .target(
            name: "FlowCore",
            path: "Sources/FlowCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FlowClone",
            dependencies: ["FlowCore", .product(name: "WhisperKit", package: "WhisperKit"),
                           .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/FlowClone",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlowCloneTests",
            dependencies: ["FlowCore"],
            path: "Tests/FlowCloneTests"
        ),
    ]
)
