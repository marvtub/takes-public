import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// Review comments on a video in the session, for Claude to act on. Kept in <session>/comments.json:
//
//   {"comments": [{"id": "c1", "file": "edits/hook-v2.mp4", "start": 3.0, "end": 6.0,
//                  "rect": [0.1, 0.2, 0.3, 0.25], "text": "Caption too big", "status": "open",
//                  "by": "user", "at": "…", "frame": "comments/c1.png",
//                  "replies": [{"by": "claude", "text": "Fixed in v3", "at": "…"}]}]}
//
// start/end are seconds (end is missing for a single moment). rect is x, y, w, h as fractions of the
// video frame, from the top left; missing means the whole frame. frame is a PNG of the moment with the
// area drawn on it, so Claude sees what the user means (MCP get_comments / reply_comment).
// Stills have a rect and no time. Script comments have file "script.md" or "variants/<slug>.md"
// and a quote: the text the user selected.

struct Reply: Codable, Hashable {
    var by: String
    var text: String
    var at: String
    /// Claude's fix: the new version's file (relative to the session or library) and where it shows.
    var file: String?
    var time: Double?

    var link: String? {
        guard let file else { return nil }
        let name = URL(fileURLWithPath: file).lastPathComponent
        let v = StyleLib.split(name).version.map { "v\($0)" } ?? name
        return time.map { "\(v) @ \(Comment.stamp($0))" } ?? v
    }
}

struct Comment: Codable, Identifiable, Hashable {
    var id: String
    var file: String
    var start: Double?
    var end: Double?
    var rect: [Double]?
    var quote: String?
    var text: String
    var status: String
    var by: String
    var at: String
    var frame: String?
    var replies: [Reply]?
    /// A comment on a storyboard shot: its id (file is storyboard/storyboard.json).
    var shot: String?
    /// What the agent learned when it resolved the comment: a rule id or "one-off" (Feedback.swift).
    var lesson: String? = nil
    /// The rule was there before the comment: the same mistake again.
    var `repeat`: Bool? = nil

    var open: Bool { status != "resolved" }
    var area: CGRect? {
        guard let r = rect, r.count == 4 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
    var timeLabel: String { Comment.label(start, end) }

    static func label(_ start: Double?, _ end: Double?) -> String {
        guard let start else { return "whole video" }
        guard let end, end - start >= 0.1 else { return stamp(start) }
        return "\(stamp(start))–\(stamp(end))"
    }

    static func stamp(_ s: Double) -> String {
        String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

struct CommentsFile: Codable {
    var comments: [Comment] = []
}

@MainActor
final class CommentStore: ObservableObject {
    @Published private(set) var all: [Comment] = []
    private var session: URL?
    private var stamp: Date?

    nonisolated static func file(_ session: URL) -> URL { session.appending(path: "comments.json") }

    nonisolated static func read(_ session: URL) -> CommentsFile {
        guard let data = try? Data(contentsOf: file(session)),
              let f = try? JSONDecoder().decode(CommentsFile.self, from: data) else { return CommentsFile() }
        return f
    }

    static func path(of url: URL, in session: URL) -> String {
        let base = session.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    /// Cheap: rereads only when the file changed.
    func load(_ session: URL) {
        let s = Store.modified(Self.file(session))
        guard session != self.session || s != stamp else { return }
        self.session = session
        stamp = s
        let fresh = Self.read(session).comments
        if fresh != all { all = fresh }
    }

    func on(_ file: String) -> [Comment] { all.filter { $0.file == file } }

    /// Reads, changes and writes the file, so edits from Claude in between are kept.
    private func edit(_ change: (inout CommentsFile) -> Void) {
        guard let session else { return }
        Self.change(session, change)
        stamp = nil
        load(session)
    }

    /// Reads, changes and writes a session's comments from any thread (the phone server).
    /// An open store picks the change up on its next load.
    nonisolated static func change(_ session: URL, _ change: (inout CommentsFile) -> Void) {
        var f = read(session)
        change(&f)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(f) { try? data.write(to: file(session), options: .atomic) }
    }

    /// A text comment from the phone: on a quote of a script or post, or on all of it (no quote).
    nonisolated static func addText(_ session: URL, file: String, quote: String?, text: String, by: String = "user",
                                    shot: String? = nil) -> Comment {
        var made: Comment!
        change(session) { f in
            let n = (f.comments.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
            made = Comment(id: "c\(n)", file: file, quote: quote, text: text, status: "open", by: by, at: now(), shot: shot)
            f.comments.append(made)
        }
        return made
    }

    /// A comment on a video moment or range, or on an area of a still, from outside the app (the
    /// iPhone). Writes the frame PNG as the app does.
    nonisolated static func addMedia(_ session: URL, file: String, start: Double?, end: Double?, rect: CGRect?,
                                     text: String, by: String = "user") -> Comment {
        var made: Comment!
        let r2 = { (v: Double) in (v * 1000).rounded() / 1000 }
        change(session) { f in
            let n = (f.comments.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
            made = Comment(id: "c\(n)", file: file,
                           start: start.map { ($0 * 100).rounded() / 100 },
                           end: end.map { ($0 * 100).rounded() / 100 },
                           rect: rect.map { [r2($0.minX), r2($0.minY), r2($0.width), r2($0.height)] },
                           text: text, status: "open", by: by, at: now(), frame: "comments/c\(n).png")
            f.comments.append(made)
        }
        let id = made.id
        Task.detached {
            try? await CommentFrame.write(media: session.appending(path: file), at: start ?? 0, rect: rect,
                                          to: session.appending(path: "comments/\(id).png"))
        }
        return made
    }

    @discardableResult
    func add(media: URL, start: Double? = nil, end: Double? = nil, rect: CGRect?, text: String) -> Comment? {
        guard let session else { return nil }
        return add(file: Self.path(of: media, in: session), media: media, start: start, end: end,
                   rect: rect, quote: nil, text: text)
    }

    /// A comment on the selected text of a script ("script.md" or "variants/<slug>.md").
    @discardableResult
    func add(script file: String, quote: String, text: String) -> Comment? {
        add(file: file, media: nil, start: nil, end: nil, rect: nil, quote: quote, text: text)
    }

    /// A comment on a text file: on its selected text (quote), or on the whole text (no quote).
    @discardableResult
    func add(text file: String, quote: String?, text: String) -> Comment? {
        add(file: file, media: nil, start: nil, end: nil, rect: nil, quote: quote, text: text)
    }

    private func add(file: String, media: URL?, start: Double?, end: Double?, rect: CGRect?,
                     quote: String?, text: String) -> Comment? {
        guard let session else { return nil }
        let n = (Self.read(session).comments.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let r2 = { (v: Double) in (v * 1000).rounded() / 1000 }
        let c = Comment(id: "c\(n)", file: file,
                        start: start.map { ($0 * 100).rounded() / 100 },
                        end: end.map { ($0 * 100).rounded() / 100 },
                        rect: rect.map { [r2($0.minX), r2($0.minY), r2($0.width), r2($0.height)] },
                        quote: quote, text: text, status: "open", by: "user", at: Self.now(),
                        frame: media == nil ? nil : "comments/c\(n).png", replies: nil)
        edit { $0.comments.append(c) }
        if let media {
            Task.detached {
                try? await CommentFrame.write(media: media, at: start ?? 0, rect: rect,
                                              to: session.appending(path: "comments/c\(n).png"))
            }
        }
        return c
    }

    /// The user changes his own comment in place (2026-10-09: he wants to edit, not reply).
    /// A changed comment is a new ask, so it opens again.
    func setText(_ id: String, _ text: String) {
        edit { f in
            guard let i = f.comments.firstIndex(where: { $0.id == id }), f.comments[i].text != text else { return }
            f.comments[i].text = text
            f.comments[i].status = "open"
        }
    }

    func setResolved(_ id: String, _ resolved: Bool) {
        edit { f in
            guard let i = f.comments.firstIndex(where: { $0.id == id }) else { return }
            f.comments[i].status = resolved ? "resolved" : "open"
        }
    }

    func delete(_ id: String) {
        guard let session else { return }
        if let c = all.first(where: { $0.id == id }), let frame = c.frame {
            try? FileManager.default.removeItem(at: session.appending(path: frame))
        }
        edit { $0.comments.removeAll { $0.id == id } }
    }

    nonisolated private static func now() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}

enum CommentFrame {
    /// Draws an image CGImageSource cannot read (SVG) at 1600 px wide.
    @MainActor private static func rasterize(_ url: URL) -> CGImage? {
        guard let img = NSImage(contentsOf: url), img.size.width > 0 else { return nil }
        let w: CGFloat = 1600, h = (w * img.size.height / img.size.width).rounded()
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return img.cgImage(forProposedRect: &rect, context: nil, hints: nil) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        rect.fill()
        img.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// The frame at `seconds` with the area outlined in the accent colour, as a PNG for Claude.
    static func write(media: URL, at seconds: Double, rect: CGRect?, to target: URL) async throws {
        let image: CGImage
        if Asset.kind(of: media) == .image {
            if let src = CGImageSourceCreateWithURL(media as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                image = img
            } else if let img = await rasterize(media) {
                image = img   // SVG
            } else { return }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: media))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            image = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let r = rect {
            let line = max(4, CGFloat(max(w, h)) / 240)
            let box = CGRect(x: r.minX * CGFloat(w), y: (1 - r.maxY) * CGFloat(h),
                             width: r.width * CGFloat(w), height: r.height * CGFloat(h))
            ctx.setStrokeColor(NSColor(hex: 0x5B9BFF).cgColor)
            ctx.setLineWidth(line)
            ctx.stroke(box.insetBy(dx: -line / 2, dy: -line / 2))
        }
        guard let out = ctx.makeImage() else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Player state

/// The playhead in its own object: while a video plays, only the views that show the time redraw,
/// not the whole player.
@MainActor
final class Playhead: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class PlayerClock: ObservableObject {
    let player: AVPlayer
    let head = Playhead()
    var time: Double {
        get { head.time }
        set { if newValue != head.time { head.time = newValue } }
    }
    @Published var duration: Double = 0 { didSet { if duration != oldValue { observe() } } }
    @Published var playing = false
    @Published var size: CGSize = .zero
    private var observer: Any?
    private var rate: Double = 0
    private var kvo: [NSKeyValueObservation] = []

    /// Seconds between playhead updates: about one timeline pixel per update, and never less
    /// often than the tenths the time label shows. A long video needs 10 a second, not 30.
    nonisolated static func interval(for duration: Double) -> Double {
        guard duration > 0 else { return 1.0 / 30 }
        return min(0.1, max(1.0 / 30, duration / 530))
    }

    init(url: URL) {
        player = AVPlayer(url: url)
        observe()
        kvo.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let on = p.timeControlStatus != .paused
            // Only a real change: each publish redraws the player and its timeline.
            Task { @MainActor in if let self, self.playing != on { self.playing = on } }
        })
        if let item = player.currentItem {
            kvo.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] i, _ in
                let s = i.presentationSize
                Task { @MainActor in if let self, self.size != s { self.size = s } }
            })
        }
    }

    private func observe() {
        let every = Self.interval(for: duration)
        guard every != rate || observer == nil else { return }
        if let observer { player.removeTimeObserver(observer) }
        rate = every
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: every, preferredTimescale: 600),
                                                  queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration, d.isNumeric, d.seconds != self.duration {
                    self.duration = d.seconds
                }
            }
        }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        kvo.removeAll()
    }

    /// Play another item of the same video (the take with its clean voice), from the same moment.
    func swap(_ item: AVPlayerItem) {
        let at = player.currentTime()
        let rolling = player.timeControlStatus != .paused
        player.replaceCurrentItem(with: item)
        kvo.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] i, _ in
            let s = i.presentationSize
            Task { @MainActor in if let self, s != .zero, self.size != s { self.size = s } }
        })
        player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
        if rolling { player.play() }
    }

    func seek(_ s: Double) {
        let t = max(0, min(duration, s))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle() {
        if playing { player.pause(); return }
        if duration > 0 && time >= duration - 0.05 { seek(0) }
        player.play()
    }
}

// MARK: - Review player

/// A video with a timeline you can comment on. Drag on the timeline to scrub. Press C (or click
/// Comment), then drag on the frame to mark an area or drag on the timeline to pick a range;
/// ⌥-drag on the timeline picks a range at once. All open the same small composer.
struct ReviewPlayer: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var paneShown
    let url: URL
    let session: URL
    /// In the post preview: it waits for a click, keeps its own comment mode and leaves the
    /// stage's player and keys alone.
    let embedded: Bool
    @StateObject private var clock: PlayerClock
    /// The post preview's own comment mode, which the app's keys reach through app.postReview.
    @StateObject private var post = PostReview()
    @StateObject private var store = CommentStore()
    @State private var draft: Draft?
    @State private var focused: String?
    @State private var drawStart: CGPoint?
    @State private var seekOnLoad: Double?
    /// The floating controls: on while the pointer moves or the video is paused, off 2 s after.
    @State private var chrome = true
    @State private var hideChrome: Task<Void, Never>?
    @State private var scrubbing = false
    /// The video's width, for the bar under it: narrow, it drops the time label.
    @State private var videoWidth: CGFloat = 600
    /// The bar sits under the video, never on it (2026-10-09): over the picture it hid captions
    /// and titles the user was reviewing. Its height plus the gap above it.
    static let barSpace: CGFloat = 54
    /// The vertical apps' safe zone over a tall video: pinned with its button, shown while the
    /// pointer is on the button.
    @AppStorage("safeZone") private var safePinned = false
    @State private var safePeek = false
    /// The take's voice, when this video is a take (nil for edits and other files).
    @StateObject private var voice: VoiceHolder

    struct Draft: Equatable {
        var quote: String?
        var timed = true
        var start: Double?
        var end: Double?
        var rect: CGRect?
        var text = ""
    }

    init(url: URL, session: URL, embedded: Bool = false) {
        self.url = url
        self.session = session
        self.embedded = embedded
        _clock = StateObject(wrappedValue: PlayerClock(url: url))
        _voice = StateObject(wrappedValue: VoiceHolder(Voice.take(for: url, in: session).map { VoiceMix(take: $0, session: session) }))
    }

    private var comments: [Comment] { store.on(CommentStore.path(of: url, in: session)) }

    /// Drawing an area or a range: the app's mode on the stage, the player's own in the post.
    private var mode: Bool {
        get { embedded ? post.mode : app.commentMode }
        nonmutating set { if embedded { post.mode = newValue } else { app.commentMode = newValue } }
    }
    private var modeBinding: Binding<Bool> { Binding(get: { mode }, set: { mode = $0 }) }

    /// The feed's shape: the video's own, at most 4:5 tall.
    private var ratio: CGFloat {
        guard clock.size.width > 0, clock.size.height > 0 else { return 4.0 / 5.0 }
        return max(clock.size.width / clock.size.height, 4.0 / 5.0)
    }

    var body: some View {
        let _ = Perf.body("ReviewPlayer")
        Group {
            if embedded {
                videoBox(width: nil)
            } else {
                // The video in its own shape, as big as fits, clear of the pills on top.
                GeometryReader { geo in
                    let room = CGSize(width: max(0, geo.size.width - 40), height: max(0, geo.size.height - 76 - Self.barSpace))
                    let box = Self.fit(clock.size == .zero ? CGSize(width: 16, height: 9) : clock.size, in: room).size
                    videoBox(width: box.width)
                        .frame(width: max(box.width, 360), height: box.height + Self.barSpace)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(y: 18)
                        // Hidden until the video's shape is known: else a 16:9 box shows first
                        // and jumps to the real shape (2026-10-04).
                        .opacity(sizing ? 0 : 1)
                        .animation(.page, value: sizing)
                }
            }
        }
        .onAppear {
            releaseKeys()
            store.load(session)
            if embedded { post.clock = clock; app.postReview = post; return }
            app.player = clock.player
            if let t = app.pendingSeek {
                app.pendingSeek = nil
                seekOnLoad = t
            } else {
                clock.player.play()
            }
        }
        .onChange(of: clock.duration) { _, d in
            if d > 0, let t = seekOnLoad { seekOnLoad = nil; clock.seek(t) }
        }
        .onChange(of: paneShown) { _, on in if !on { clock.player.pause(); mode = false } }
        .onDisappear {
            clock.stop(); mode = false
            if app.postReview === post { app.postReview = nil }
        }
        .onFilesChanged(in: session) { store.load(session); voice.mix?.reload() }
        .task { voice.mix?.attach(clock) }
        .onChange(of: mode) { _, on in
            if on { clock.player.pause(); focused = nil }
        }
        .onExitCommand { cancel() }
    }

    /// The video with its comment layers and big play button, and the controls under it.
    private func videoBox(width: CGFloat?) -> some View {
        VStack(spacing: embedded ? 0 : Self.barSpace - 44) {
            Group {
                if embedded { video.aspectRatio(ratio, contentMode: .fit) } else { video.frame(width: width) }
            }
                .shadow(color: .black.opacity(embedded ? 0 : 0.35), radius: 24, y: 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { videoWidth = $0 }
            ReviewBar(clock: clock, head: clock.head, url: url, comments: comments, draft: $draft, focused: focused,
                      commentMode: modeBinding, embedded: embedded, compact: videoWidth < 440,
                      scrubbing: $scrubbing,
                      onRange: { s, e in
                          clock.player.pause()
                          focused = nil
                          draft = Draft(start: s, end: e, rect: draft?.rect)
                      },
                      voice: voice.mix,
                      safeZone: vertical ? $safePinned : nil,
                      onSafePeek: { safePeek = $0 },
                      onFocus: { focus($0) },
                      onComment: { mode.toggle() })
                .frame(height: 44)
                .padding(embedded ? 8 : 0)
        }
    }

    private var video: some View {
        GeometryReader { geo in
            let frame = Self.fit(clock.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                // The AVPlayerView keeps every click, so a clear layer on top takes it: a click
                // on the picture plays or pauses. Off while commenting: that click draws an area.
                PlayerLayerView(player: clock.player).allowsHitTesting(false)
                if !mode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { releaseKeys(); clock.toggle(); wake() }
                }
                TimedAreas(head: clock.head, comments: comments, frame: frame, focused: focused,
                           hidden: draft != nil || mode, onFocus: focus)
                if showSafe { SafeZoneOverlay(frame: frame).transition(.opacity) }
                if let a = draft?.rect { areaBox(a, in: frame, number: nil, strong: true).allowsHitTesting(false) }
                if mode { drawLayer(frame) }
            }
            .overlay { bigPlay }
            .overlay(alignment: .top) {
                // The file name, with the controls (the post preview shows its own).
                if showChrome && !embedded && !mode {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(Theme.sans(12, .semibold)).foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                        .help(url.path)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 14, style: .continuous))
        }
        .overlay(alignment: .bottomLeading) { card.padding(12) }
        .onContinuousHover { phase in
            if case .active = phase { wake() } else { sleepSoon(after: 0.6) }
        }
        .animation(Theme.motion, value: showChrome)
        .animation(Theme.motion, value: showSafe)
        .animation(Theme.spring, value: clock.playing)
        .onChange(of: clock.playing) { _, on in if on { sleepSoon() } else { wake() } }
    }

    /// A tall video, made for TikTok, Reels and Shorts. Not in the post preview, which crops to 4:5.
    private var vertical: Bool { !embedded && SafeZone.fits(clock.size) }
    private var showSafe: Bool { vertical && (safePinned || safePeek) && !mode }

    /// The video's shape is not known yet. A file with no picture shows once its length is known.
    private var sizing: Bool { clock.size == .zero && clock.duration == 0 }

    /// Controls stay while paused, commenting or scrubbing; else they follow the pointer.
    private var showChrome: Bool {
        chrome || !clock.playing || mode || draft != nil || scrubbing || focused != nil
    }

    private func wake() {
        if !chrome { chrome = true }
        sleepSoon()
    }

    private func sleepSoon(after secs: Double = 2) {
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled { chrome = false }
        }
    }

    /// Paused: one big round play button in the middle. A click plays.
    @ViewBuilder private var bigPlay: some View {
        if !clock.playing && !mode && draft == nil && clock.duration > 0 {
            Button { releaseKeys(); clock.toggle() } label: { GlassPlayButton() }
            .buttonStyle(PressScale())
            .help("Play (Space)")
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    // MARK: Frame

    /// Where an aspect-fit video sits inside `box`.
    static func fit(_ video: CGSize, in box: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / video.width, box.height / video.height)
        let w = video.width * s, h = video.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func areaBox(_ a: CGRect, in f: CGRect, number: Int?, strong: Bool) -> some View {
        Self.areaBox(a, in: f, number: number, strong: strong)
    }

    static func areaBox(_ a: CGRect, in f: CGRect, number: Int?, strong: Bool) -> some View {
        let r = CGRect(x: f.minX + a.minX * f.width, y: f.minY + a.minY * f.height,
                       width: max(2, a.width * f.width), height: max(2, a.height * f.height))
        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Theme.accent, lineWidth: 2)
            .background(Theme.accent.opacity(strong ? 0.12 : 0.05))
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)").font(Theme.mono(10, .bold)).foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: -6, y: -8)
                }
            }
            .opacity(strong ? 1 : 0.7)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }

    private func drawLayer(_ f: CGRect) -> some View {
        Color.black.opacity(0.18)
            .overlay(alignment: .top) {
                if draft?.rect == nil && drawStart == nil {
                    StagePill(text: "Drag over the area · or drag the timeline for a range · click for the whole frame · Esc",
                              icon: "viewfinder", accent: true)
                        .padding(.top, 16)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if drawStart == nil { drawStart = g.startLocation }
                var d = draft ?? Draft(start: clock.time)
                d.rect = Self.normal(g.startLocation, g.location, in: f)
                draft = d
            }.onEnded { g in
                drawStart = nil
                var d = draft ?? Draft(start: clock.time)
                let r = Self.normal(g.startLocation, g.location, in: f)
                d.rect = (r.width < 0.015 && r.height < 0.015) ? nil : r
                draft = d
                mode = false
            })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }

    static func normal(_ a: CGPoint, _ b: CGPoint, in f: CGRect) -> CGRect {
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        let x0 = clamp((min(a.x, b.x) - f.minX) / f.width), x1 = clamp((max(a.x, b.x) - f.minX) / f.width)
        let y0 = clamp((min(a.y, b.y) - f.minY) / f.height), y1 = clamp((max(a.y, b.y) - f.minY) / f.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Card

    @ViewBuilder private var card: some View {
        if draft != nil, !mode {
            Composer(draft: Composer.bind($draft, Draft()),
                     onSend: send, onCancel: cancel,
                     onArea: { mode = true })
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let id = focused, let i = comments.firstIndex(where: { $0.id == id }) {
            CommentCard(comment: comments[i], number: i + 1,
                        onEdit: { store.setText(id, $0) },
                        onResolve: { store.setResolved(id, comments[i].open) },
                        onDelete: { store.delete(id); focused = nil },
                        onClose: { focused = nil },
                        onJump: { app.jump(to: session.appending(path: $0), at: $1) })
                .transition(.opacity)
        }
    }

    private func send() {
        guard let d = draft else { return }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = store.add(media: url, start: d.start, end: d.end, rect: d.rect, text: text)
        withAnimation(Theme.motion) { draft = nil }
        if let c { app.show(toast: "Comment \(c.id) saved for Takes") }
    }

    private func cancel() {
        withAnimation(Theme.motion) {
            if mode { mode = false } else if draft != nil { draft = nil } else { focused = nil }
        }
    }

    private func focus(_ c: Comment) {
        clock.player.pause()
        draft = nil
        mode = false
        if let s = c.start { clock.seek(s) }
        withAnimation(Theme.motion) { focused = c.id }
    }
}

/// The comment mode and the clock of the review player in the post preview. AppModel sends the
/// keys (C, Esc, Space, ←/→) here while the post view is open, as the stage does for its player.
@MainActor
final class PostReview: ObservableObject {
    @Published var mode = false
    weak var clock: PlayerClock?
}

/// Area comments that show while the playhead is in their range. Watches the playhead itself.
private struct TimedAreas: View {
    @ObservedObject var head: Playhead
    let comments: [Comment]
    let frame: CGRect
    let focused: String?
    let hidden: Bool
    let onFocus: (Comment) -> Void

    var body: some View {
        ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
            if let a = c.area, visible(c) {
                ReviewPlayer.areaBox(a, in: frame, number: i + 1, strong: focused == c.id)
                    .onTapGesture { onFocus(c) }
            }
        }
    }

    private func visible(_ c: Comment) -> Bool {
        if focused == c.id { return true }
        guard c.open, !hidden, let s = c.start else { return false }
        let e = max(c.end ?? s, s + 1.5)
        return head.time >= s - 0.05 && head.time <= e
    }
}

/// Ends typing in the script, so Space and the arrow keys reach the video.
@MainActor func releaseKeys() {
    if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
}

/// The video layer, with no controls of its own. ReviewBar is the control.
/// Shrinks a little while pressed.
struct PressScale: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : hover ? 1.06 : 1)
            .onHover { hover = $0 }
            .animation(Theme.spring, value: configuration.isPressed)
            .animation(Theme.spring, value: hover)
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.player = player
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

// MARK: - Timeline

struct ReviewBar: View {
    @Environment(AppModel.self) var app
    @ObservedObject var clock: PlayerClock
    /// Not observed here: only the time label and the playhead watch it (10–30 times a second),
    /// not the whole bar with its markers and buttons.
    let head: Playhead
    let url: URL
    let comments: [Comment]
    @Binding var draft: ReviewPlayer.Draft?
    let focused: String?
    @Binding var commentMode: Bool
    /// In the post preview: no save-frame or close.
    var embedded = false
    /// A narrow video: no time label, the comment button as an icon.
    var compact = false
    /// True while a drag scrubs or picks a range: the controls stay on.
    @Binding var scrubbing: Bool
    let onRange: (Double, Double?) -> Void
    var voice: VoiceMix?
    /// A vertical video's safe-zone button: the pinned setting, and the hover that shows it.
    var safeZone: Binding<Bool>? = nil
    var onSafePeek: (Bool) -> Void = { _ in }
    let onFocus: (Comment) -> Void
    let onComment: () -> Void
    @State private var dragFrom: Double?
    @State private var dragTo: Double?
    @State private var hoverX: CGFloat?
    /// This drag picks a range to comment on (C first, or ⌥). A plain drag only scrubs.
    @State private var ranging = false
    @State private var resumeAfter = false
    @State private var trackHover = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            // Takes the keys back from the chat box too, so Space plays after this click.
            Button { releaseKeys(); clock.toggle() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(PressScale()).foregroundStyle(.white)
            .help("Play or pause (Space). ←/→ one frame, ⇧←/→ one second.")
            if !compact {
                PlayheadStamp(head: head, duration: clock.duration)
                    .font(Theme.mono(11, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85)).fixedSize()
            }
            GeometryReader { geo in timeline(geo.size.width) }
                .frame(height: 30)
                .frame(minWidth: 60)
            HStack(spacing: 4) {
                if let voice { VoiceButton(voice: voice) }
                if let safeZone { SafeZoneButton(pinned: safeZone, onPeek: onSafePeek) }
                Button(action: onComment) {
                    HStack(spacing: 5) {
                        Image(systemName: commentMode ? "xmark" : "text.bubble.fill")
                            .contentTransition(.symbolEffect(.replace))
                        if openCount > 0 && !commentMode { Text("\(openCount)").monospacedDigit() }
                    }
                    .font(Theme.sans(12, .semibold))
                    .padding(.horizontal, openCount > 0 && !commentMode ? 11 : 0)
                    .frame(minWidth: 30, minHeight: 30)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(PressScale())
                .help("Comment (C): then drag on the frame for an area, or on the timeline for a range. ⌥-drag the timeline for a range at once.")
                if !embedded { barIcon("xmark", app.camera.paused ? "Close the video" : "Back to the live camera") { app.preview = nil } }
            }
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    private var openCount: Int { comments.filter(\.open).count }

    private func barIcon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(BarIconStyle()).help(help)
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        clock.duration > 0 ? CGFloat(t / clock.duration) * w : 0
    }

    private func t(_ x: CGFloat, _ w: CGFloat) -> Double {
        w > 0 ? max(0, min(clock.duration, Double(x / w) * clock.duration)) : 0
    }

    private func timeline(_ w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // track: thicker under the pointer
            Capsule().fill(commentMode ? Theme.accent.opacity(0.45) : .white.opacity(0.2)).frame(height: thick)
            PlayheadMark(head: head, duration: clock.duration, width: w, progress: true, height: thick)
            // a range being dragged, or the draft's range
            if let (a, b) = selection, b > a {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accent, lineWidth: 1))
                    .frame(width: max(2, x(b, w) - x(a, w)), height: 14)
                    .offset(x: x(a, w))
            }
            // playhead
            PlayheadMark(head: head, duration: clock.duration, width: w, progress: false, knob: trackHover || dragFrom != nil)
            if let hoverX, dragFrom == nil {
                Text(Comment.stamp(t(hoverX, w))).font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
                    .fixedSize().offset(x: min(max(0, hoverX - 20), w - 44), y: -22)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            if dragFrom == nil {
                scrubbing = true
                dragFrom = t(g.startLocation.x, w)
                releaseKeys()
                ranging = Self.picksRange(commentMode: commentMode, modifiers: NSEvent.modifierFlags)
                // Scrub like any player: hold still while dragging, play on after.
                resumeAfter = !ranging && clock.playing
                clock.player.pause()
            }
            if ranging, abs(g.translation.width) > 3 { dragTo = t(g.location.x, w) }
            clock.seek(t(g.location.x, w))
        }.onEnded { g in
            let from = dragFrom ?? t(g.startLocation.x, w)
            let to = dragTo
            let range = ranging
            dragFrom = nil; dragTo = nil; ranging = false; scrubbing = false
            if range, let to, abs(to - from) >= 0.1 {
                let (a, b) = (min(from, to), max(from, to))
                clock.seek(a)
                commentMode = false
                onRange(a, b)
            } else {
                clock.seek(t(g.location.x, w))
                if resumeAfter { clock.player.play() }
            }
            resumeAfter = false
        })
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x; if !trackHover { trackHover = true } } else { hoverX = nil; trackHover = false }
        }
        .animation(Theme.motion, value: trackHover)
        .overlay(alignment: .topLeading) { markers(w) }
    }

    private var thick: CGFloat { trackHover || dragFrom != nil ? 6 : 4 }

    /// A timeline drag picks a range only in comment mode (C) or with ⌥. Otherwise it scrubs.
    nonisolated static func picksRange(commentMode: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        commentMode || modifiers.contains(.option)
    }

    private var selection: (Double, Double)? {
        if let dragFrom, let dragTo { return (min(dragFrom, dragTo), max(dragFrom, dragTo)) }
        if let d = draft, let s = d.start, let e = d.end { return (s, e) }
        return nil
    }

    /// Comment marks above the track. Click one to jump to it.
    private func markers(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                if let s = c.start {
                    let e = c.end ?? s
                    let width = max(8, x(e, w) - x(s, w))
                    let on = focused == c.id
                    RoundedRectangle(cornerRadius: 2)
                        .fill(c.open ? Theme.accent : Color.white.opacity(0.3))
                        .frame(width: width, height: on ? 6 : 4)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .offset(x: min(x(s, w) - (e > s ? 0 : 4), w - width))
                        .onTapGesture { onFocus(c) }
                        .help("\(i + 1) · \(c.timeLabel) · \(c.text)")
                }
            }
        }
        .frame(width: w, height: 10, alignment: .topLeading)
        .offset(y: -1)
    }
}

/// "0:12 / 1:04": redraws with the playhead, alone.
struct PlayheadStamp: View {
    @ObservedObject var head: Playhead
    let duration: Double
    var body: some View { Text("\(Comment.stamp(head.time)) / \(SessionDoc.clock(duration))") }
}

/// The played part of the track, or the playhead: a thin line, or a round knob under the pointer.
struct PlayheadMark: View {
    @ObservedObject var head: Playhead
    let duration: Double
    let width: CGFloat
    let progress: Bool
    var height: CGFloat = 4
    var knob = false

    var body: some View {
        let x = duration > 0 ? CGFloat(head.time / duration) * width : 0
        if progress {
            Capsule().fill(.white.opacity(0.85)).frame(width: max(0, x), height: height)
        } else if knob {
            Circle().fill(.white).frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .offset(x: x - 6.5)
                .transition(.scale.combined(with: .opacity))
        } else {
            Capsule().fill(.white).frame(width: 3, height: 12).offset(x: x - 1.5)
        }
    }
}

/// A round icon button on the dark bar: brighter with a soft fill on hover.
/// Shows the safe zone while the pointer is on it; a click keeps it on for every vertical video.
struct SafeZoneButton: View {
    @Binding var pinned: Bool
    let onPeek: (Bool) -> Void

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 13, weight: pinned ? .bold : .medium))
                .foregroundStyle(pinned ? Theme.accent : .white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(BarIconStyle())
        .onHover(perform: onPeek)
        .onDisappear { onPeek(false) }
        .help(pinned ? "Safe zone on: click to hide it" : "Safe zone for TikTok, Reels and Shorts: hover to see it, click to keep it on")
    }
}

struct BarIconStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
            .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
    }
}

// MARK: - Cards

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(width: 340, alignment: .leading)
            .background(Theme.stage.opacity(0.94), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

private struct Chip: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct Composer: View {
    @Binding var draft: ReviewPlayer.Draft
    let onSend: () -> Void
    let onCancel: () -> Void
    let onArea: () -> Void
    /// False where a comment cannot mark an area (a whole text).
    var areas = true
    @FocusState private var typing: Bool

    /// The draft for the composer. After a send clears it, the text field can still write its
    /// text back once as it loses focus. That write must not open the composer again.
    static func bind(_ draft: Binding<ReviewPlayer.Draft?>, _ fallback: ReviewPlayer.Draft) -> Binding<ReviewPlayer.Draft> {
        Binding(get: { draft.wrappedValue ?? fallback },
                set: { if draft.wrappedValue != nil { draft.wrappedValue = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let q = draft.quote {
                    Chip(text: "“\(q.prefix(40))\(q.count > 40 ? "…" : "")”", icon: "text.quote")
                } else if draft.timed {
                    Chip(text: Comment.label(draft.start, draft.end), icon: "clock")
                }
                if draft.quote != nil {
                    EmptyView()
                } else if draft.rect != nil {
                    Button { draft.rect = nil } label: { Chip(text: "area ✕", icon: "viewfinder") }
                        .buttonStyle(.plain).help("Remove the area")
                } else if areas {
                    Button(action: onArea) {
                        Text("+ area").font(Theme.mono(10.5)).foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain).help("Mark an area on the frame")
                }
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).help("Cancel (Esc)")
            }
            HStack(spacing: 8) {
                TextField("What should change?", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.sans(13.5)).foregroundStyle(.white)
                    .lineLimit(1...5)
                    .focused($typing)
                    .onSubmit(onSend)
                    .onExitCommand(perform: onCancel)
                Image(systemName: "return").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(draft.text.isEmpty ? .white.opacity(0.25) : Theme.accent)
            }
        }
        .modifier(CardStyle())
        // Ask again once the card is in the window: in the active window a request made while the
        // card is still being inserted can fail, and the window then gives the keyboard to its
        // first text field, the session title (2026-09-30).
        .onAppear {
            typing = true
            DispatchQueue.main.async { typing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { typing = true }
        }
    }
}

struct CommentCard: View {
    let comment: Comment
    let number: Int
    let onEdit: (String) -> Void
    let onResolve: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    var onJump: ((String, Double?) -> Void)? = nil
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(number)").font(Theme.mono(10, .bold)).foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(comment.open ? Theme.accent : Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                Text(comment.start != nil ? comment.timeLabel : comment.quote != nil ? "text" : "image")
                    .font(Theme.mono(10.5)).foregroundStyle(.white.opacity(0.55))
                if !comment.open {
                    Text("resolved").font(Theme.mono(10.5)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                icon(comment.open ? "checkmark.circle" : "arrow.uturn.backward.circle",
                     comment.open ? "Resolve" : "Reopen", onResolve)
                icon("trash", "Delete", onDelete)
                icon("xmark", "Close (Esc)", onClose)
            }
            if let q = comment.quote {
                Text("“\(q)”").font(Theme.sans(12.5).italic()).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3).padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            // Click the text to change it: Return or clicking away saves, Esc puts it back.
            TextField("What should change?", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.sans(13.5))
                .foregroundStyle(.white.opacity(comment.open || editing ? 0.95 : 0.55))
                .lineLimit(1...8)
                .focused($editing)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.white.opacity(editing ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, -5).padding(.vertical, -3)
                .onSubmit(save)
                .onExitCommand { text = comment.text; editing = false; onClose() }
                .onChange(of: editing) { _, now in if !now { save() } }
                .onChange(of: comment.text, initial: true) { _, t in if !editing { text = t } }
                .help("Click to edit")
            ForEach(Array((comment.replies ?? []).enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(r.by == "user" ? "you" : r.by).font(Theme.mono(10, .medium))
                        .foregroundStyle(r.by == "user" ? .white.opacity(0.45) : Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        if !r.text.isEmpty {
                            Text(r.text).font(Theme.sans(12.5)).foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        if let link = r.link, let file = r.file {
                            Button { onJump?(file, r.time) } label: {
                                Label(link, systemImage: "arrow.right.circle")
                                    .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .disabled(onJump == nil)
                            .help("Show the fix in \(file)")
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .modifier(CardStyle())
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { text = comment.text } else if t != comment.text { onEdit(t) }
        editing = false
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help(help)
    }
}


// MARK: - Stills

/// A still with the same area comments as a video, and no timeline.
struct StillReview: View {
    @Environment(AppModel.self) var app
    let url: URL
    let session: URL
    @StateObject private var store = CommentStore()
    @State private var image: NSImage?
    @State private var draft: ReviewPlayer.Draft?
    @State private var focused: String?

    private var comments: [Comment] { store.on(CommentStore.path(of: url, in: session)) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = image.map { img -> CGSize in
                    // SVGs have no pixel size: use the point size.
                    guard let rep = img.representations.first, rep.pixelsWide > 0 else { return img.size }
                    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                } ?? .zero
                let frame = ReviewPlayer.fit(size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture { releaseKeys(); withAnimation(Theme.motion) { focused = nil } }
                    }
                    if draft == nil && !app.commentMode {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                            if let a = c.area, c.open || focused == c.id {
                                ReviewPlayer.areaBox(a, in: frame, number: i + 1, strong: focused == c.id)
                                    .onTapGesture { withAnimation(Theme.motion) { focused = c.id } }
                            }
                        }
                    }
                    if let a = draft?.rect {
                        ReviewPlayer.areaBox(a, in: frame, number: nil, strong: true).allowsHitTesting(false)
                    }
                    if app.commentMode { drawLayer(frame) }
                }
                .overlay(alignment: .bottomLeading) { card.padding(12) }
            }
            .clipped()
            bar
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
        .onAppear { releaseKeys(); store.load(session) }
        .onDisappear { app.commentMode = false }
        .onFilesChanged(in: session) { store.load(session) }
        .onChange(of: app.commentMode) { _, on in if on { focused = nil } }
    }

    private func drawLayer(_ f: CGRect) -> some View {
        Color.black.opacity(0.18)
            .overlay(alignment: .top) {
                if draft?.rect == nil {
                    StagePill(text: "Drag over the area · click for the whole image · Esc", icon: "viewfinder", accent: true)
                        .padding(.top, 16)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var d = draft ?? ReviewPlayer.Draft(timed: false)
                d.rect = ReviewPlayer.normal(g.startLocation, g.location, in: f)
                draft = d
            }.onEnded { g in
                var d = draft ?? ReviewPlayer.Draft(timed: false)
                let r = ReviewPlayer.normal(g.startLocation, g.location, in: f)
                d.rect = (r.width < 0.015 && r.height < 0.015) ? nil : r
                draft = d
                app.commentMode = false
            })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }

    @ViewBuilder private var card: some View {
        if draft != nil, !app.commentMode {
            Composer(draft: Composer.bind($draft, ReviewPlayer.Draft(timed: false)),
                     onSend: send, onCancel: { withAnimation(Theme.motion) { draft = nil } },
                     onArea: { app.commentMode = true })
        } else if let id = focused, let i = comments.firstIndex(where: { $0.id == id }) {
            CommentCard(comment: comments[i], number: i + 1,
                        onEdit: { store.setText(id, $0) },
                        onResolve: { store.setResolved(id, comments[i].open) },
                        onDelete: { store.delete(id); focused = nil },
                        onClose: { focused = nil },
                        onJump: { app.jump(to: session.appending(path: $0), at: $1) })
        }
    }

    private func send() {
        guard let d = draft else { return }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let c = store.add(media: url, rect: d.rect, text: text)
        withAnimation(Theme.motion) { draft = nil }
        if let c { app.show(toast: "Comment \(c.id) saved for Takes") }
    }

    private var bar: some View {
        let open = comments.filter(\.open)
        return HStack(spacing: 12) {
            Text(url.lastPathComponent).font(Theme.mono(10.5, .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.middle).help(url.path)
            Spacer()
            // Resolved comments stay reachable from here.
            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                Button { withAnimation(Theme.motion) { draft = nil; focused = c.id } } label: {
                    Text("\(i + 1)").font(Theme.mono(10, .bold)).foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(c.open ? Theme.accent : Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain).help(c.text)
            }
            Button { app.commentMode.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                    Text(open.isEmpty ? "Comment" : "\(open.count)")
                }
                .font(Theme.mono(11, .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radius))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain).help("Mark an area on the image (C)")
            Button { app.preview = nil } label: {
                Image(systemName: "xmark").font(.system(size: 13)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            .help(app.camera.paused ? "Close the image" : "Back to the live camera")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.stage)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
}

// MARK: - Glass player

/// A plain video with the review player's look, for places without comments (the chat): the
/// video in its frame, a big play button while paused, and a glass bar that hides while it plays.
struct GlassPlayer: View {
    let url: URL
    var autoplay = true
    /// Shows an "open in Takes" button on the bar.
    var onOpen: (() -> Void)?
    @StateObject private var clock: PlayerClock
    @State private var chrome = true
    @State private var hideChrome: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var trackHover = false
    @State private var hoverX: CGFloat?
    @State private var muted = false

    init(url: URL, autoplay: Bool = true, onOpen: (() -> Void)? = nil) {
        self.url = url
        self.autoplay = autoplay
        self.onOpen = onOpen
        _clock = StateObject(wrappedValue: PlayerClock(url: url))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlayerLayerView(player: clock.player).allowsHitTesting(false)
                Color.clear.contentShape(Rectangle()).onTapGesture { clock.toggle(); wake() }
                if !clock.playing && clock.duration > 0 {
                    Button { clock.toggle() } label: { GlassPlayButton(size: geo.size.width < 260 ? 48 : 60) }
                        .buttonStyle(PressScale())
                        .help("Play")
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if chrome || !clock.playing || scrubbing {
                    bar(compact: geo.size.width < 300)
                        .padding(geo.size.width < 300 ? 6 : 10)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { wake() } else { sleepSoon(after: 0.6) }
        }
        .animation(Theme.motion, value: chrome)
        .animation(Theme.spring, value: clock.playing)
        .onChange(of: clock.playing) { _, on in if on { sleepSoon() } else { chrome = true } }
        .onAppear { if autoplay { clock.player.play() } }
        .onDisappear { clock.stop() }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Button { clock.toggle() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(PressScale()).foregroundStyle(.white)
            if !compact {
                PlayheadStamp(head: clock.head, duration: clock.duration)
                    .font(Theme.mono(10.5, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85)).fixedSize()
            }
            GeometryReader { g in track(g.size.width) }.frame(height: 26).frame(minWidth: 40)
            Button { muted.toggle(); clock.player.isMuted = muted } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Circle())
            }
            .buttonStyle(BarIconStyle()).help(muted ? "Sound on" : "Sound off")
            if let onOpen, !compact {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(BarIconStyle()).help("Open it in Takes")
            }
        }
        .padding(.leading, 5).padding(.trailing, 6).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func track(_ w: CGFloat) -> some View {
        let thick: CGFloat = trackHover || scrubbing ? 6 : 4
        func t(_ x: CGFloat) -> Double { w > 0 ? max(0, min(clock.duration, Double(x / w) * clock.duration)) : 0 }
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2)).frame(height: thick)
            PlayheadMark(head: clock.head, duration: clock.duration, width: w, progress: true, height: thick)
            PlayheadMark(head: clock.head, duration: clock.duration, width: w, progress: false, knob: trackHover || scrubbing)
            if let hoverX, !scrubbing {
                Text(Comment.stamp(t(hoverX))).font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: Capsule())
                    .fixedSize().offset(x: min(max(0, hoverX - 20), w - 44), y: -20)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: 26)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            if !scrubbing { scrubbing = true }
            clock.seek(t(g.location.x))
        }.onEnded { g in
            clock.seek(t(g.location.x))
            scrubbing = false
        })
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverX = p.x; if !trackHover { trackHover = true } } else { hoverX = nil; trackHover = false }
        }
        .animation(Theme.motion, value: trackHover)
    }

    private func wake() {
        if !chrome { chrome = true }
        sleepSoon()
    }

    private func sleepSoon(after secs: Double = 2) {
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled { chrome = false }
        }
    }
}

/// The round frosted play button of the players.
struct GlassPlayButton: View {
    var size: CGFloat = 64
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.37, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: size * 0.03)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
