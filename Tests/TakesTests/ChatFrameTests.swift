import AVFoundation
import Foundation
import Testing
@testable import Takes

/// 2026-10-13: a chat named an edit while ffmpeg still wrote it, and its card stayed grey.
@MainActor
struct ChatFrameTests {
    /// Runs ffmpeg: a 2 s video with its index at the end, as ffmpeg writes it without faststart.
    @Test func aCardWaitsForAVideoStillBeingWritten() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appending(path: "full.mp4"), edit = dir.appending(path: "edit-v1.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=2",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", full.path]
        try p.run()
        p.waitUntilExit()
        let data = try Data(contentsOf: full)
        try data.prefix(data.count / 2).write(to: edit)   // half written: no index yet
        #expect(await Thumbs.shared.frame(waitingFor: edit, tries: 1) == nil)

        let wait = Task { await Thumbs.shared.frame(waitingFor: edit, tries: 20, every: .milliseconds(150)) }
        try await Task.sleep(for: .milliseconds(400))
        try data.write(to: edit)                           // ffmpeg is done
        #expect(await wait.value != nil)
    }
}
