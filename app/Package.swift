// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Current",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Current", targets: ["Current"]),
        .executable(name: "CurrentRelauncher", targets: ["CurrentRelauncher"]),
        .executable(
            name: "CurrentContextWorker",
            targets: ["CurrentContextWorker"]
        ),
        .library(name: "CurrentCore", targets: ["CurrentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.6"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CurrentCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "Current",
            dependencies: ["CurrentCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "CurrentRelauncher"),
        .executableTarget(
            name: "CurrentContextWorker",
            dependencies: ["CurrentCore"]
        ),
        .testTarget(
            name: "CurrentCoreTests",
            dependencies: ["CurrentCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
