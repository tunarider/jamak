// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JamakCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JamakCore", targets: ["JamakCore"]),
        .library(name: "JamakMedia", targets: ["JamakMedia"]),
        .library(name: "JamakLLM", targets: ["JamakLLM"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .target(name: "JamakCore", resources: [.process("Resources")]),
        .target(name: "JamakMedia", dependencies: [
            "JamakCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ]),
        .target(name: "JamakLLM", dependencies: ["JamakCore"]),
        .testTarget(name: "JamakCoreTests", dependencies: ["JamakCore"]),
        .testTarget(name: "JamakMediaTests", dependencies: [
            "JamakMedia",
            "JamakCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ]),
        .testTarget(name: "JamakLLMTests", dependencies: ["JamakLLM", "JamakCore"]),
    ]
)
