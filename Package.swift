// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Takes",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Takes", path: "Sources/Takes"),
        .testTarget(name: "TakesTests", dependencies: ["Takes"], path: "Tests/TakesTests")
    ],
    swiftLanguageModes: [.v5]
)
