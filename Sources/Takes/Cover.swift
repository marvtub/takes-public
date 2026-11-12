import AVFoundation
import Foundation
import ImageIO
import SwiftUI

// A cover is a thumbnail baked into the video as its first frames, so the feed and the player show
// it before the video plays (2026-10-02: The user had thumbnails but no way to get one into the video).
//
// The Cover button on the Post tab picks one for the platform on show: each platform has its own
// video, and its versions (Main, Short, ...) share it. Takes makes the next edit version: the
// image for `Cover.seconds`, then that post's video. That post then shows the new version. Its
// front matter keeps the choice, so Claude can put the same cover on each later edit:
//
//   cover:       thumbnails/x.png    the image
//   cover_from:  edits/a-v7.mp4      the video without the cover
//   cover_video: edits/a-v8.mp4      the version Takes made with it
//
// Before (2026-10-04), "Use as cover" sat on every thumbnail and always went to the LinkedIn post.
//
// An edit with a recipe (2026-10-11, EditRecipe.swift) has its cover in the recipe, and publish_edit
// drops cover_from. A new cover on such a version skips the old one (no second cover stacked), and
// No cover makes a version without it. Both write the new version's recipe.

enum Cover {
    /// How long the cover shows. Long enough to be frame 0 everywhere, short enough not to be seen.
    static let seconds = 0.1

    /// Only thumbnails can be a cover.
    static func can(_ image: URL) -> Bool {
        Asset.kind(of: image) == .image && image.deletingLastPathComponent().lastPathComponent == "thumbnails"
            && AppModel.session(containing: image) != nil
    }

    /// The platforms whose post can have a cover: the ones that show a video.
    static func platforms() -> [PostPlatform] { PostPlatform.allCases.filter { $0 != .article } }

    /// The cover a platform's post uses now.
    static func current(_ session: URL, _ p: PostPlatform = .linkedin) -> URL? {
        PostFile.read(session, p)?.meta["cover"].map { session.appending(path: $0).standardizedFileURL }
    }

    /// The video to put a cover on: the post's video, but without a cover Takes made before.
    static func source(in session: URL, _ p: PostPlatform = .linkedin) -> URL? {
        let c = PostFile.read(session, p)
        guard let media = PostFile.media(c, in: session, p), Asset.kind(of: media) == .video else {
            return p == .vertical ? nil : PostFile.newest(session.appending(path: "edits"), .video)
        }
        if let made = c?.meta["cover_video"], let from = c?.meta["cover_from"],
           media.standardizedFileURL == session.appending(path: made).standardizedFileURL {
            let u = session.appending(path: from)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return media
    }

    /// Width over height of an image or a video, as it shows.
    static func ratio(_ url: URL) -> CGFloat? {
        if Asset.kind(of: url) == .video {
            guard let track = AVURLAsset(url: url).tracks(withMediaType: .video).first else { return nil }
            let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            return abs(r.height) > 0 ? abs(r.width) / abs(r.height) : nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, h > 0 else { return nil }
        let turned = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? h / w : w / h
    }

    /// Tall, wide or square: a cover is cropped to fill the video, so only the same shape fits.
    static func shape(_ ratio: CGFloat) -> Int { ratio < 0.85 ? -1 : ratio > 1.18 ? 1 : 0 }

    /// The session's thumbnails with the shape of `video`, newest first.
    static func candidates(in session: URL, for video: URL) -> [URL] {
        let dir = session.appending(path: "thumbnails")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let want = ratio(video).map(shape)
        return files.filter { Asset.kind(of: $0) == .image }
            .filter { f in want == nil || ratio(f).map(shape) == want }
            .sorted { (Store.modified($0) ?? .distantPast) > (Store.modified($1) ?? .distantPast) }
            .map(\.standardizedFileURL)
    }

    /// edits/a-v7.mp4 → edits/a-v8.mp4 (one more than the highest a-vN there). A recipe with no video
    /// (a-v8.recipe.json: publish_edit claimed it) counts too.
    static func next(after video: URL) -> URL {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent
        let slug = stem.replacingOccurrences(of: #"-v\d+$"#, with: "", options: .regularExpression)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let top = names.compactMap { n -> Int? in
            guard n.hasPrefix(slug + "-v") else { return nil }
            let digits = n.dropFirst(slug.count + 2).prefix { $0.isNumber }
            let rest = n.dropFirst(slug.count + 2 + digits.count)
            return rest.hasPrefix(".") ? Int(digits) : nil
        }.max() ?? 1
        return dir.appending(path: "\(slug)-v\(top + 1).mp4")
    }

    /// Makes `out`: the image for `seconds`, filled and cropped to the video's frame, then the video.
    /// `skip`: seconds cut off the video's start first (the cover a recipe already baked in). No image:
    /// only the cut.
    static func make(image: URL?, video: URL, out: URL, skip: Double = 0) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("No video in \(video.lastPathComponent)") }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let size = natural.applying(transform)
        let w = Int(abs(size.width)) / 2 * 2, h = Int(abs(size.height)) / 2 * 2
        let fps = rate > 0 ? Double(rate) : 30
        let sound = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        try await ffmpeg(args(image: image, video: video, out: out, w: w, h: h, fps: fps, sound: sound, skip: skip))
    }

    /// The ffmpeg arguments of `make`, as a plain function for the tests.
    static func args(image: URL?, video: URL, out: URL, w: Int, h: Int, fps: Double, sound: Bool, skip: Double) -> [String] {
        let input = (skip > 0 ? ["-ss", String(format: "%.3f", skip)] : []) + ["-i", video.path]
        var args = ["-hide_banner", "-loglevel", "error", "-y"] + input
        if let image {
            let fmt = "aformat=sample_rates=48000:channel_layouts=stereo"
            var graph = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1,fps=\(fps),format=yuv420p[c];"
                + "[0:v]setsar=1,fps=\(fps),format=yuv420p[v];"
            graph += sound
                ? "[2:a]\(fmt)[s];[0:a]\(fmt)[a];[c][s][v][a]concat=n=2:v=1:a=1[ov][oa]"
                : "[c][v]concat=n=2:v=1:a=0[ov]"
            args += ["-loop", "1", "-framerate", "\(fps)", "-t", "\(seconds)", "-i", image.path,
                     "-f", "lavfi", "-t", "\(seconds)", "-i", "anullsrc=r=48000:cl=stereo",
                     "-filter_complex", graph, "-map", "[ov]"]
            if sound { args += ["-map", "[oa]", "-c:a", "aac", "-b:a", "192k"] }
        } else {
            args += ["-map", "0:v:0"] + (sound ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "192k"] : [])
        }
        return args + ["-c:v", "libx264", "-crf", "18", "-preset", "fast", "-pix_fmt", "yuv420p",
                       "-map_chapters", "-1", "-movflags", "+faststart", out.path]
    }

    /// Puts `image` on a platform's video as its cover: a new edit version, and that post shows it.
    /// Returns the new file.
    static func use(_ image: URL, on p: PostPlatform = .linkedin) async throws -> URL {
        guard let session = AppModel.session(containing: image) else { throw Failure("This image is not in a session") }
        guard let video = source(in: session, p) else { throw Failure("No video in edits/ for the \(p.name) post") }
        // A version whose recipe has a cover: its first seconds are that cover. Skip them, never stack.
        let baked = EditRecipe.cover(for: video)
        let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
        let rel = { (u: URL) in String(real(u).dropFirst(real(session).count + 1)) }
        let part = temp(after: video)
        try await make(image: image, video: video, out: part, skip: baked?.seconds ?? 0)
        // Read before the new version lands: after, it is the newest edit every post without a pick shows.
        let keep = before(session)
        let out = try land(part, after: video)
        EditRecipe.withCover(source: video, image: rel(image), out: out, session: session)
        settle(session, p, keep: keep) { c in
            c.meta["cover"] = rel(image)
            c.meta["cover_from"] = baked == nil ? rel(video) : nil
            c.meta["cover_video"] = baked == nil ? rel(out) : nil
            c.media = rel(out)
            // He picked a cover, not this file: publish_edit moves the post on to the next version.
            c.meta["media_by"] = "takes"
        }
        return out
    }

    /// A hidden temp file for the next version of `video`.
    private static func temp(after video: URL) -> URL {
        let n = next(after: video)
        return n.deletingLastPathComponent().appending(path: ".\(n.lastPathComponent).\(UUID().uuidString.prefix(6)).part.mp4")
    }

    /// Moves the finished temp file to the next free version, never over a file: publish_edit may take a
    /// number while ffmpeg runs.
    private static func land(_ temp: URL, after video: URL) throws -> URL {
        for _ in 0..<20 {
            let out = next(after: video)
            do {
                try FileManager.default.linkItem(at: temp, to: out)
                try? FileManager.default.removeItem(at: temp)
                return out
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                if FileManager.default.fileExists(atPath: out.path) { continue }
                try FileManager.default.moveItem(at: temp, to: out)
                return out
            }
        }
        try? FileManager.default.removeItem(at: temp)
        throw Failure("No free version number for \(video.lastPathComponent)")
    }

    /// Takes the cover off: the post shows the video without it again. A version whose recipe baked the
    /// cover in (no cover_from) gets a new version without its first seconds.
    static func remove(from session: URL, _ p: PostPlatform) async throws {
        guard let c = PostFile.read(session, p), c.meta["cover"] != nil else { return }
        if c.meta["cover_from"] == nil, let media = PostFile.media(c, in: session, p),
           let baked = EditRecipe.cover(for: media) {
            let part = temp(after: media)
            try await make(image: nil, video: media, out: part, skip: baked.seconds)
            let keep = before(session)
            let out = try land(part, after: media)
            EditRecipe.withCover(source: media, image: nil, out: out, session: session)
            let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
            settle(session, p, keep: keep) { c in
                c.meta["cover"] = nil; c.meta["cover_from"] = nil; c.meta["cover_video"] = nil
                c.media = String(real(out).dropFirst(real(session).count + 1))
                c.meta["media_by"] = "takes"
            }
            return
        }
        let from = c.meta["cover_from"].map { session.appending(path: $0) }
        let back = from.flatMap { FileManager.default.fileExists(atPath: $0.path) ? c.meta["cover_from"] : nil }
        settle(session, p, keep: before(session)) { c in
            c.meta["cover"] = nil; c.meta["cover_from"] = nil; c.meta["cover_video"] = nil
            c.media = back
        }
    }

    /// What each platform's post shows now.
    private static func before(_ session: URL) -> [PostPlatform: (pick: String?, shows: URL?)] {
        var out: [PostPlatform: (pick: String?, shows: URL?)] = [:]
        for p in platforms() {
            guard let c = PostFile.read(session, p) else { continue }
            out[p] = (c.media, PostFile.media(c, in: session, p))
        }
        return out
    }

    /// Changes post `p`, then keeps every other post on the video it showed. A post without a pick
    /// shows the newest edit, and the new cover version is the newest: before, a cover for the
    /// vertical post also moved the LinkedIn post onto it.
    private static func settle(_ session: URL, _ p: PostPlatform, keep: [PostPlatform: (pick: String?, shows: URL?)],
                               _ change: (inout PostFile.Content) -> Void) {
        if PostFile.read(session, p) == nil { PostFile.write(PostFile.Content(text: ""), to: session, p) }
        PostFile.update(session, p, change)
        // Resolved: a folder listing says /private/var where the session says /var.
        let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
        let base = real(session) + "/"
        for (q, was) in keep where q != p && was.pick == nil {
            guard let shows = was.shows, real(shows).hasPrefix(base),
                  PostFile.media(PostFile.read(session, q), in: session, q).map(real) != real(shows)
            else { continue }
            PostFile.update(session, q) { $0.media = String(real(shows).dropFirst(base.count)) }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static func ffmpeg(_ args: [String]) async throws {
        guard let bin = Setup.tool("ffmpeg") else { throw Failure("ffmpeg is missing. Click Finish setup in the sidebar.") }
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
    /// Makes the cover version in the background, then says where it is. `coverWork` holds the
    /// post file while it works, so its button shows a spinner.
    func useCover(_ image: URL, on p: PostPlatform) {
        guard let session = AppModel.session(containing: image) else { return }
        let key = PostFile.url(session, p).standardizedFileURL
        guard !coverWork.contains(key) else { return }
        coverWork.insert(key)
        show(toast: "Putting the cover on the \(p.name) video…")
        Task {
            defer { coverWork.remove(key) }
            do {
                let out = try await Cover.use(image, on: p)
                show(toast: "\(out.deletingPathExtension().lastPathComponent) starts with this cover. The \(p.name) post uses it.")
            } catch {
                show(toast: error.localizedDescription)
            }
        }
    }
}

/// The Cover button on the Post toolbar: the post's cover, and the session's thumbnails of the
/// same shape to pick from.
struct CoverPicker: View {
    @Environment(AppModel.self) var app
    let session: URL
    let platform: PostPlatform
    /// The video the post shows.
    let video: URL
    @State private var open = false
    @State private var current: URL?
    @State private var choices: [URL] = []
    @State private var images: [URL: NSImage] = [:]

    private var busy: Bool { app.coverWork.contains(PostFile.url(session, platform).standardizedFileURL) }

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                if busy {
                    LayerSpinner(color: Theme.ink, lineWidth: 1.5, inset: 1).frame(width: 13, height: 13)
                } else if let current, let img = images[current] {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "photo.on.rectangle")
                }
            }
            .frame(width: 30, height: 28)
        }
        .help(busy ? "Making the cover version…" : current == nil
              ? "Cover: put a thumbnail in the first frames of the \(platform.name) video"
              : "Cover: \(current!.lastPathComponent). Click to change it")
        .takesPopover(isPresented: $open) { panel }
        .task(id: "\(video.path)|\(busy)") { await load() }
    }

    private func load() async {
        current = Cover.current(session, platform)
        let s = session, v = video
        choices = await Task.detached(priority: .userInitiated) { Cover.candidates(in: s, for: v) }.value
        var todo: [Asset] = []
        for u in choices + [current].compactMap({ $0 }) where images[u] == nil && !todo.contains(where: { $0.url == u }) {
            todo.append(Asset(url: u, group: "", name: u.lastPathComponent, size: 0, modified: Store.modified(u) ?? .distantPast))
        }
        // Each thumbnail is its own file read: 4 at a time, not one after another.
        await withTaskGroup(of: (URL, NSImage?).self) { group in
            for (i, a) in todo.enumerated() {
                if i >= 4, let (u, img) = await group.next() { images[u] = img }
                group.addTask { (a.url, await Thumbs.shared.image(a)) }
            }
            for await (u, img) in group { images[u] = img }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(platform.name) cover").font(Theme.sans(13, .semibold))
                Text("The video starts with this image, so the feed shows it before it plays. Every version of this post uses it.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if choices.isEmpty {
                Text("No thumbnail in this shape yet. Ask Takes to make one.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 10)], spacing: 10) {
                        ForEach(choices, id: \.self) { u in tile(u) }
                    }
                }
                .frame(maxHeight: 360)
            }
            if current != nil {
                Button("No cover") {
                    open = false
                    let s = session, p = platform
                    Task {
                        do {
                            try await Cover.remove(from: s, p)
                            app.show(toast: "The \(p.name) post shows the video without a cover again")
                        } catch {
                            app.show(toast: error.localizedDescription)
                        }
                    }
                }
                .buttonStyle(BracketButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func tile(_ u: URL) -> some View {
        let on = u == current
        return Button {
            open = false
            app.useCover(u, on: platform)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.hover)
                    if let img = images[u] { Image(nsImage: img).resizable().scaledToFit() }
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.accent).padding(5)
                    }
                }
                Text((u.lastPathComponent as NSString).deletingPathExtension)
                    .font(Theme.sans(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || app.isRecording)
        .help(on ? "The cover now. Click to make the newest edit again with it." : "Use as the \(platform.name) cover")
    }
}
