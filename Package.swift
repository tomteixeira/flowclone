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
        // Local LLMs (Qwen3) in-process on Apple silicon. lm minors track mlx-swift
        // minors, and the metallib built by scripts/build-app.sh must match mlx.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
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
                           .product(name: "FluidAudio", package: "FluidAudio"),
                           .product(name: "MLXLLM", package: "mlx-swift-lm"),
                           .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                           .product(name: "HuggingFace", package: "swift-huggingface"),
                           .product(name: "Tokenizers", package: "swift-transformers")],
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
