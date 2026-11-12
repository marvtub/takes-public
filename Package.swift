// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Takes",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Takes", path: "Sources/Takes"),
        // The face finder for check_edit's framing check (mcp/takes_mcp.py chk_framing).
        .executableTarget(name: "takes-faces", path: "Sources/TakesFaces"),
        .testTarget(name: "TakesTests", dependencies: ["Takes"], path: "Tests/TakesTests"),
        .testTarget(name: "TakesFacesTests", path: "Tests/TakesFacesTests")
    ],
    swiftLanguageModes: [.v5]
)
