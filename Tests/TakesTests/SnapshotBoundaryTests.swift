import Foundation
import Testing

/// Snapshot tests render their own views. The running app must not expose a remote capture hook
/// (2026-10-31): a distributed notification has no trusted sender or destination.
struct SnapshotBoundaryTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theRemoteSnapshotProtocolIsAbsentFromProduction() throws {
        let sources = root.appending(path: "Sources/Takes")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let exposesSnapshotProtocol = source.contains("de.marvinaziz.takes.snapshot")
            #expect(!exposesSnapshotProtocol,
                    "No production listener for an unauthenticated capture request: \(file.lastPathComponent)")
        }
    }

    @Test func appLaunchCannotRegisterOrCaptureRemoteSnapshots() throws {
        let source = try String(contentsOf: root.appending(path: "Sources/Takes/Views.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "final class AppDelegate:"))
        let end = try #require(source.range(of: "\nextension NSWindow {", range: start.upperBound..<source.endIndex))
        let delegate = source[start.lowerBound..<end.lowerBound]
        let registersRemoteRequests = delegate.contains("DistributedNotificationCenter")
        let preparesCapture = delegate.contains("bitmapImageRepForCachingDisplay")
        let capturesWindow = delegate.contains("cacheDisplay(")
        #expect(!registersRemoteRequests, "App launch must not register remote capture requests")
        #expect(!preparesCapture, "App launch must not prepare a remote capture")
        #expect(!capturesWindow, "App launch must not capture a window on a remote request")
    }
}
