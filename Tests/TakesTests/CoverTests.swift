import AVFoundation
import Foundation
import Testing
@testable import Takes

struct CoverTests {
    @Test func nextVersionIsOneMoreThanTheHighest() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString)/edits")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        for n in ["shop-v3.mp4", "shop-v7.mp4", "other-v9.mp4"] { try Data().write(to: dir.appending(path: n)) }
        #expect(Cover.next(after: dir.appending(path: "shop-v3.mp4")).lastPathComponent == "shop-v8.mp4")
        #expect(Cover.next(after: dir.appending(path: "cut.mp4")).lastPathComponent == "cut-v2.mp4")
    }

    /// Runs ffmpeg: a red thumbnail on a 1 s blue video with sound.
    @Test func coverBecomesTheFirstFrameAndThePostUsesIt() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
        let fm = FileManager.default
        let s = fm.temporaryDirectory.appending(path: "cover-\(UUID().uuidString)/P/2026-10-02-a")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        try fm.createDirectory(at: s.appending(path: "thumbnails"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        let video = s.appending(path: "edits/a-v1.mp4"), image = s.appending(path: "thumbnails/a-v1.png")
        try sh(["-f", "lavfi", "-i", "color=blue:s=360x640:r=30:d=1", "-f", "lavfi", "-i", "sine=d=1",
                "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
        try sh(["-f", "lavfi", "-i", "color=red:s=400x400", "-frames:v", "1", image.path])
        PostFile.pickMedia("thumbnails/a-v1.png", in: s)  // starred as the post image, like the user did

        let out = try await Cover.use(image)
        #expect(out.lastPathComponent == "a-v2.mp4")
        let c = try #require(PostFile.read(s))
        #expect(c.media == "edits/a-v2.mp4")
        #expect(c.meta["cover"] == "thumbnails/a-v1.png")
        #expect(Cover.current(s) == image.standardizedFileURL)
        // Again: it starts from a-v1, not from the version that already has a cover.
        #expect(Cover.source(in: s)?.lastPathComponent == "a-v1.mp4")

        let asset = AVURLAsset(url: out)
        let d = try await asset.load(.duration).seconds
        #expect(abs(d - 1.1) < 0.08)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let first = try await gen.image(at: .zero).image
        let later = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        #expect(Self.red(first) > 0.7 && Self.red(later) < 0.3)
        #expect(first.width == 360 && first.height == 640)
    }

    private static func red(_ img: CGImage) -> Double {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(ctx.data!.load(as: UInt8.self)) / 255
    }

    private func sh(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}
