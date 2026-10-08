import Combine
import AVFoundation
import SwiftUI
import UIKit

// Review comments on a video or picture of the session, as on the Mac's review player
// (Comments.swift there). Tap Comment, then drag on the picture to mark an area, or drag on the
// timeline to pick a range; a tap on the picture means the whole frame. The comment lands in the
// session's comments.json with a frame PNG, and Claude reads it there (MCP get_comments).

/// What a new comment points at, before it has text.
struct MediaDraft: Identifiable {
    var start: Double?
    var end: Double?
    var rect: CGRect?
    var id: String { "\(start ?? -1)-\(end ?? -1)-\(rect.map { "\($0)" } ?? "")" }
}

@MainActor
final class ReviewTicker: ObservableObject {
    @Published var time: Double = 0
}

/// Redraws its content each time the ticker moves.
struct Ticking<Content: View>: View {
    @ObservedObject var ticker: ReviewTicker
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// The player for the review: its time, length and picture size, for the timeline and the areas.
@MainActor
final class ReviewClock: ObservableObject {
    let player = AVPlayer()
    /// The playhead, 30 times a second, in its own object: only the timeline watches it.
    let ticker = ReviewTicker()
    var time: Double {
        get { ticker.time }
        set { if ticker.time != newValue { ticker.time = newValue } }
    }
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var size: CGSize = .zero
    /// The video can show its first frame: the poster under it goes.
    @Published var ready = false
    private var clock: Any?
    private var watch: NSKeyValueObservation?
    private var status: NSKeyValueObservation?
    private var url: URL?
    /// Scrubbing: one seek at a time, and the newest place waits (a "chase" seek).
    private var seeking = false
    private var next: Double?

    func start(_ url: URL, known: Double?) {
        guard self.url != url else { return }
        self.url = url
        if let known { duration = known }
        let item = AVPlayerItem(url: url)
        status = item.observe(\.status) { [weak self] it, _ in
            let ok = it.status == .readyToPlay
            Task { @MainActor in if ok, self?.ready == false { self?.ready = true } }
        }
        player.replaceCurrentItem(with: item)
        AVAudioSession.sharedInstance().use(.playback)
        watch = player.observe(\.timeControlStatus) { [weak self] pl, _ in
            let on = pl.timeControlStatus != .paused
            Task { @MainActor in self?.playing = on }
        }
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, d != self.duration { self.duration = d }
            }
        }
        Task {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, turn) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = natural.applying(turn)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
        }
    }

    func toggle() {
        if playing { player.pause(); return }
        if duration > 0 && time >= duration - 0.05 { seek(0) }
        player.play()
    }

    func seek(_ s: Double) {
        let t = max(0, min(duration > 0 ? duration : s, s))
        time = t
        next = nil
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// While a finger drags the timeline: exact seeks queued up and the picture lagged behind the
    /// finger. Now a new seek starts only when the last one is done, near enough (2026-10-08).
    func scrub(_ s: Double) {
        let t = max(0, min(duration > 0 ? duration : s, s))
        time = t
        guard !seeking else { next = t; return }
        seeking = true
        let near = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: near, toleranceAfter: near) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let n = self.next { self.next = nil; self.scrub(n) }
            }
        }
    }

    func stop() { player.pause() }

    deinit { if let clock { player.removeTimeObserver(clock) } }
}

struct MediaReview: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    /// The file's path inside the session, as comments.json names it.
    let rel: String
    let sessionID: String
    @StateObject private var clock = ReviewClock()
    @State private var image: UIImage?
    @State private var comments: [Comment] = []
    /// Drawing: a drag on the picture marks an area, a drag on the timeline picks a range.
    @State private var marking = false
    @State private var draft: MediaDraft?
    @State private var composing: MediaDraft?
    @State private var drawing: CGRect?
    @State private var focused: String?
    @State private var showResolved = false
    /// The playhead to a quarter second: enough for the comment boxes, 4 redraws a second.
    @State private var now: Double = 0
    /// The TikTok, Reels and Shorts safe zone over a vertical video, as on the Mac. Remembered.
    @AppStorage("safeZone") private var safeZone = false
    private var vertical: Bool { file.isVideo && SafeZone.fits(size) }

    private var mine: [Comment] { comments.filter { $0.file == rel } }
    private var open: [Comment] { mine.filter(\.open) }
    private var size: CGSize { file.isVideo ? clock.size : (image?.size ?? .zero) }

    var body: some View {
        VStack(spacing: 0) {
            stage
            if file.isVideo {
                Ticking(ticker: clock.ticker) {
                    ReviewTimeline(clock: clock, comments: mine, focused: focused, marking: $marking,
                                   range: draft.flatMap { d in d.start.flatMap { s in d.end.map { (s, $0) } } },
                                   onRange: { a, b in pick(start: a, end: b, rect: draft?.rect) },
                                   onFocus: focus)
                }
            }
            bar
            list
        }
        .onReceive(clock.ticker.$time.map { ($0 * 4).rounded() / 4 }.removeDuplicates()) { now = $0 }
        .background(Color.black)
        .task(id: file.path) {
            await load()
            // Claude answers on the Mac: show its replies while the review is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if let c = await model.comments(sessionID), c != comments { comments = c }
            }
        }
        .onAppear { if file.isVideo { clock.start(model.api.media(file.path), known: file.duration); clock.player.play() } }
        .onDisappear { clock.stop() }
        .onChange(of: marking) { _, on in if on { clock.player.pause(); focused = nil } }
        .sheet(item: $composing) { d in
            NewComment(quote: nil, what: file.isVideo ? "video" : "picture", place: place(d), more: more(d)) { text in
                guard let c = await model.comment(sessionID, media: rel, start: d.start, end: d.end, rect: d.rect, text: text)
                else { return false }
                comments.append(c)
                draft = nil
                focused = c.id
                return true
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Picture

    private var stage: some View {
        GeometryReader { geo in
            let f = Self.fit(size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Group {
                    if file.isVideo {
                        ZStack {
                            // The thumbnail already seen, until the first frame: no black wait.
                            if !clock.ready, let poster {
                                Image(uiImage: poster).resizable().scaledToFit().transition(.opacity)
                            }
                            ReviewLayer(player: clock.player)
                        }
                        .animation(.easeOut(duration: 0.15), value: clock.ready)
                    } else if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { if file.isVideo { clock.toggle() } }
                // A long press: a comment on this moment and the whole frame, without the steps.
                .onLongPressGesture(minimumDuration: 0.45) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    pick(start: nil, end: nil, rect: nil)
                }
                ForEach(Array(mine.enumerated()), id: \.element.id) { i, c in
                    if let a = c.area, visible(c) {
                        AreaBox(rect: a, in: f, number: i + 1, strong: focused == c.id)
                            .onTapGesture { focus(c) }
                    }
                }
                if safeZone && vertical && !marking { SafeZoneOverlay(frame: f).transition(.opacity) }
                if let a = drawing ?? draft?.rect { AreaBox(rect: a, in: f, number: nil, strong: true).allowsHitTesting(false) }
                if marking { drawLayer(f) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .layoutPriority(1)
        .clipped()
    }

    private func drawLayer(_ f: CGRect) -> some View {
        Color.black.opacity(0.2)
            .overlay(alignment: .top) {
                if drawing == nil {
                    Text(file.isVideo ? "Drag over the area · or drag the timeline for a range · tap for the whole frame"
                                      : "Drag over the area · tap for the whole picture")
                        .font(.inter(.caption, .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Palette.accent, in: Capsule())
                        .padding(12)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { g in
                drawing = Self.normal(g.startLocation, g.location, in: f)
            }.onEnded { g in
                drawing = nil
                let r = Self.normal(g.startLocation, g.location, in: f)
                let area: CGRect? = (r.width < 0.015 && r.height < 0.015) ? nil : r
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                pick(start: draft?.start, end: draft?.end, rect: area)
            })
    }

    private func visible(_ c: Comment) -> Bool {
        if focused == c.id { return true }
        guard c.open, !marking, draft == nil else { return false }
        guard file.isVideo, let s = c.start else { return true }
        let e = max(c.end ?? s, s + 1.5)
        return now >= s - 0.05 && now <= e
    }

    // MARK: Bar and list

    private var bar: some View {
        HStack {
            if marking {
                Button("Cancel") { marking = false; draft = nil }.foregroundStyle(.white)
            } else {
                Text(open.isEmpty ? "No open comments" : "\(open.count) open")
                    .font(.inter(.footnote)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if vertical && !marking {
                Button { withAnimation(.snappy) { safeZone.toggle() } } label: {
                    Image(systemName: safeZone ? "rectangle.inset.filled" : "rectangle.dashed")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(safeZone ? Palette.accent.opacity(0.25) : Color.white.opacity(0.12), in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(safeZone ? "Hide the safe zone" : "Show the safe zone for TikTok, Reels and Shorts")
            }
            Button { marking.toggle() } label: {
                Label(marking ? "Marking…" : "Comment", systemImage: "text.bubble")
                    .font(.inter(.subheadline, .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Palette.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .accessibilityHint("Then drag on the picture for an area, or on the timeline for a range.")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if mine.count > open.count {
                        HStack {
                            Spacer()
                            Button(showResolved ? "Hide resolved" : "Show resolved") { showResolved.toggle() }.font(.inter(.caption))
                        }
                    }
                    ForEach(mine.filter { $0.open || showResolved || $0.id == focused }) { c in
                        CommentCard(comment: c, sessionID: sessionID) { await load() }
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: focused == c.id ? 2 : 0))
                            .contentShape(Rectangle())
                            .onTapGesture { focus(c) }
                            .id(c.id)
                    }
                    if mine.isEmpty {
                        Text("Tap Comment, or hold on the picture, to say what should change. Takes reads it on the Mac.")
                            .font(.inter(.footnote)).foregroundStyle(.white.opacity(0.55)).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .frame(maxHeight: mine.isEmpty ? 60 : 280)
            .onChange(of: focused) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        }
    }

    // MARK: Actions

    private func pick(start: Double?, end: Double?, rect: CGRect?) {
        marking = false
        clock.player.pause()
        let d = MediaDraft(start: file.isVideo ? (start ?? clock.time) : nil, end: end, rect: rect)
        draft = d
        composing = d
    }

    private func place(_ d: MediaDraft) -> String {
        var parts: [String] = []
        if let s = d.start { parts.append(Comment.label(s, d.end)) }
        parts.append(d.rect == nil ? (file.isVideo ? "whole frame" : "whole picture") : "area")
        return parts.joined(separator: " · ")
    }

    /// From the sheet: go back and add an area, or a range, to the draft.
    private func more(_ d: MediaDraft) -> [(String, String, () -> Void)] {
        var m: [(String, String, () -> Void)] = []
        if d.rect == nil { m.append(("Mark an area", "viewfinder", { draft = d; marking = true })) }
        if file.isVideo && d.end == nil { m.append(("Pick a range on the timeline", "arrow.left.and.right", { draft = d; marking = true })) }
        return m
    }

    private func focus(_ c: Comment) {
        clock.player.pause()
        marking = false
        draft = nil
        if let s = c.start { clock.seek(s) }
        withAnimation(.snappy) { focused = c.id }
    }

    private func load() async {
        // A picture shows its thumbnail at once, then the full one, sized for the screen and
        // decoded off the main thread, from the phone's cache when it has it (2026-10-08).
        if file.isImage, image == nil { image = poster }
        if file.isImage {
            Task {
                if let full = await ImageCache.shared.load(model.api.media(file.path), maxPixels: 2400) { image = full }
            }
        }
        if let c = await model.comments(sessionID) { comments = c }
    }

    /// The biggest thumbnail of this file already in memory (the list, chat and post use these sizes).
    private var poster: UIImage? {
        for w in [1600, 900, 720, 400, 300, 200, 160] {
            if let i = ImageCache.shared.memory(model.api.thumb(file.path, width: w)) { return i }
        }
        return nil
    }

    // MARK: Geometry

    /// Where an aspect-fit picture sits inside `box`.
    static func fit(_ media: CGSize, in box: CGSize) -> CGRect {
        guard media.width > 0, media.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / media.width, box.height / media.height)
        let w = media.width * s, h = media.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// Two points as x, y, w, h fractions of the picture, from the top left.
    static func normal(_ a: CGPoint, _ b: CGPoint, in f: CGRect) -> CGRect {
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        let x0 = clamp((min(a.x, b.x) - f.minX) / f.width), x1 = clamp((max(a.x, b.x) - f.minX) / f.width)
        let y0 = clamp((min(a.y, b.y) - f.minY) / f.height), y1 = clamp((max(a.y, b.y) - f.minY) / f.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A marked area, numbered like the comment list.
struct AreaBox: View {
    let rect: CGRect
    let `in`: CGRect
    let number: Int?
    let strong: Bool

    var body: some View {
        let f = `in`
        let r = CGRect(x: f.minX + rect.minX * f.width, y: f.minY + rect.minY * f.height,
                       width: max(2, rect.width * f.width), height: max(2, rect.height * f.height))
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Palette.accent, lineWidth: 2)
            .background(Palette.accent.opacity(strong ? 0.14 : 0.06))
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)").font(.caption2.monospacedDigit().weight(.bold)).foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: -7, y: -9)
                }
            }
            .opacity(strong ? 1 : 0.75)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }
}

/// Play, the time, and a timeline with a mark per comment. Drag to scrub; in comment mode a drag
/// picks a range.
struct ReviewTimeline: View {
    @ObservedObject var clock: ReviewClock
    let comments: [Comment]
    let focused: String?
    @Binding var marking: Bool
    let range: (Double, Double)?
    let onRange: (Double, Double) -> Void
    let onFocus: (Comment) -> Void
    @State private var from: Double?
    @State private var to: Double?
    @State private var resume = false

    var body: some View {
        HStack(spacing: 12) {
            Button { clock.toggle() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: 28, height: 28)
            }
            .foregroundStyle(.white)
            .accessibilityLabel(clock.playing ? "Pause" : "Play")
            GeometryReader { g in track(g.size.width) }.frame(height: 36)
            Text("\(Comment.stamp(clock.time))").font(.inter(.caption).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { clock.duration > 0 ? CGFloat(t / clock.duration) * w : 0 }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { w > 0 ? max(0, min(clock.duration, Double(x / w) * clock.duration)) : 0 }

    private var shown: (Double, Double)? {
        if let from, let to { return (min(from, to), max(from, to)) }
        return range
    }

    private func track(_ w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(marking ? Palette.accent.opacity(0.5) : .white.opacity(0.18)).frame(height: 5)
            Capsule().fill(.white.opacity(0.55)).frame(width: x(clock.time, w), height: 5)
            if let (a, b) = shown, b > a {
                RoundedRectangle(cornerRadius: 3).fill(Palette.accent.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.accent, lineWidth: 1))
                    .frame(width: max(3, x(b, w) - x(a, w)), height: 18)
                    .offset(x: x(a, w))
            }
            Capsule().fill(.white).frame(width: 3, height: 18).offset(x: x(clock.time, w) - 1.5)
            ForEach(comments.filter { $0.start != nil }) { c in
                let s = c.start ?? 0, e = c.end ?? s
                let width = max(8, x(e, w) - x(s, w))
                RoundedRectangle(cornerRadius: 2)
                    .fill(c.open ? Palette.accent : Color.white.opacity(0.35))
                    .frame(width: width, height: focused == c.id ? 7 : 5)
                    .offset(x: min(max(0, x(s, w) - (e > s ? 0 : 4)), w - width), y: -12)
                    .onTapGesture { onFocus(c) }
            }
        }
        .frame(width: w, height: 36)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            if from == nil {
                from = t(g.startLocation.x, w)
                resume = !marking && clock.playing
                clock.player.pause()
            }
            if marking, abs(g.translation.width) > 4 { to = t(g.location.x, w) }
            clock.scrub(t(g.location.x, w))
        }.onEnded { g in
            let a = from ?? t(g.startLocation.x, w), b = to
            from = nil; to = nil
            if marking, let b, abs(b - a) >= 0.1 {
                clock.seek(min(a, b))
                onRange(min(a, b), max(a, b))
            } else {
                clock.seek(t(g.location.x, w))
                if resume { clock.player.play() }
            }
            resume = false
        })
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue(Comment.stamp(clock.time))
    }
}

/// An AVPlayerLayer that fits the video in its frame, as the areas expect.
struct ReviewLayer: UIViewRepresentable {
    let player: AVPlayer
    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> View {
        let v = View()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: View, context: Context) {}
}
