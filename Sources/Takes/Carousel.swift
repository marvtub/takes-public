import AppKit
import SwiftUI

/// Carousels (2026-10-26): one set of slides per session, woven into the Post tab's own platforms.
/// The LinkedIn post switches its media from Video to Carousel (a PDF document post); the vertical
/// post switches from Video to Photos (a TikTok photo post and an Instagram carousel). The post text
/// stays the platform's own post. Takes does not post them: Export writes the files to upload.
///
///   posts/carousel.json   {"slides": [slide], "look", "accent", "on": {"linkedin": true, "vertical": false},
///                         "docTitle"}; same format as set_carousel in mcp/takes_mcp.py
///   posts/carousel/linkedin.pdf             one 4:5 page per slide (a video slide shows its first frame)
///   posts/carousel/<place>/slide-NN.png     1080 × 1440 (Instagram, 3:4), 1080 × 1920 (TikTok)
///   posts/carousel/instagram/slide-NN.mp4   a video slide (Instagram only: TikTok photo posts have no video)
///
/// Slides are not only text (2026-10-29): each has a layout (one word, a cover photo, a grid of
/// frames, before and after, a photo with notes on it, a magazine page, a list, a video) and the
/// set has one look (CarouselSlides.swift). Pictures come from the session: stills, sketches,
/// thumbnails, a frame of a take or an edit at a second.
///
/// What works (Metricool, Oktopost, PostNitro, 2026): the first slide is the hook and the only one
/// people see before they swipe; one idea per slide; the last slide asks for one thing.
struct CarouselSlide: Codable, Equatable, Hashable {
    var layout = SlideLayout.text
    var kicker = ""
    var title = ""
    var body = ""
    /// A picture or a video: a path in the session ("stills/a.jpg", "take-02-camera.mov") or a full path.
    var media = ""
    /// For a video in `media` on a still layout: the second to show.
    var at: Double?
    /// The video layout's part of the clip, in seconds.
    var start: Double?
    var end: Double?
    /// The frames layout's pictures (two to four), and before and after's two.
    var items: [SlideItem] = []
    /// The annotate layout's notes on the picture.
    var marks: [SlideMark] = []

    init(layout: SlideLayout = .text, kicker: String = "", title: String = "", body: String = "", media: String = "",
         at: Double? = nil, items: [SlideItem] = [], marks: [SlideMark] = []) {
        self.layout = layout; self.kicker = kicker; self.title = title; self.body = body
        self.media = media; self.at = at; self.items = items; self.marks = marks
    }

    enum CodingKeys: String, CodingKey { case layout, kicker, title, body, media, at, start, end, items, marks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? c.decodeIfPresent(String.self, forKey: .layout)).flatMap { $0.flatMap(SlideLayout.init(rawValue:)) } ?? .text
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        media = try c.decodeIfPresent(String.self, forKey: .media) ?? ""
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        items = (try? c.decodeIfPresent([SlideItem].self, forKey: .items)) ?? []
        marks = (try? c.decodeIfPresent([SlideMark].self, forKey: .marks)) ?? []
    }

    /// Only what is set, so a text slide stays {"kicker", "title", "body"} as before.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if layout != .text { try c.encode(layout.rawValue, forKey: .layout) }
        try c.encode(kicker, forKey: .kicker)
        try c.encode(title, forKey: .title)
        try c.encode(body, forKey: .body)
        if !media.isEmpty { try c.encode(media, forKey: .media) }
        try c.encodeIfPresent(at, forKey: .at)
        try c.encodeIfPresent(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        if !items.isEmpty { try c.encode(items, forKey: .items) }
        if !marks.isEmpty { try c.encode(marks, forKey: .marks) }
    }

    /// Every file the slide shows.
    var files: [String] { ([media] + items.map(\.media)).filter { !$0.isEmpty } }
}

/// One picture of a frames or before-and-after slide, with its tag ("WS", "Before") and a line.
struct SlideItem: Codable, Equatable, Hashable {
    var media = ""
    var at: Double?
    var label = ""
    var text = ""

    init(media: String = "", at: Double? = nil, label: String = "", text: String = "") {
        self.media = media; self.at = at; self.label = label; self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        media = try c.decodeIfPresent(String.self, forKey: .media) ?? ""
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// A note on the annotate layout's picture: a dot at x, y (0 to 1, from the top left) and its words.
struct SlideMark: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var text = ""

    init(x: Double, y: Double, text: String = "") { self.x = x; self.y = y; self.text = text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5))
        y = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5))
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// What a slide is (2026-10-29). Same names as set_carousel's `layout`.
enum SlideLayout: String, Codable, CaseIterable, Identifiable {
    case text, word, cover, photo, frames, compare, annotate, magazine, list, video
    var id: String { rawValue }

    var name: String {
        switch self {
        case .text: "Text"
        case .word: "One word"
        case .cover: "Cover photo"
        case .photo: "Photo only"
        case .frames: "Frames"
        case .compare: "Before and after"
        case .annotate: "Photo with notes"
        case .magazine: "Magazine page"
        case .list: "List"
        case .video: "Video"
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .word: "textformat.size.larger"
        case .cover: "photo.artframe"
        case .photo: "photo"
        case .frames: "square.grid.2x2"
        case .compare: "rectangle.split.2x1"
        case .annotate: "mappin.and.ellipse"
        case .magazine: "newspaper"
        case .list: "list.number"
        case .video: "play.rectangle"
        }
    }

    /// The layouts that show `media`.
    var showsMedia: Bool { [.cover, .photo, .annotate, .magazine, .video].contains(self) }
    var showsItems: Bool { self == .frames || self == .compare }
}

/// The set's look (2026-10-29): type, colours, paper. Same names as set_carousel's `look`.
enum CarouselLook: String, Codable, CaseIterable, Identifiable {
    case takes, bold, magazine, note, cinema
    var id: String { rawValue }

    var name: String {
        switch self {
        case .takes: "Takes"
        case .bold: "Bold"
        case .magazine: "Magazine"
        case .note: "Note"
        case .cinema: "Cinema"
        }
    }

    var detail: String {
        switch self {
        case .takes: "Navy and white, round type"
        case .bold: "Tall black type, one yellow, grid paper"
        case .magazine: "Serif on cream paper, one dark red"
        case .note: "A note on your phone, handwritten notes"
        case .cinema: "Black, white serif, like a film"
        }
    }
}

struct CarouselFile: Codable, Equatable, Hashable {
    var slides: [CarouselSlide] = []
    /// The posts that show the slides in place of the video: "linkedin", "vertical".
    var on: [String: Bool] = [:]
    /// The LinkedIn document's name: LinkedIn shows it on the post.
    var docTitle = ""
    var look = CarouselLook.takes
    /// A colour in place of the look's own, "#FFD21F". Empty: the look's.
    var accent = ""

    static let rel = "posts/carousel.json"
    static func url(_ session: URL) -> URL { session.appending(path: rel) }
    /// The platforms a carousel can stand in for.
    static let platforms: [PostPlatform] = [.linkedin, .vertical]
    /// Pictures dropped on a slide from outside the session are copied here.
    static let mediaFolder = "posts/carousel/media"

    init(slides: [CarouselSlide] = [], on: [String: Bool] = [:], docTitle: String = "", look: CarouselLook = .takes, accent: String = "") {
        self.slides = slides; self.on = on; self.docTitle = docTitle; self.look = look; self.accent = accent
    }

    enum CodingKeys: String, CodingKey { case slides, on, docTitle, look, accent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slides = try c.decodeIfPresent([CarouselSlide].self, forKey: .slides) ?? []
        on = try c.decodeIfPresent([String: Bool].self, forKey: .on) ?? [:]
        docTitle = try c.decodeIfPresent(String.self, forKey: .docTitle) ?? ""
        look = (try? c.decodeIfPresent(String.self, forKey: .look)).flatMap { $0.flatMap(CarouselLook.init(rawValue:)) } ?? .takes
        accent = (try? c.decodeIfPresent(String.self, forKey: .accent)).flatMap { $0 } ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slides, forKey: .slides)
        try c.encode(on, forKey: .on)
        try c.encode(docTitle, forKey: .docTitle)
        if look != .takes { try c.encode(look.rawValue, forKey: .look) }
        if !accent.isEmpty { try c.encode(accent, forKey: .accent) }
    }

    func isOn(_ p: PostPlatform) -> Bool { on[p.rawValue] == true && !slides.isEmpty }

    static func read(_ session: URL) -> CarouselFile? {
        guard let data = try? Data(contentsOf: url(session)) else { return nil }
        return try? JSONDecoder().decode(CarouselFile.self, from: data)
    }

    /// The post shows its slides in place of the video.
    static func isOn(_ session: URL, _ p: PostPlatform) -> Bool { read(session)?.isOn(p) == true }

    @discardableResult
    static func write(_ c: CarouselFile, to session: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(c) else { return false }
        try? FileManager.default.createDirectory(at: url(session).deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url(session), options: .atomic)) != nil
    }

    /// A slide's file: a path in the session, or a full path ("~" too).
    static func resolve(_ media: String, in session: URL) -> URL? {
        let m = media.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        if m.hasPrefix("/") { return URL(fileURLWithPath: m) }
        if m.hasPrefix("~") { return URL(fileURLWithPath: (m as NSString).expandingTildeInPath) }
        return session.appending(path: m)
    }

    /// What a slide calls a file: its path in the session when it is in there, else the full path.
    static func name(of file: URL, in session: URL) -> String {
        let real = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath().path }
        let base = real(session) + "/"
        let p = real(file)
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    /// A file dropped on a slide: kept where it is when it is in the session, else copied into
    /// posts/carousel/media, so the slide still shows it when the file moves.
    static func adopt(_ file: URL, in session: URL) -> String? {
        let name = name(of: file, in: session)
        guard name.hasPrefix("/") else { return name }
        let dir = session.appending(path: mediaFolder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appending(path: file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appending(path: file.deletingPathExtension().lastPathComponent + "-\(n)." + file.pathExtension)
            n += 1
        }
        guard (try? FileManager.default.copyItem(at: file, to: dest)) != nil else { return nil }
        return mediaFolder + "/" + dest.lastPathComponent
    }

    /// First slides from the session's name: a hook, two slides to fill in, the ask.
    static func starter(_ title: String) -> [CarouselSlide] {
        [CarouselSlide(kicker: "Swipe →", title: title.isEmpty ? "The one idea of this post" : title, body: "Save this for later."),
         CarouselSlide(kicker: "1", title: "First point", body: "One idea per slide."),
         CarouselSlide(kicker: "2", title: "Second point", body: "Big text: people read it on a phone."),
         CarouselSlide(kicker: "That's it", title: "Save this.", body: "Follow for more.")]
    }

    /// Turns the slides on or off for a post; the first time, from the session (CarouselTemplate.auto).
    static func set(_ p: PostPlatform, on: Bool, in session: URL, title: String) -> CarouselFile {
        var c = read(session) ?? CarouselFile(docTitle: title)
        if on && c.slides.isEmpty {
            let t = CarouselTemplate.auto(session)
            c.slides = t.slides(session, title: title)
            c.look = t.look
        }
        c.on[p.rawValue] = on
        write(c, to: session)
        return c
    }

    /// A change from the phone: {"platform", "on": "true"/"false"} or {"slide": "2", "title" or "body"},
    /// {"action": "add"} (before the last slide), {"action": "delete", "slide": "2"} (three slides or more),
    /// {"slide": "2", "layout": "word"}, {"look": "bold"} or {"template": "filmed"}.
    /// Nil when done, else what went wrong.
    static func phoneChange(_ change: [String: String], in session: URL, title: String) -> String? {
        if let raw = change["platform"], let p = PostPlatform(rawValue: raw), platforms.contains(p), let v = change["on"] {
            _ = set(p, on: v == "true", in: session, title: title)
            return nil
        }
        if let raw = change["template"] {
            guard let t = CarouselTemplate(rawValue: raw) else { return "No such template" }
            var c = read(session) ?? CarouselFile(docTitle: title)
            c.slides = t.slides(session, title: title)
            c.look = t.look
            return write(c, to: session) ? nil : "Could not save the carousel"
        }
        guard var c = read(session) else { return "No carousel" }
        if let raw = change["look"] {
            guard let l = CarouselLook(rawValue: raw) else { return "No such look" }
            c.look = l
        } else if change["action"] == "add" {
            let at = max(0, c.slides.count - 1)
            c.slides.insert(CarouselSlide(kicker: "\(at)", title: "New slide"), at: at)
        } else if change["action"] == "delete", let raw = change["slide"], let i = Int(raw), c.slides.indices.contains(i) {
            guard c.slides.count > 2 else { return "A carousel keeps two slides or more" }
            c.slides.remove(at: i)
        } else if let raw = change["slide"], let i = Int(raw), c.slides.indices.contains(i), let l = change["layout"] {
            guard let layout = SlideLayout(rawValue: l) else { return "No such layout" }
            c.slides[i].layout = layout
        } else if let raw = change["slide"], let i = Int(raw), c.slides.indices.contains(i), change["title"] != nil || change["body"] != nil {
            if let t = change["title"] { c.slides[i].title = t }
            if let b = change["body"] { c.slides[i].body = b }
        } else {
            return "Nothing to change"
        }
        return write(c, to: session) ? nil : "Could not save the carousel"
    }

    /// What the session's chat hears about it, for the post on show.
    func context(_ p: PostPlatform) -> String? {
        guard isOn(p) else { return nil }
        let list = slides.enumerated().map { i, s in
            "\(i + 1). " + (s.layout == .text ? "" : "[\(s.layout.rawValue)] ") + s.title + (s.body.isEmpty ? "" : " / \(s.body)")
                + (s.files.isEmpty ? "" : " (\(s.files.joined(separator: ", ")))")
        }
        return "The \(p == .linkedin ? "LinkedIn post is a carousel (a PDF)" : "vertical post is a photo post")"
            + " with \(slides.count) slides in the \(look.rawValue) look (\(CarouselFile.rel), set_carousel): " + list.joined(separator: "; ") + "."
    }
}

/// The apps a slide is drawn for: the size and the space the app's buttons leave.
enum CarouselPlace: String, CaseIterable, Identifiable {
    case instagram, linkedin, tiktok
    var id: String { rawValue }

    var name: String {
        switch self {
        case .instagram: "Instagram"
        case .linkedin: "LinkedIn"
        case .tiktok: "TikTok"
        }
    }
    /// The first slide sets the size for all of an Instagram carousel. 3:4 since 2026-10-29: the
    /// feed and the grid show it whole, and it is taller than 4:5.
    var size: CGSize {
        switch self {
        case .tiktok: CGSize(width: 1080, height: 1920)
        case .instagram: CGSize(width: 1080, height: 1440)
        case .linkedin: CGSize(width: 1080, height: 1350)
        }
    }
    var ratio: CGFloat { size.width / size.height }
    var folder: String { "posts/carousel/\(rawValue)" }
    /// TikTok photo posts and LinkedIn documents have no video: a video slide shows its first frame.
    var plays: Bool { self == .instagram }

    /// The photo posts a vertical post makes: TikTok and Instagram. Shorts has no photo posts.
    static func photos(_ places: [VerticalPlace]) -> [CarouselPlace] {
        (places.contains(.tiktok) ? [.tiktok] : []) + (places.contains(.reels) ? [.instagram] : [])
    }
}

// MARK: - Templates

/// Ways to start a carousel from what the session has (2026-10-29). Each sets a look and fills the
/// slides with the session's own pictures: its stills, its storyboard sketches, frames of its takes.
enum CarouselTemplate: String, CaseIterable, Identifiable {
    case tips, filmed, photos, story, note
    var id: String { rawValue }

    var name: String {
        switch self {
        case .tips: "Tips"
        case .filmed: "How I filmed this"
        case .photos: "Photo dump"
        case .story: "Magazine story"
        case .note: "Note"
        }
    }

    var detail: String {
        switch self {
        case .tips: "A hook, one tip a slide, the ask"
        case .filmed: "Each storyboard sketch next to the frame you filmed"
        case .photos: "Your stills, full bleed"
        case .story: "A cover, then pages with a picture and a paragraph"
        case .note: "Like a note on your phone, with notes on a photo"
        }
    }

    var look: CarouselLook {
        switch self {
        case .tips: .takes
        case .filmed: .bold
        case .photos: .cinema
        case .story: .magazine
        case .note: .note
        }
    }

    /// The template a new carousel starts from: the storyboard when shots were filmed, the stills
    /// when there are a few, else tips.
    static func auto(_ session: URL) -> CarouselTemplate {
        if !SessionPictures.filmedShots(session).isEmpty { return .filmed }
        if SessionPictures.stills(session).count >= 3 { return .photos }
        return .tips
    }

    func slides(_ session: URL, title: String) -> [CarouselSlide] {
        let name = title.isEmpty ? "The one idea of this post" : title
        let stills = SessionPictures.stills(session)
        let first = stills.first ?? SessionPictures.keeperFrame(session)
        let ask = CarouselSlide(kicker: "That's it", title: "Save this.", body: "Follow for more.")
        switch self {
        case .tips:
            return CarouselFile.starter(title)
        case .filmed:
            let shots = SessionPictures.filmedShots(session)
            var s = [CarouselSlide(layout: .cover, kicker: "How I filmed this", title: name, body: "Save this for your next shoot.",
                                   media: first?.media ?? "", at: first?.at)]
            let plan = SessionPictures.sketches(session).prefix(4)
            if !plan.isEmpty {
                s.append(CarouselSlide(layout: .frames, kicker: "The plan", title: "\(plan.count) shots",
                                       items: plan.enumerated().map { i, p in SlideItem(media: p.media, label: "Shot \(i + 1)", text: p.text) }))
            }
            for (i, shot) in shots.prefix(6).enumerated() {
                s.append(CarouselSlide(layout: .compare, kicker: "Shot \(i + 1)", title: shot.title, body: shot.how,
                                       items: [SlideItem(media: shot.sketch, label: "Sketch"),
                                               SlideItem(media: shot.frame.media, at: shot.frame.at, label: "Filmed")]))
            }
            s.append(CarouselSlide(layout: .word, kicker: "Your turn", title: "Film it.", body: "Save this. Follow for more."))
            return s
        case .photos:
            var s = [CarouselSlide(layout: .cover, kicker: "Swipe →", title: name, media: first?.media ?? "", at: first?.at)]
            s += stills.dropFirst().prefix(8).map { CarouselSlide(layout: .photo, media: $0.media, at: $0.at) }
            if s.count == 1 { s.append(CarouselSlide(layout: .photo)) }
            return s + [ask]
        case .story:
            var s = [CarouselSlide(layout: .cover, kicker: "The story", title: name, body: "A short read. Swipe →",
                                   media: first?.media ?? "", at: first?.at)]
            let pages = Array(stills.dropFirst().prefix(4))
            for (i, p) in (pages.isEmpty ? [SessionPicture(media: "")] : pages).enumerated() {
                s.append(CarouselSlide(layout: .magazine, kicker: "Part \(i + 1)", title: "A headline for this part",
                                       body: "Two or three sentences. Say what happened and why it matters.", media: p.media, at: p.at))
            }
            return s + [CarouselSlide(layout: .text, kicker: "The end", title: "Save this.", body: "Follow for the next one.")]
        case .note:
            return [CarouselSlide(layout: .text, kicker: "Note to self", title: name, body: "Read this before you film."),
                    CarouselSlide(layout: .list, kicker: "Before you film", title: "The list",
                                  body: "Face the window\nLock the exposure\nClip the mic on\nLook at the lens"),
                    CarouselSlide(layout: .annotate, kicker: "The setup", title: "Where it all goes", media: first?.media ?? "", at: first?.at,
                                  marks: [SlideMark(x: 0.3, y: 0.3, text: "Light"), SlideMark(x: 0.65, y: 0.62, text: "Mic")]),
                    CarouselSlide(layout: .word, title: "Go.", body: "Save this note.")]
        }
    }
}

/// A picture a template can use: a file in the session, and the second for a video.
struct SessionPicture: Equatable {
    var media: String
    var at: Double? = nil
    var text = ""
}

/// A storyboard shot with a take: its sketch, a frame of the take, and its words.
struct FilmedShot: Equatable {
    var sketch: String
    var frame: SessionPicture
    var title: String
    var how: String
}

/// What a session has to show on slides.
enum SessionPictures {
    static let stillTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]

    /// The user's saved frames (stills/), oldest first.
    static func stills(_ session: URL) -> [SessionPicture] {
        let dir = session.appending(path: "stills")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { stillTypes.contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent).sorted()
            .map { SessionPicture(media: "stills/" + $0) }
    }

    /// The storyboard's sketches, in shot order, with the line each shot says.
    static func sketches(_ session: URL) -> [SessionPicture] {
        (Storyboard.read(session)?.shots ?? []).compactMap { shot in
            guard let img = shot.image, !img.isEmpty else { return nil }
            return SessionPicture(media: "storyboard/" + img, text: short(shot.say))
        }
    }

    /// Shots with a sketch and a take: the keeper, else the newest; the frame a second into its best cut.
    static func filmedShots(_ session: URL) -> [FilmedShot] {
        guard let board = Storyboard.read(session), let meta = Store.readMeta(session) else { return [] }
        let cuts = TakeCut.read(session)
        return board.shots.compactMap { shot in
            guard let img = shot.image, !img.isEmpty, !shot.id.isEmpty else { return nil }
            let takes = meta.takes.filter { $0.shot == shot.id && $0.kind == .camera }
            guard let take = takes.first(where: \.keeper) ?? takes.max(by: { $0.number < $1.number }) else { return nil }
            let cut = cuts[String(take.number)]
            let at = (cut?.start ?? 0) + 1
            return FilmedShot(sketch: "storyboard/" + img, frame: SessionPicture(media: take.file, at: at),
                              title: short(shot.say, words: 6), how: shot.how)
        }
    }

    /// A frame of the keeper take (or the newest camera take), when there are no stills.
    static func keeperFrame(_ session: URL) -> SessionPicture? {
        guard let meta = Store.readMeta(session) else { return nil }
        let cams = meta.takes.filter { $0.kind == .camera }
        guard let t = cams.first(where: \.keeper) ?? cams.max(by: { $0.number < $1.number }) else { return nil }
        return SessionPicture(media: t.file, at: 1)
    }

    static func short(_ s: String, words: Int = 12) -> String {
        let w = s.split(whereSeparator: \.isWhitespace)
        return w.count > words ? w.prefix(words).joined(separator: " ") + "…" : w.joined(separator: " ")
    }
}

// MARK: - Store

/// The session's carousel. Edits show at once and reach the file half a second later; a change
/// from the chat or the phone loads again.
@MainActor
final class CarouselStore: ObservableObject {
    @Published private(set) var file: CarouselFile?
    private(set) var session: URL?
    private var pending: DispatchWorkItem?

    var style: SlideStyle { SlideStyle(file?.look ?? .takes, accent: file?.accent ?? "") }

    func load(_ s: URL) {
        if s != session { flush(); session = s }
        guard pending == nil else { return }
        let new = CarouselFile.read(s)
        if new != file { file = new }
    }

    func change(_ edit: (inout CarouselFile) -> Void) {
        guard var c = file else { return }
        edit(&c)
        file = c
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        if let file, let session { CarouselFile.write(file, to: session) }
    }

    func set(_ p: PostPlatform, on: Bool, title: String) {
        guard let session else { return }
        flush()
        file = CarouselFile.set(p, on: on, in: session, title: title)
    }

    /// Files dropped or chosen for slide `i`. A video makes it a video slide; on frames or before and
    /// after they fill the pictures in order; on a slide with no picture it becomes a cover or a photo.
    func put(_ urls: [URL], on i: Int) {
        guard let session, file?.slides.indices.contains(i) == true else { return }
        let names = urls.compactMap { CarouselFile.adopt($0, in: session) }
        guard let first = names.first else { return }
        urls.forEach { SlidePictures.shared.forget($0) }
        change { c in
            var s = c.slides[i]
            if s.layout.showsItems {
                for (n, m) in names.prefix(4).enumerated() {
                    if s.items.indices.contains(n) { s.items[n].media = m; s.items[n].at = nil } else { s.items.append(SlideItem(media: m)) }
                }
            } else {
                s.media = first
                s.at = nil
                if SlidePictures.isVideo(urls[0]) { s.layout = .video; s.start = nil; s.end = nil }
                else if !s.layout.showsMedia || s.layout == .video { s.layout = i == 0 || !s.title.isEmpty ? .cover : .photo }
            }
            c.slides[i] = s
        }
    }

    /// A template's slides in place of these.
    func start(_ t: CarouselTemplate, title: String) {
        guard let session else { return }
        change { c in
            c.slides = t.slides(session, title: title)
            c.look = t.look
        }
        flush()
    }
}

// MARK: - Export

enum CarouselExport {
    /// The slides at the app's size: PNGs (and an MP4 for an Instagram video slide), or for LinkedIn
    /// the PDF. Returns what it wrote, relative to the session.
    @MainActor @discardableResult
    static func run(_ c: CarouselFile, place: CarouselPlace, session: URL, name: String) async throws -> String {
        let fm = FileManager.default
        let slides = c.slides
        let style = SlideStyle(c.look, accent: c.accent)
        var files: [(URL, Double?)] = []
        for s in slides {
            if let u = CarouselFile.resolve(s.media, in: session) { files.append((u, s.layout == .video ? (s.start ?? 0) : s.at)) }
            for i in s.items { if let u = CarouselFile.resolve(i.media, in: session) { files.append((u, i.at)) } }
        }
        await SlidePictures.shared.preload(files)
        func view(_ i: Int, overlay: Bool = false) -> some View {
            CarouselSlideView(slide: slides[i], index: i, total: slides.count, place: place, name: name,
                              width: place.size.width, style: style, session: session, exporting: true, overlayOnly: overlay)
        }
        if place == .linkedin {
            let rel = "posts/carousel/linkedin.pdf"
            let pdf = session.appending(path: rel)
            try fm.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
            var box = CGRect(origin: .zero, size: place.size)
            guard let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
            for i in slides.indices {
                ImageRenderer(content: view(i)).render { _, draw in
                    ctx.beginPDFPage(nil)
                    draw(ctx)
                    ctx.endPDFPage()
                }
            }
            ctx.closePDF()
            return rel
        }
        let dir = session.appending(path: place.folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Slides from an export with more slides go; nothing else in the folder is touched.
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("slide-") && ["png", "mp4"].contains(f.pathExtension) { try? fm.removeItem(at: f) }
        for i in slides.indices {
            let base = String(format: "slide-%02d", i + 1)
            if place.plays, slides[i].layout == .video, let clip = CarouselFile.resolve(slides[i].media, in: session),
               fm.fileExists(atPath: clip.path) {
                let over = fm.temporaryDirectory.appending(path: "takes-slide-\(UUID().uuidString).png")
                defer { try? fm.removeItem(at: over) }
                try png(view(i, overlay: true), to: over)
                try await video(clip, start: slides[i].start, end: slides[i].end, overlay: over, size: place.size,
                                to: dir.appending(path: base + ".mp4"))
            } else {
                try png(view(i), to: dir.appending(path: base + ".png"))
            }
        }
        return place.folder
    }

    @MainActor
    static func png(_ v: some View, to url: URL) throws {
        let r = ImageRenderer(content: v)
        r.scale = 1
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
    }

    /// The ffmpeg arguments for a video slide: the clip's part, filled to the slide, the words over it.
    /// Instagram plays up to 60 s of a carousel video.
    static func videoArgs(_ clip: URL, start: Double?, end: Double?, overlay: URL, size: CGSize, to out: URL) -> [String] {
        let s = max(0, start ?? 0)
        let len = min(60, max(0.5, (end ?? (s + 60)) - s))
        let w = Int(size.width), h = Int(size.height)
        return ["-y", "-ss", String(format: "%.3f", s), "-t", String(format: "%.3f", len), "-i", clip.path, "-i", overlay.path,
                "-filter_complex", "[0:v]scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1[b];[b][1:v]overlay=0:0,format=yuv420p[v]",
                "-map", "[v]", "-map", "0:a?", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path]
    }

    static func video(_ clip: URL, start: Double?, end: Double?, overlay: URL, size: CGSize, to out: URL) async throws {
        try await Cover.ffmpeg(videoArgs(clip, start: start, end: end, overlay: overlay, size: size, to: out))
    }
}

// MARK: - The Post tab

/// The post's media: its video, or the slides in its place. In the Post tab's toolbar.
struct CarouselMediaSwitch: View {
    let platform: PostPlatform
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        TakesSwitch(selection: Binding(get: { on }, set: set),
                    options: [(false, "Video"), (true, platform == .linkedin ? "Carousel" : "Photos")])
            .fixedSize()
            .help(platform == .linkedin ? "Post a video, or slides as a LinkedIn document (PDF)"
                  : "Post the vertical video, or slides as a TikTok photo post and an Instagram carousel")
    }
}

/// The rows for a slide and the set: layout, picture, look, templates. The toolbar's Slides menu and a
/// slide's right-click menu share them, so both keep one order.
@MainActor
enum CarouselMenu {
    static func slideRows(_ store: CarouselStore, _ i: Int, say: @escaping (String) -> Void) -> [MenuItem] {
        guard let c = store.file, c.slides.indices.contains(i) else { return [] }
        let s = c.slides[i]
        return MenuGroup("Layout", icon: s.layout.icon, detail: s.layout.name) {
            SlideLayout.allCases.flatMap { l in
                MenuButton(l.name, icon: l.icon, checked: l == s.layout) {
                    store.change { $0.slides[i].layout = l }
                    say("Slide \(i + 1) is now \(l.name.lowercased())")
                }.items
            }
        }.items
        + MenuButton(s.layout == .video ? "Choose a video…" : s.layout.showsItems ? "Choose pictures…" : "Choose a picture…",
                     icon: "photo.on.rectangle") { choose(store, i, say: say) }.items
        + (s.files.isEmpty ? [] : MenuButton("Remove the picture", icon: "xmark.circle") {
            store.change { c in c.slides[i].media = ""; c.slides[i].at = nil; for n in c.slides[i].items.indices { c.slides[i].items[n].media = "" } }
            say("Removed the picture on slide \(i + 1)")
        }.items)
    }

    static func lookRows(_ store: CarouselStore, say: @escaping (String) -> Void) -> [MenuItem] {
        let look = store.file?.look ?? .takes
        return MenuGroup("Look", icon: "paintpalette", detail: look.name) {
            CarouselLook.allCases.flatMap { l in
                MenuButton(l.name, detail: l.detail, checked: l == look) {
                    store.change { $0.look = l }
                    say("The slides use the \(l.name) look")
                }.items
            }
        }.items
    }

    static func templateRows(_ ask: @escaping (CarouselTemplate) -> Void) -> [MenuItem] {
        MenuGroup("Start from", icon: "square.on.square") {
            CarouselTemplate.allCases.flatMap { t in MenuButton(t.name, detail: t.detail) { ask(t) }.items }
        }.items
    }

    /// A picture or video from the session's folder (or anywhere), for slide `i`.
    static func choose(_ store: CarouselStore, _ i: Int, say: @escaping (String) -> Void) {
        guard let session = store.session, let s = store.file?.slides[safe: i] else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = s.layout.showsItems
        panel.canChooseDirectories = false
        panel.allowedContentTypes = s.layout == .video ? [.movie] : [.image, .movie]
        let stills = session.appending(path: "stills")
        panel.directoryURL = FileManager.default.fileExists(atPath: stills.path) ? stills : session
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.put(panel.urls, on: i)
        say("Put \(panel.urls.map(\.lastPathComponent).joined(separator: ", ")) on slide \(i + 1)")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The Slides menu in the Post tab's toolbar while the slides are on: the shown slide's layout and
/// picture, the look, and a template to start again from.
struct CarouselSlidesMenu: View {
    @ObservedObject var store: CarouselStore
    let picked: Int
    let title: String
    let say: (String) -> Void
    @State private var asking: CarouselTemplate?

    var body: some View {
        TakesMenuButton(width: 260, help: "Layout, picture and look of the slides") {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack").font(.system(size: 12, weight: .medium))
                Text("Slide \(picked + 1)").font(Theme.sans(12, .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
        } content: {
            MenuLabel("Slide \(picked + 1)")
            CarouselMenu.slideRows(store, picked, say: say)
            MenuDivider()
            CarouselMenu.lookRows(store, say: say)
            CarouselMenu.templateRows { asking = $0 }
        }
        .sheet(item: $asking) { t in
            TakesConfirm(title: "Start from \(t.name)?",
                         message: "\(t.detail). It takes the place of the \(store.file?.slides.count ?? 0) slides you have now.",
                         confirm: "Start from \(t.name)",
                         onConfirm: {
                             store.start(t, title: title)
                             say("Started the slides from the \(t.name) template: \(store.file?.slides.count ?? 0) slides")
                             asking = nil
                         },
                         onCancel: { asking = nil })
        }
    }
}

/// The slides down the left of the post, as the design has them (2026-10-26): a picture of each
/// slide, × on hover to delete one, + Add at the end. Click a slide to show it in the post; right-click
/// for its layout and picture; drop a picture on it.
struct CarouselRail: View {
    @ObservedObject var store: CarouselStore
    let platform: PostPlatform
    @Binding var picked: Int
    let say: (String) -> Void
    @AppStorage("linkedinName") private var name = "You"
    @State private var hover: Int?

    var body: some View {
        if let c = store.file {
            let i = min(picked, max(0, c.slides.count - 1))
            VStack(alignment: .leading, spacing: 10) {
                Text("\(c.slides.count) \(platform == .linkedin ? "pages" : "photos")".uppercased())
                    .font(Theme.sans(11, .bold)).tracking(0.6).foregroundStyle(Theme.muted)
                    .padding(.leading, 20)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(c.slides.enumerated()), id: \.offset) { n, s in row(c, n, s, i) }
                        HStack(spacing: 6) {
                            Color.clear.frame(width: 14)
                            Button(action: { add(c) }) {
                                Text("+ Add").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(platform == .linkedin ? "Add a page before the last one" : "Add a photo before the last one")
                        }
                    }
                    .padding(.top, 6).padding(.bottom, 16)
                }
            }
            .padding(.top, 16).padding(.leading, 10).padding(.trailing, 12)
            .frame(width: 108)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.paper)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
    }

    private func row(_ c: CarouselFile, _ n: Int, _ s: CarouselSlide, _ i: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n + 1)").font(Theme.sans(11, .semibold)).monospacedDigit()
                .foregroundStyle(n == i ? Theme.ink : Theme.faint)
                .frame(width: 14, alignment: .trailing).padding(.top, 2)
            Button {
                withAnimation(Theme.motion) { picked = n }
                say("Picked slide \(n + 1): “\(s.title)”")
            } label: {
                CarouselSlideView(slide: s, index: n, total: c.slides.count, place: .instagram, name: name, width: 66,
                                  style: store.style, session: store.session, exporting: true)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(n == i ? Theme.accent : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Slide \(n + 1): \(s.layout.name). Right-click for its layout and picture.")
            .takesContextMenu { CarouselMenu.slideRows(store, n, say: say) }
            .dropDestination(for: URL.self) { urls, _ in
                store.put(urls, on: n)
                say("Put \(urls.map(\.lastPathComponent).joined(separator: ", ")) on slide \(n + 1)")
                return true
            }
            .overlay(alignment: .topTrailing) {
                if c.slides.count > 2 && hover == n {
                    Button { delete(c, n) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(CarouselSlideView.navy))
                            .shadow(color: Theme.shadow, radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Delete slide \(n + 1)")
                    .offset(x: 4, y: -4)
                    .transition(.opacity)
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h ? n : (hover == n ? nil : hover) } }
    }

    private func add(_ c: CarouselFile) {
        // Before the last slide: the last one asks for the follow and stays last.
        let at = max(0, c.slides.count - 1)
        withAnimation(Theme.motion) {
            store.change { $0.slides.insert(CarouselSlide(kicker: "\(at)", title: "New slide"), at: at) }
            picked = at
        }
        say("Added slide \(at + 1)")
    }

    private func delete(_ c: CarouselFile, _ n: Int) {
        let t = c.slides[n].title
        withAnimation(Theme.motion) {
            store.change { $0.slides.remove(at: n) }
            if picked >= n && picked > 0 { picked -= 1 }
        }
        hover = nil
        say("Deleted slide \(n + 1): “\(t)”")
    }
}

/// Export in the Post tab's toolbar while the slides are on: the PDF for LinkedIn, the photos for
/// TikTok and Instagram. Shows them in Finder.
struct CarouselExportButton: View {
    @ObservedObject var store: CarouselStore
    let platform: PostPlatform
    var places: [VerticalPlace] = []
    let say: (String) -> Void
    @AppStorage("linkedinName") private var name = "You"
    @State private var exporting = false

    private var targets: [CarouselPlace] { platform == .linkedin ? [.linkedin] : CarouselPlace.photos(places) }

    var body: some View {
        Button(exporting ? "Exporting…" : platform == .linkedin ? "Export PDF" : "Export photos") { export() }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .disabled(exporting || (store.file?.slides.isEmpty ?? true) || targets.isEmpty)
            .help(platform == .linkedin ? "One PDF. Upload it as a document post."
                  : targets.isEmpty ? "Shorts has no photo posts. Turn on TikTok or Reels."
                  : "9:16 photos for TikTok, 3:4 for Instagram. A video slide is an MP4 for Instagram.")
    }

    private func export() {
        guard let c = store.file, let session = store.session else { return }
        store.flush()
        exporting = true
        say("Exporting the slides for " + targets.map(\.name).joined(separator: " and "))
        Task { @MainActor in
            defer { exporting = false }
            do {
                var wrote: [String] = []
                for t in targets { wrote.append(try await CarouselExport.run(c, place: t, session: session, name: name)) }
                say("Exported " + wrote.joined(separator: " and "))
                NSWorkspace.shared.activateFileViewerSelecting(wrote.map { session.appending(path: $0) })
            } catch {
                say("Could not export the slides: \(error.localizedDescription)")
            }
        }
    }
}

extension CarouselFile {
    /// What the vertical post's photos need you to know: Shorts gets the video, TikTok wants a sound.
    static func notes(_ places: [VerticalPlace]) -> [String] {
        (places.contains(.shorts) ? ["Shorts has no photo posts. It gets the video."] : [])
            + (places.contains(.tiktok) ? ["Add a sound in TikTok when you post. Photo posts with a sound get more views."] : [])
    }
}

/// The slides where the post's video would be: full width, a page tag, a thin progress line.
/// Click the left or right half to flip. LinkedIn's document post; Instagram's carousel.
struct CarouselPager: View {
    let slides: [CarouselSlide]
    let place: CarouselPlace
    let name: String
    @Binding var index: Int
    var width: CGFloat
    var style = SlideStyle(.takes)
    var session: URL? = nil
    var flipped: (Int) -> Void = { _ in }
    /// Typed in place: the slide at an index changed.
    var edit: ((Int, CarouselSlide) -> Void)? = nil
    /// Files dropped on the slide at an index.
    var drop: ((Int, [URL]) -> Void)? = nil
    @State private var hoverEdge: Int?

    var body: some View {
        let total = slides.count
        let i = min(index, max(0, total - 1))
        Group {
            if slides.indices.contains(i) {
                CarouselSlideView(slide: slides[i], index: i, total: total, place: place, name: name, width: width,
                                  style: style, session: session, edit: edit.map { e in { e(i, $0) } })
                    .id(i).transition(.opacity)
            }
        }
        .frame(width: width, height: width / place.ratio)
        .dropDestination(for: URL.self) { urls, _ in
            guard let drop else { return false }
            drop(i, urls)
            return true
        }
        .overlay(alignment: .topTrailing) {
            Text(place == .linkedin ? "\(i + 1) / \(total)" : "\(i + 1)/\(total)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.7), in: place == .linkedin ? AnyShape(RoundedRectangle(cornerRadius: 4)) : AnyShape(Capsule()))
                .padding(10).allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if place == .linkedin {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.12))
                    Rectangle().fill(LinkedIn.blue).frame(width: width * CGFloat(i + 1) / CGFloat(max(1, total)))
                }
                .frame(height: 3).allowsHitTesting(false)
            }
        }
        .overlay {
            // Thin edges flip, so the middle stays free to type in.
            HStack(spacing: 0) {
                if i > 0 { edge(-1, i) }
                Spacer(minLength: 0)
                if i < total - 1 { edge(1, i) }
            }
        }
    }

    private func edge(_ by: Int, _ i: Int) -> some View {
        Color.clear
            .frame(width: max(22, width * 0.08))
            .contentShape(Rectangle())
            .overlay {
                Image(systemName: by < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.92)))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .opacity(hoverEdge == by ? 1 : 0)
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hoverEdge = h ? by : nil } }
            .onTapGesture { flip(by, i) }
            .help(by < 0 ? "Previous slide" : "Next slide")
    }

    private func flip(_ by: Int, _ i: Int) {
        let n = max(0, min(slides.count - 1, i + by))
        guard n != i else { return }
        withAnimation(Theme.motion) { index = n }
        flipped(n)
    }
}

/// The vertical post's photos on a phone, as TikTok (9:16, full screen) or Instagram (a 3:4
/// carousel in the feed) shows them, with the post's caption.
struct CarouselPhotosPhone: View {
    let slides: [CarouselSlide]
    let place: CarouselPlace
    let name: String
    let caption: String
    @Binding var index: Int
    var height: CGFloat = 560
    var style = SlideStyle(.takes)
    var session: URL? = nil
    var flipped: (Int) -> Void = { _ in }
    var edit: ((Int, CarouselSlide) -> Void)? = nil
    var drop: ((Int, [URL]) -> Void)? = nil

    private var width: CGFloat { (height * 9 / 19.5).rounded() }
    private var handle: String { name.lowercased().replacingOccurrences(of: " ", with: "") }
    private var text: String { caption.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group { place == .tiktok ? AnyView(tiktok) : AnyView(instagram) }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color(white: 0.08)))
            .shadow(color: Color(red: 0.06, green: 0.16, blue: 0.34).opacity(0.16), radius: 22, y: 10)
            .environment(\.colorScheme, .light)
    }

    private var statusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 12, weight: .semibold))
            Spacer()
            HStack(spacing: 4) { Image(systemName: "cellularbars"); Image(systemName: "wifi"); Image(systemName: "battery.100") }
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 24).frame(height: 36)
    }

    private func dots(on: Color, off: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<min(slides.count, 12), id: \.self) { n in Circle().fill(n == index ? on : off).frame(width: 6, height: 6) }
        }
    }

    private func pager(_ p: CarouselPlace) -> CarouselPager {
        CarouselPager(slides: slides, place: p, name: name, index: $index, width: width, style: style, session: session,
                      flipped: flipped, edit: edit, drop: drop)
    }

    private var instagram: some View {
        VStack(spacing: 0) {
            statusBar
            HStack(spacing: 8) {
                VideoAvatar(name: name, size: 28)
                Text(handle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            pager(.instagram)
            ZStack {
                HStack(spacing: 14) {
                    Image(systemName: "heart"); Image(systemName: "bubble.right"); Image(systemName: "paperplane")
                    Spacer()
                    Image(systemName: "bookmark")
                }
                .font(.system(size: 18))
                dots(on: Color(red: 0, green: 0.58, blue: 0.96), off: Color(white: 0.78))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            (Text(handle + " ").fontWeight(.semibold) + Text(text))
                .font(.system(size: 13)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .background(.white)
    }

    private var tiktok: some View {
        ZStack {
            Color.black
            pager(.tiktok)
            VStack(spacing: 0) {
                statusBar
                HStack(spacing: 16) {
                    Text("Following").opacity(0.7)
                    VStack(spacing: 3) { Text("For You").fontWeight(.bold); Capsule().fill(.white).frame(width: 18, height: 2) }
                }
                .font(.system(size: 14, weight: .semibold))
                Spacer()
                dots(on: .white, off: .white.opacity(0.45)).padding(.bottom, 12)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: 14, weight: .bold))
                        Text(text).font(.system(size: 13)).lineLimit(2)
                        HStack(spacing: 5) {
                            Image(systemName: "music.note").font(.system(size: 11))
                            Text("Add a sound in TikTok").font(.system(size: 12))
                        }
                    }
                    Spacer(minLength: 56)
                }
                .padding(.horizontal, 12).padding(.bottom, 24)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .allowsHitTesting(false)
            VStack(spacing: 18) {
                VideoAvatar(name: name, size: 38).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                Image(systemName: "heart.fill").font(.system(size: 26))
                Image(systemName: "ellipsis.bubble.fill").font(.system(size: 24))
                Image(systemName: "bookmark.fill").font(.system(size: 22))
                Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 22))
            }
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 10).padding(.bottom, 140)
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
    }
}
