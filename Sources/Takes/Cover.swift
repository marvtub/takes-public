import AVFoundation
import Foundation
import SwiftUI

// A cover is a thumbnail baked into the video as its first frames, so the feed and the player show
// it before the video plays (2026-10-02: The user had thumbnails but no way to get one into the video).
//
// "Use as cover" on an image in thumbnails/ makes the next edit version: the image for
// `Cover.seconds`, then the post's video. The post then shows that version. The post's front
// matter keeps the choice, so Claude can put the same cover on each later edit:
//
//   cover:       thumbnails/x.png    the image
//   cover_from:  edits/a-v7.mp4      the video without the cover
//   cover_video: edits/a-v8.mp4      the version Takes made with it

enum Cover {
    /// How long the cover shows. Long enough to be frame 0 everywhere, short enough not to be seen.
    static let seconds = 0.1

    /// Only thumbnails can be a cover.
    static func can(_ image: URL) -> Bool {
        Asset.kind(of: image) == .image && image.deletingLastPathComponent().lastPathComponent == "thumbnails"
            && AppModel.session(containing: image) != nil
    }

    /// The cover the session's post uses now.
    static func current(_ session: URL) -> URL? {
        PostFile.read(session)?.meta["cover"].map { session.appending(path: $0).standardizedFileURL }
    }

    /// The video to put a cover on: the post's video, but without a cover Takes made before.
    static func source(in session: URL) -> URL? {
        let c = PostFile.read(session)
        guard let media = PostFile.media(c, in: session), Asset.kind(of: media) == .video else {
            return PostFile.newest(session.appending(path: "edits"), .video)
        }
        if let made = c?.meta["cover_video"], let from = c?.meta["cover_from"],
           media.standardizedFileURL == session.appending(path: made).standardizedFileURL {
            let u = session.appending(path: from)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return media
    }

    /// edits/a-v7.mp4 → edits/a-v8.mp4 (one more than the highest a-vN there).
    static func next(after video: URL) -> URL {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent
        let slug = stem.replacingOccurrences(of: #"-v\d+$"#, with: "", options: .regularExpression)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let top = names.compactMap { n -> Int? in
            let s = (n as NSString).deletingPathExtension
            guard s.hasPrefix(slug + "-v") else { return nil }
            return Int(s.dropFirst(slug.count + 2))
        }.max() ?? 1
        return dir.appending(path: "\(slug)-v\(top + 1).mp4")
    }

    /// Makes `out`: the image for `seconds`, filled and cropped to the video's frame, then the video.
    static func make(image: URL, video: URL, out: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("No video in \(video.lastPathComponent)") }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let size = natural.applying(transform)
        let w = Int(abs(size.width)) / 2 * 2, h = Int(abs(size.height)) / 2 * 2
        let fps = rate > 0 ? Double(rate) : 30
        let sound = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        let fmt = "aformat=sample_rates=48000:channel_layouts=stereo"
        var graph = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1,fps=\(fps),format=yuv420p[c];"
            + "[0:v]setsar=1,fps=\(fps),format=yuv420p[v];"
        graph += sound
            ? "[2:a]\(fmt)[s];[0:a]\(fmt)[a];[c][s][v][a]concat=n=2:v=1:a=1[ov][oa]"
            : "[c][v]concat=n=2:v=1:a=0[ov]"
        var args = ["-hide_banner", "-loglevel", "error", "-y",
                    "-i", video.path,
                    "-loop", "1", "-framerate", "\(fps)", "-t", "\(seconds)", "-i", image.path,
                    "-f", "lavfi", "-t", "\(seconds)", "-i", "anullsrc=r=48000:cl=stereo",
                    "-filter_complex", graph, "-map", "[ov]"]
        if sound { args += ["-map", "[oa]", "-c:a", "aac", "-b:a", "192k"] }
        args += ["-c:v", "libx264", "-crf", "18", "-preset", "fast", "-pix_fmt", "yuv420p",
                 "-movflags", "+faststart", out.path]
        try await ffmpeg(args)
    }

    /// Puts `image` on the post's video as its cover: a new edit version, and the post shows it.
    /// Returns the new file.
    static func use(_ image: URL) async throws -> URL {
        guard let session = AppModel.session(containing: image) else { throw Failure("This image is not in a session") }
        guard let video = source(in: session) else { throw Failure("No edit in edits/ to put the cover on") }
        let out = next(after: video)
        let part = out.deletingLastPathComponent().appending(path: ".\(out.lastPathComponent).part.mp4")
        try await make(image: image, video: video, out: part)
        try FileManager.default.moveItem(at: part, to: out)

        let rel = { (u: URL) in String(u.standardizedFileURL.path.dropFirst(session.standardizedFileURL.path.count + 1)) }
        let pinned = PostFile.read(session)?.media != nil
        if PostFile.read(session) == nil { PostFile.write(PostFile.Content(text: ""), to: session) }
        PostFile.update(session) { c in
            c.meta["cover"] = rel(image)
            c.meta["cover_from"] = rel(video)
            c.meta["cover_video"] = rel(out)
            // A starred video moves to the new version; else the newest edit (this one) shows anyway.
            if pinned { c.media = rel(out) }
        }
        return out
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static func ffmpeg(_ args: [String]) async throws {
        let bin = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { throw Failure("ffmpeg is not installed (brew install ffmpeg)") }
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            p.qualityOfService = .utility
            try p.run()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
                throw Failure("ffmpeg failed: \(msg ?? "exit \(p.terminationStatus)")")
            }
        }.value
    }
}

extension AppModel {
    /// "Use as cover": makes the version in the background, then says where it is.
    func useCover(_ image: URL) {
        guard !coverWork.contains(image) else { return }
        coverWork.insert(image)
        show(toast: "Putting the cover on the video…")
        Task {
            defer { coverWork.remove(image) }
            do {
                let out = try await Cover.use(image)
                show(toast: "\(out.deletingPathExtension().lastPathComponent) starts with this cover. The post uses it.")
            } catch {
                show(toast: error.localizedDescription)
            }
        }
    }
}

/// "Use as cover" on a thumbnail: on the stage bar (dark) and on chat cards (light).
struct CoverButton: View {
    @Environment(AppModel.self) var app
    let image: URL
    var dark = true
    @State private var isCover = false

    var body: some View {
        let busy = app.coverWork.contains(image)
        Button { app.useCover(image) } label: {
            HStack(spacing: 5) {
                if busy {
                    LayerSpinner(color: dark ? .white : Theme.ink, lineWidth: 1.5, inset: 1).frame(width: 12, height: 12)
                } else {
                    Image(systemName: isCover ? "checkmark" : "photo.badge.checkmark")
                }
                Text(busy ? "Making…" : isCover ? "Cover" : "Use as cover")
            }
            .font(dark ? Theme.mono(11, .medium) : Theme.sans(12, .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(dark ? Color.white.opacity(isCover ? 0.18 : 0.1) : (isCover ? Theme.accentSoft : Theme.hover),
                        in: RoundedRectangle(cornerRadius: Theme.radius))
            .foregroundStyle(dark ? Color.white : (isCover ? Theme.accentInk : Theme.ink))
        }
        .buttonStyle(.plain)
        .disabled(busy || app.isRecording)
        .help(isCover ? "The video starts with this image. Click to make the newest edit again with it."
                      : "Put this image in the first frames of the post's video, as a new edit version")
        .task(id: busy) {
            if let s = AppModel.session(containing: image) { isCover = Cover.current(s) == image.standardizedFileURL }
        }
    }
}
