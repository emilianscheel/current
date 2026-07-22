// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Current",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Current", targets: ["Current"]),
        .executable(name: "CurrentRelauncher", targets: ["CurrentRelauncher"]),
        .library(name: "CurrentCore", targets: ["CurrentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(
            name: "CurrentCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "Current",
            dependencies: ["CurrentCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "CurrentRelauncher"),
        .testTarget(name: "CurrentCoreTests", dependencies: ["CurrentCore"]),
    ]
)
