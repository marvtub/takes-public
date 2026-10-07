// swift-tools-version: 6.3
// takes-embed: the on-device search engine for Takes (EmbeddingGemma 2 on MLX).
// Built with xcodebuild by build.sh (`swift build` cannot compile MLX's Metal shaders) and shipped
// inside Takes.app. The model weights are not in the app: Takes downloads them in the background.
// Sources/EmbeddingGemma2 is a pinned copy of github.com/Obscyra-app/EmbeddingGemma2Swift
// (MIT, commit 2c7815f, 2026-10-06), read through before it went in: it makes no network calls.
import PackageDescription

let package = Package(
    name: "TakesEmbed",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "takes-embed", targets: ["TakesEmbed"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [
        .target(name: "EmbeddingGemma2", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers")]),
        .executableTarget(name: "TakesEmbed", dependencies: ["EmbeddingGemma2", .product(name: "MLX", package: "mlx-swift")],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ])
