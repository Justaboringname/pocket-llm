// swift-tools-version: 6.2
// LLMCore: the MLX-free core of the app (catalog, protocols, mocks, thinking parser,
// memory-fit math, safety monitors, chat view model, persistence).
//
// This package must never depend on MLX or on Hugging Face packages so that it builds and
// tests on the Mac host with plain `swift build` / `swift test`. The MLX-backed engine and
// the Hugging Face-backed downloader live in the app target and plug into the protocols
// defined here.

import PackageDescription

let package = Package(
    name: "LLMCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "LLMCore", targets: ["LLMCore"])
    ],
    targets: [
        .target(
            name: "LLMCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LLMCoreTests",
            dependencies: ["LLMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
