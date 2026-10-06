import AppKit
import SwiftUI

// The Storyboard tab (2026-10-03): the video idea as a row of sketches on a timeline, each with the
// script lines it covers. Claude writes storyboard/storyboard.json with the takes MCP
// (set_storyboard, the storyboard skill) and draws the sketches in the background, so the tab
// fills in while the user watches.

/// One shot of storyboard/storyboard.json.
struct StoryShot: Decodable, Equatable, Identifiable {
    /// Stays the same when Claude rewrites the storyboard: takes and comments point at it.
    var id = ""
    var section = Section.main
    var kind = "SHOT"
    var say = ""
    var how = ""
    var sketch = ""
    var seconds: Double?
    var image: String?
    /// A real clip instead of the sketch, a path in the session (2026-10-03). Plays muted while shown.
    var video: String?
    var error: String?
    /// A Higgsfield clip on its way (the file it lands in), and why the last one failed (2026-10-06).
    var generating: String?
    var clipError: String?

    /// The rows of the tab, top to bottom (2026-10-03).
    enum Section: String, Decodable, CaseIterable {
        case hook, main, end
        var title: String {
            switch self {
            case .hook: return "Hook"
            case .main: return "Main"
            case .end: return "End"
            }
        }
    }

    enum CodingKeys: String, CodingKey { case id, section, kind, say, how = "do", sketch, seconds, image, video, error, generating, clipError = "clip_error" }

    init(id: String = "", section: Section = .main, kind: String = "SHOT", say: String = "", seconds: Double? = nil) {
        self.id = id; self.section = section; self.kind = kind; self.say = say; self.seconds = seconds
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "SHOT"
        let sec = (try? c.decodeIfPresent(String.self, forKey: .section)) ?? nil
        section = sec.flatMap(Section.init(rawValue:)) ?? (kind == "END" ? .end : .main)
        say = try c.decodeIfPresent(String.self, forKey: .say) ?? ""
        how = try c.decodeIfPresent(String.self, forKey: .how) ?? ""
        sketch = try c.decodeIfPresent(String.self, forKey: .sketch) ?? ""
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        video = try c.decodeIfPresent(String.self, forKey: .video)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        generating = try c.decodeIfPresent(String.self, forKey: .generating)
        clipError = try c.decodeIfPresent(String.self, forKey: .clipError)
    }

    /// The given length, else the time it takes to say the lines (2.6 words a second, 2 s at least).
    var length: Double {
        if let seconds, seconds > 0 { return seconds }
        let words = say.split(whereSeparator: \.isWhitespace).count
        return max(2, Double(words) / 2.6)
    }
}

struct Storyboard: Decodable, Equatable {
    var shots: [StoryShot] = []
    /// The video's shape, "16:9", "9:16", "4:5" or "1:1" (2026-10-05). The sketches are drawn in it.
    /// Nil in a storyboard from before: 4:5, the shape those sketches have.
    var format: String?

    /// Width over height.
    var ratio: CGFloat { Self.ratio(format) }

    static func ratio(_ format: String?) -> CGFloat {
        let p = (format ?? "").split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return 4.0 / 5.0 }
        return CGFloat(p[0] / p[1])
    }

    static func folder(_ session: URL) -> URL { session.appending(path: "storyboard") }
    static func file(_ session: URL) -> URL { folder(session).appending(path: "storyboard.json") }

    /// Comments on a shot name this file and the shot's id.
    static let commentFile = "storyboard/storyboard.json"

    /// A take's name for its shot: "Hook 1: I do my bookkeeping". The section, the shot's place
    /// in it, and the first words it says, so the files sort and read without opening them.
    func takeName(for id: String) -> String? {
        guard let shot = shots.first(where: { $0.id == id }) else { return nil }
        let k = (shots.filter { $0.section == shot.section }.firstIndex { $0.id == id } ?? 0) + 1
        let words = shot.say.split { $0.isWhitespace }.prefix(4)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let what = words.isEmpty ? shot.kind.capitalized : words.joined(separator: " ")
        return "\(shot.section.title) \(k): \(what)"
    }

    static func read(_ session: URL) -> Storyboard? {
        guard let data = try? Data(contentsOf: file(session)),
              var b = try? JSONDecoder().decode(Storyboard.self, from: data) else { return nil }
        // A storyboard from before ids (2026-10-03): the MCP numbers them the same way.
        for i in b.shots.indices where b.shots[i].id.isEmpty { b.shots[i].id = "s\(i + 1)" }
        // Hook, main, end, each in the order written.
        let rank = Dictionary(uniqueKeysWithValues: StoryShot.Section.allCases.enumerated().map { ($1, $0) })
        b.shots = b.shots.enumerated().sorted { (rank[$0.1.section]!, $0.0) < (rank[$1.1.section]!, $1.0) }.map(\.1)
        return b
    }

    /// Where each shot starts, in seconds.
    var starts: [Double] {
        var t = 0.0
        return shots.map { s in defer { t += s.length }; return t }
    }

    var total: Double { shots.reduce(0) { $0 + $1.length } }

    static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}

// One shot at a time (2026-10-04): three rows of tiles, each with its lines, directions, buttons and
// comments, was too much to take in. Now a filmstrip of small sketches runs along the top and the
// chosen shot fills the page: the sketch, the line to say, one Record button. The directions fold away.
struct StoryboardPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var shown
    var doc: SessionDoc
    @State private var board: Storyboard?
    @State private var stamp: Date?
    @State private var images: [String: NSImage] = [:]
    @State private var picked: String?
    @StateObject private var comments = CommentStore()
    @FocusState private var stripFocus: Bool
    @Namespace private var ns

    /// Preloaded: the load task stays off.
    private var still = false

    init(doc: SessionDoc) { self.doc = doc }

    /// With the storyboard already read: snapshot tests, where the load task does not run.
    init(doc: SessionDoc, board: Storyboard, images: [String: NSImage]) {
        self.doc = doc
        _board = State(initialValue: board)
        _images = State(initialValue: images)
        still = true
    }

    /// The cache size of a sketch: twice the width of a big frame on a normal window.
    static let tileWidth: CGFloat = 300

    var body: some View {
        let _ = Perf.body("StoryboardPane")
        Group {
            if let board, !board.shots.isEmpty {
                let shot = current(board)
                VStack(alignment: .leading, spacing: 0) {
                    header(board)
                    strip(board, shot: shot)
                    if let shot {
                        let i = board.shots.firstIndex(of: shot) ?? 0
                        ShotDetail(doc: doc, shot: shot, number: i + 1, count: board.shots.count,
                                   start: board.starts[i], ratio: board.ratio, image: shot.image.flatMap { images[$0] },
                                   takes: takes[shot.id] ?? [],
                                   comments: comments.all.filter { $0.shot == shot.id }, store: comments,
                                   step: { step(board, $0) })
                            .id(shot.id)
                            // A new shot blurs in, the old one blurs out (a picked shot animates).
                            .transition(.blurReplace)
                    }
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: doc.url) {
            guard !still else { return }
            stamp = nil; board = nil; images = [:]; picked = nil
            // Sketches land one by one while the tab is open: a stat every 1.5 s costs nothing.
            while !Task.isCancelled {
                if shown { await reload(); comments.load(doc.url) }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// The camera takes filed under each shot, oldest first.
    private var takes: [String: [Take]] {
        Dictionary(grouping: doc.meta.takes.filter { $0.kind == .camera && $0.shot != nil }, by: { $0.shot! })
            .mapValues { $0.sorted { $0.number < $1.number } }
    }

    /// The shot the user picked, else the first one with no take yet: where he left off.
    private func current(_ b: Storyboard) -> StoryShot? {
        if let picked, let s = b.shots.first(where: { $0.id == picked }) { return s }
        let t = takes
        return b.shots.first { t[$0.id] == nil } ?? b.shots.first
    }

    private func step(_ b: Storyboard, _ by: Int) {
        guard let s = current(b), let i = b.shots.firstIndex(of: s) else { return }
        let j = i + by
        guard b.shots.indices.contains(j) else { return }
        withAnimation(Theme.spring) { picked = b.shots[j].id }
    }

    private func header(_ b: Storyboard) -> some View {
        let drawing = b.shots.filter { $0.image == nil && $0.video == nil && $0.error == nil }.count
        let done = b.shots.filter { takes[$0.id] != nil }.count
        return HStack(spacing: 10) {
            Text("\(b.shots.count) shots").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            Text("·").foregroundStyle(Theme.faint)
            Text("about \(Storyboard.clock(b.total))").font(Theme.sans(13)).foregroundStyle(Theme.muted)
            if done > 0 {
                Text("·").foregroundStyle(Theme.faint)
                Text("\(done) recorded").font(Theme.sans(13)).foregroundStyle(Theme.live)
            }
            if drawing > 0 {
                ProgressView().controlSize(.small)
                Text("Drawing \(drawing) sketch\(drawing == 1 ? "" : "es")…")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { NSWorkspace.shared.open(Storyboard.folder(doc.url)) } label: {
                Image(systemName: "folder").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            .help("Show the sketches and storyboard.json in Finder")
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 10)
    }

    /// Every shot as a small card, in order, with the section names above their first card.
    /// ← and → step through them once a card was clicked.
    private func strip(_ b: Storyboard, shot: StoryShot?) -> some View {
        let t = takes
        let starts = Dictionary(uniqueKeysWithValues: zip(b.shots.map(\.id), b.starts))
        let last = b.shots.last?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(StoryShot.Section.allCases, id: \.self) { sec in
                        let shots = b.shots.filter { $0.section == sec }
                        if !shots.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(sec.title.uppercased()).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.faint)
                                HStack(spacing: 6) {
                                    ForEach(shots) { s in
                                        VStack(alignment: .leading, spacing: 5) {
                                        ShotThumb(doc: doc, shot: s, image: s.image.flatMap { images[$0] },
                                                  recorded: t[s.id] != nil,
                                                  noted: comments.all.contains { $0.shot == s.id && $0.open },
                                                  on: s.id == shot?.id, ratio: b.ratio, ns: ns)
                                        ShotTime(start: starts[s.id] ?? 0, length: s.length, on: s.id == shot?.id,
                                                 gap: s.id == last ? 0 : s.id == shots.last?.id ? 18 : 6,
                                                 end: s.id == last ? b.total : nil)
                                        }
                                            .id(s.id)
                                            .onTapGesture {
                                                withAnimation(Theme.spring) { picked = s.id }
                                                stripFocus = true
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .focusable().focusEffectDisabled().focused($stripFocus)
            .onKeyPress(.leftArrow) { step(b, -1); return .handled }
            .onKeyPress(.rightArrow) { step(b, 1); return .handled }
            .onChange(of: shot?.id) { _, id in
                guard let id else { return }
                withAnimation(.page) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 30)).foregroundStyle(Theme.faint)
            Text("No storyboard yet").font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
            Text("Takes writes the script and sketches each shot,\nso you see how to film it before you start.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Storyboard this video") {
                app.chats.chat(doc.url).send("Storyboard this video. Use the storyboard skill.",
                                             title: doc.meta.title, onStage: nil)
                app.chats.open = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        let file = Storyboard.file(doc.url)
        let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard m != stamp || board == nil && m != nil else { return }
        stamp = m
        let session = doc.url
        let have = Set(images.keys)
        let (b, new) = await Task.detached(priority: .userInitiated) { () -> (Storyboard?, [String: NSImage]) in
            guard let b = Storyboard.read(session) else { return (nil, [:]) }
            var new: [String: NSImage] = [:]
            for name in b.shots.compactMap(\.image) where !have.contains(name) && new[name] == nil {
                new[name] = Self.sketch(Storyboard.folder(session).appending(path: name))
            }
            return (b, new)
        }.value
        board = b
        images.merge(new) { $1 }
    }

    nonisolated(unsafe) private static let sketches: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()

    /// A sketch decoded here, off the main thread, at twice the tile width. NSImage(contentsOf:)
    /// decoded the full 928×1152 PNG on the main thread at first draw: 10 ms a sketch, every time
    /// the tab opened (2026-10-03). Kept per file and date, so a session switch costs nothing.
    nonisolated static func sketch(_ url: URL) -> NSImage? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = sketches.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: tileWidth * 2 * 1152 / 928,
              ] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        sketches.setObject(img, forKey: key)
        return img
    }

    /// The fold's title: a motion graphic is made, not filmed.
    static func howTitle(_ kind: String) -> String {
        switch kind.uppercased() {
        case "MG": return "What it shows"
        case "SCREEN": return "What to record"
        default: return "How to film it"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "MG": return Theme.accent
        case "B-ROLL", "BROLL": return Color(nsColor: NSColor(hex: 0x8B5CF6))
        case "SCREEN": return Theme.secondary
        case "WALK", "OUTSIDE": return Theme.live
        default: return Theme.ink
        }
    }
}

/// The kind of a shot (DESK, MG, SCREEN…) as a soft tinted chip: readable in light and dark.
/// The old chip put white text on the ink colour, so DESK vanished in dark mode.
struct KindChip: View {
    var kind: String

    var body: some View {
        let c = StoryboardPane.color(kind)
        Text(kind).font(Theme.mono(10.5, .semibold)).foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.14), in: Capsule())
    }
}

/// The strip's time ruler (2026-10-04): under each card, a rail that runs on to the next card,
/// a tick and the time the shot starts, so the strip reads as the video's timeline.
struct ShotTime: View {
    let start: Double
    let length: Double
    let on: Bool
    /// How far the rail runs past the card, to the next one.
    let gap: CGFloat
    /// Under the last card: the video's length at the rail's end.
    let end: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.border).frame(width: 76 + gap, height: 1)
            if on { Rectangle().fill(Theme.accent).frame(width: 76, height: 2) }
            Rectangle().fill(on ? Theme.accent : Theme.faint).frame(width: 1, height: 6)
            Text(Storyboard.clock(start))
                .font(Theme.mono(9.5, on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.faint)
                .padding(.leading, 4).padding(.top, 3)
            if let end {
                Rectangle().fill(Theme.faint).frame(width: 1, height: 6).offset(x: 75)
                Text(Storyboard.clock(end)).font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
                    .frame(width: 72, alignment: .trailing).padding(.top, 3)
            }
        }
        .frame(width: 76, height: 16, alignment: .topLeading)
        .help("Starts at \(Storyboard.clock(start)) · about \(Int(length.rounded())) s")
    }
}

/// A shot in the filmstrip: its sketch, a check once it has a take, a dot for an open comment.
private struct ShotThumb: View {
    var doc: SessionDoc
    var shot: StoryShot
    var image: NSImage?
    var recorded: Bool
    var noted: Bool
    var on: Bool
    var ratio: CGFloat
    var ns: Namespace.ID
    @State private var hover = false
    @State private var poster: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        ZStack {
            shape.fill(Theme.paper)
            if let img = image ?? poster {
                Image(nsImage: img).resizable().scaledToFill()
            } else if shot.error != nil {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        // The video's shape, at the strip's width: 95 high for 4:5, 43 for 16:9.
        .frame(width: 76, height: 76 / ratio)
        .clipShape(shape)
        .contentShape(shape)
        .overlay(shape.strokeBorder(Theme.border))
        .overlay(alignment: .bottomTrailing) {
            if recorded {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Theme.live, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 1.5))
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if noted { Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(5) }
        }
        .opacity(on || hover ? 1 : 0.72)
        .scaleEffect(on ? 1.06 : hover ? 1.03 : 1)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(-4)
                    .matchedGeometryEffect(id: "shot", in: ns)
            }
        }
        .padding(.vertical, 5)
        .animation(Theme.spring, value: on)
        .animation(Theme.motion, value: hover)
        .onHover { hover = $0 }
        .help(shot.say.isEmpty ? shot.kind : "“\(shot.say)”")
        .task(id: shot.video) {
            guard let v = shot.video else { return }
            let clip = doc.url.appending(path: v)
            poster = BrollLib.cachedPoster(clip)
            if poster == nil { poster = await BrollLib.poster(clip) }
        }
    }
}

/// The chosen shot, big: the sketch on the left; the line to say, one Record button, its takes
/// and comments on the right. How to film it (What it shows, for a motion graphic) folds away under the line.
/// The shot's sketch and its column, side by side. The sketch's size comes only from the space
/// offered, never from what is inside, so one layout pass settles it.
private struct ShotSplit: Layout {
    /// The frame's width over its height.
    var ratio: CGFloat = 4.0 / 5.0
    var gap: CGFloat = 40
    var column: CGFloat = 560

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 900, height: 600))
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        // As big as the height allows, but never more than about half the width: a wide frame
        // takes a little more, so the line still has room.
        let w = max(220, min(b.height * ratio, (b.width - gap) * (ratio > 1 ? 0.62 : 0.55)))
        subviews[0].place(at: b.origin, proposal: ProposedViewSize(width: w, height: w / ratio))
        let x = b.minX + w + gap
        subviews[1].place(at: CGPoint(x: x, y: b.minY),
                          proposal: ProposedViewSize(width: max(0, min(column, b.maxX - x)), height: b.height))
    }
}

private struct ShotDetail: View {
    @Environment(AppModel.self) var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.paneShown) private var shown
    var doc: SessionDoc
    var shot: StoryShot
    var number: Int
    var count: Int
    var start: Double
    /// The storyboard's shape. A clip shows in its own shape.
    var ratio: CGFloat
    var image: NSImage?
    var takes: [Take]
    var comments: [Comment]
    var store: CommentStore
    var step: (Int) -> Void
    @State private var draft = ""
    @State private var showResolved = false
    @State private var showHow = false
    @State private var poster: NSImage?
    /// Clips play with sound: The user turns it on once and it stays on (2026-10-04).
    @AppStorage("storyboardSound") private var sound = false
    @FocusState private var typing: Bool

    private var clip: URL? { shot.video.map { doc.url.appending(path: $0) } }

    /// The model that made what the frame shows: the clip, else the sketch (2026-10-06).
    private var madeWith: String? {
        if let clip { return MadeWith.label(for: clip) }
        return shot.image.flatMap { MadeWith.label(for: Storyboard.folder(doc.url).appending(path: $0)) }
    }

    /// A clip's own shape, from its first frame, so a 16:9 clip is not cut to a 9:16 card.
    private var frameRatio: CGFloat {
        if clip != nil, let p = poster, p.size.width > 0, p.size.height > 0 { return p.size.width / p.size.height }
        return ratio
    }

    // The sketch takes the room there is (2026-10-04): half the width at most, all the height.
    // With the chat closed it grows; with it open it shrinks before the line does. A Layout, not a
    // GeometryReader (inside one the blur-in never started) and not a measured @State size: that
    // fed the sketch's width back into the size it was measured from and froze the app (2026-10-04).
    var body: some View {
        ShotSplit(ratio: frameRatio) {
            frame
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    top
                    if !shot.say.isEmpty {
                        Text(shot.say).font(Theme.display(28, .semibold)).foregroundStyle(Theme.ink)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !shot.how.isEmpty { how }
                    if let e = shot.clipError, shot.generating == nil {
                        Label("Higgsfield: \(e)", systemImage: "exclamationmark.triangle")
                            .font(Theme.sans(12)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if !takes.isEmpty { takeStrip }
                    notes.padding(.top, 10)
                }
                // Room for the field's border and focus ring: the scroll view clipped its right edge.
                .padding(.vertical, 4).padding(.horizontal, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
        .contextMenu { menu }
    }

    private var top: some View {
        HStack(spacing: 8) {
            Text("\(shot.section.title) · \(number) of \(count)")
                .font(Theme.sans(12, .medium)).foregroundStyle(Theme.muted)
            KindChip(kind: shot.kind)
            Text("\(Storyboard.clock(start)) · \(Int(shot.length.rounded())) s")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            if let m = madeWith {
                Text(m).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1)
                    .help(clip != nil ? "This clip was made with \(m)" : "This sketch was drawn with \(m)")
            }
            Spacer()
            generate
            record
            HStack(spacing: 2) {
                arrow("chevron.left", -1, off: number == 1)
                arrow("chevron.right", 1, off: number == count)
            }
        }
    }

    private func arrow(_ icon: String, _ by: Int, off: Bool) -> some View {
        Button { step(by) } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(off ? Theme.faint : Theme.ink)
        .background(Theme.hover.opacity(off ? 0 : 1), in: Circle())
        .disabled(off)
        .help(by < 0 ? "The shot before (←)" : "The next shot (→)")
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Theme.spring) { showHow.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showHow ? 90 : 0))
                    Text(StoryboardPane.howTitle(shot.kind)).font(Theme.sans(12, .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            if showHow {
                Text(shot.how).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    @ViewBuilder private var frame: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        Color.clear
            .overlay {
                ZStack {
                    shape.fill(Theme.paper)
                    if let clip {
                        // The clip plays on its own, muted and looping, while the tab shows (2026-10-04).
                        Theme.stage
                            .overlay { if let poster { Image(nsImage: poster).resizable().scaledToFill() } }
                            .overlay { if shown && !app.isRecording { LoopingVideo(url: clip, sound: sound) } }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(clip) }
                            .help("Double-click to open")
                            .task(id: clip) {
                                poster = BrollLib.cachedPoster(clip)
                                if poster == nil { poster = await BrollLib.poster(clip) }
                            }
                    } else if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .onTapGesture(count: 2) { if let n = shot.image { NSWorkspace.shared.open(Storyboard.folder(doc.url).appending(path: n)) } }
                            .help(shot.sketch)
                    } else if let err = shot.error {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                            Text(err).font(Theme.sans(11)).foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center).lineLimit(5)
                        }
                        .padding(16)
                    } else {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Drawing…").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                        }
                    }
                }
                // A wide clip fills by overflowing the frame sideways: hover and clicks stay inside the card.
                .clipShape(shape).contentShape(shape)
            }
            .overlay(shape.strokeBorder(Theme.border))
            .shadow(color: Theme.shadow, radius: 18, y: 8)
            .overlay(alignment: .topTrailing) {
                if takes.contains(where: \.keeper) {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(.yellow)
                        .padding(7).background(.black.opacity(0.55), in: Circle()).padding(10)
                        .help("This shot has a keeper take")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if shot.generating != nil {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Generating with Higgsfield…").font(Theme.sans(11.5, .medium)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip != nil {
                    Button { sound.toggle() } label: {
                        Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.55), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .padding(12)
                    .help(sound ? "Mute the clips" : "Play the clips with sound (stays on)")
                }
            }
    }

    /// ✦ next to the record dot (2026-10-06): Takes makes this shot's clip with Higgsfield. Not set up
    /// yet: it opens Settings › Higgsfield.
    private var generate: some View {
        Button { makeClip() } label: {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(Theme.accentInk)
        .background(Theme.accentSoft, in: Circle())
        .disabled(shot.generating != nil)
        .opacity(shot.generating != nil ? 0.45 : 1)
        .help(shot.generating != nil ? "Higgsfield is making this clip" : clip == nil ? "Make this shot's clip with Higgsfield" : "Make a new clip with Higgsfield")
    }

    private func makeClip() {
        Task {
            let hf = Higgsfield.shared
            if !hf.ready { await hf.check() }
            guard hf.ready else {
                UserDefaults.standard.set(SettingsView.SettingsPage.higgsfield.rawValue, forKey: "settingsPage")
                openSettings()
                return
            }
            app.chats.chat(doc.url).send(Higgsfield.shotPrompt(shot), title: doc.meta.title, onStage: nil)
            app.chats.open = true
        }
    }

    /// One red record dot next to the arrows (2026-10-04): the script column shows only this shot's lines.
    private var record: some View {
        Button { app.record(shot: shot) } label: {
            Circle().fill(.white).frame(width: 10, height: 10)
                .frame(width: 28, height: 28)
                .background(Theme.danger, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(app.isRecording)
        .opacity(app.isRecording ? 0.45 : 1)
        .padding(.trailing, 6)
        .help(takes.isEmpty ? "Record this shot" : "Record this shot again")
    }

    private var takeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(takes.count) take\(takes.count == 1 ? "" : "s")").font(Theme.sans(12, .medium)).foregroundStyle(Theme.muted)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(takes) { t in TakeThumb(doc: doc, take: t) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Notes for Takes on this shot: the open ones, then one box that is always there.
    /// No Comment button to find first (2026-10-04: the button then a box under it felt odd).
    private var notes: some View {
        let open = comments.filter(\.open), done = comments.filter { !$0.open }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(open) { c in note(c) }
            if showResolved { ForEach(done) { c in note(c) } }
            AskBox(placeholder: "Note for Takes: what should change?", text: $draft, focus: $typing, send: send,
                   cancel: { draft = ""; typing = false }, autofocus: false, inline: true)
            if !done.isEmpty {
                Button { withAnimation(Theme.motion) { showResolved.toggle() } } label: {
                    Text(showResolved ? "Hide resolved" : "\(done.count) resolved")
                        .font(Theme.sans(11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).padding(.leading, 14)
            }
        }
    }

    private func note(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(c.text).font(Theme.sans(12)).foregroundStyle(c.open ? Theme.ink : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    CommentStore.change(doc.url) { f in
                        if let i = f.comments.firstIndex(where: { $0.id == c.id }) { f.comments[i].status = c.open ? "resolved" : "open" }
                    }
                    store.load(doc.url)
                } label: {
                    Image(systemName: c.open ? "checkmark.circle" : "arrow.uturn.backward.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.faint)
                .help(c.open ? "Resolve" : "Open again")
            }
            ForEach(Array((c.replies ?? []).enumerated()), id: \.offset) { _, r in
                Text((r.by == "claude" ? "Takes: " : "You: ") + r.text)
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(c.open ? Theme.accent.opacity(0.08) : Theme.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = CommentStore.addText(doc.url, file: Storyboard.commentFile, quote: nil, text: t, shot: shot.id)
        store.load(doc.url)
        draft = ""
    }

    @ViewBuilder private var menu: some View {
        Button("Record this shot") { app.record(shot: shot) }.disabled(app.isRecording)
        Button("Make the clip with Higgsfield") { makeClip() }.disabled(shot.generating != nil)
        let others = doc.meta.takes.filter { $0.kind == .camera && $0.shot != shot.id }.sorted { $0.number > $1.number }
        if !others.isEmpty {
            Menu("File a take under this shot") {
                ForEach(others) { t in
                    Button("\(t.name ?? "Take \(t.number)")\(t.duration.map { " · \(Storyboard.clock($0))" } ?? "")") {
                        doc.link(take: t.number, to: shot.id)
                    }
                }
            }
        }
        if let clip {
            Button("Open the clip") { NSWorkspace.shared.open(clip) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip]) }
        } else if let n = shot.image {
            Button("Open the sketch") { NSWorkspace.shared.open(Storyboard.folder(doc.url).appending(path: n)) }
        }
    }
}

/// A take under a shot: its frame, the number, a star for the keeper. Click plays it on the stage.
private struct TakeThumb: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    var take: Take
    @State private var image: NSImage?
    @State private var cut: TakeCut?

    var body: some View {
        let url = doc.fileURL(take)
        Button {
            SessionMode.set(.assets)
            app.jump(to: url, at: cut?.state == "done" ? cut?.start ?? 0 : 0)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Theme.stage)
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                HStack(spacing: 3) {
                    if take.keeper { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    Text("\(take.number)")
                }
                .font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
            }
            .frame(width: 52, height: 65)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // The wide frame overflows sideways; without this its clicks open the take beside it.
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if let cut {
                    Image(systemName: cut.state == "running" ? "ellipsis" : cut.state == "failed" ? "exclamationmark" : "scissors")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(cut.state == "failed" || cut.clean == false ? Color.orange
                                    : cut.by == "agent" ? Theme.live : Color.gray, in: Circle())
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .contextMenu {
            Button(take.keeper ? "Unstar" : "Star as the keeper") { doc.toggleKeeper(take.number) }
            Button(cut == nil ? "Find the Best Cut" : "Find the Best Cut Again") {
                TakeCut.start(doc.url, take: take.number)
                cut = TakeCut(state: "running")
            }
            .disabled(cut?.state == "running")
            Button("Take it off this shot") { doc.link(take: take.number, to: nil) }
        }
        .task(id: url) { cut = TakeCut.read(doc.url)[String(take.number)] }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { note in
            guard let paths = note.object as? [String], paths.contains(where: { $0.hasSuffix("cuts.json") }) else { return }
            let now = TakeCut.read(doc.url)[String(take.number)]
            if now != cut { cut = now }
        }
        .task(id: url) {
            image = await Thumbs.shared.image(Asset(url: url, group: "", name: take.file, size: 0,
                                                    modified: take.startedAt, take: true))
        }
    }
}

extension TakeThumb {
    var help: String {
        var s = "\(take.name ?? "Take \(take.number)")\(take.duration.map { " · \(Storyboard.clock($0))" } ?? "")"
        switch cut?.state {
        case "running": s += "\nGemini is finding the best cut…"
        case "failed": s += "\nNo best cut: \(cut?.error ?? "it failed")"
        case "done":
            let who = cut?.by == "agent" ? "Best cut, checked by Takes" : "Gemini's first suggestion (Takes checks it before cutting)"
            if let r = cut?.range { s += "\n\(who): \(r)\(cut?.clean == false ? " (not every word clean)" : "")" }
            if let w = cut?.why { s += ": \(w)" }
        default: break
        }
        return s + "\nClick to play it\(cut?.range != nil ? " from the best cut" : "")."
    }
}

/// The clean delivery in a shot's take (<session>/cuts.json, keyed by take number). Gemini's
/// --take-cut run writes a first suggestion (by "gemini"); the editing agent checks it and writes
/// the range it uses with set_best_cut (by "agent").
struct TakeCut: Decodable, Equatable {
    var state: String
    var start: Double?
    var end: Double?
    var clean: Bool?
    var why: String?
    var error: String?
    var by: String?

    static func file(_ session: URL) -> URL { session.appending(path: "cuts.json") }

    static func read(_ session: URL) -> [String: TakeCut] {
        (try? Data(contentsOf: file(session))).flatMap { try? JSONDecoder().decode([String: TakeCut].self, from: $0) } ?? [:]
    }

    /// Starts the pick in the background (Gemini, about a minute).
    static func start(_ session: URL, take: Int) {
        _ = Voice.launch(["--take-cut", session.path, String(take)])
    }

    var range: String? {
        guard state == "done", let start, let end else { return nil }
        return String(format: "%.1f–%.1f s", start, end)
    }
}

/// Above the script column while a storyboard shot records: which shot this take is for.
struct ShotBanner: View {
    var shot: StoryShot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1").foregroundStyle(Theme.accent)
            Text("Shot for the storyboard").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
            KindChip(kind: shot.kind)
            Spacer()
            if !shot.how.isEmpty {
                Text(shot.how).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.08))
    }
}
