import AppKit
import AVFoundation
import CryptoKit
import SwiftUI

// The LinkedIn post that goes with the session's video, written by Claude (MCP `set_post`) or by
// The user in the post tab, which shows it as it will look in the LinkedIn feed:
//
//   posts/linkedin.md            the post text, with optional front matter:
//       media: edits/x-v3.mp4             the video; without it the newest edit shows
//       status: ready                     draft (no field) | ready | scheduled | posted
//       at: 2026-10-01T09:00:00-07:00     when it goes out (the user sets it with [schedule])
//       tz: America/Los_Angeles           the time zone he picked for it
//       scheduled_at / scheduled_hash     what Claude scheduled on LinkedIn (MCP set_post_status)
//       url                               the live post
//   posts/variants/, posts/hooks.json, posts/history/   see PostDrafts.swift
//
// Comments on the post are text comments on "posts/linkedin.md", like script comments: a quote,
// or no quote for the whole post.
//
// The X post sits next to it (2026-09-29): posts/x.md, with its variants, hooks and history in
// posts/x/. A thread is one file: the tweets separated by a line with only "---".

enum PostPlatform: String, CaseIterable, Identifiable {
    case linkedin, x, youtube, vertical, article
    var id: String { rawValue }
    /// The platforms the app shows: the article only where the blog is on (Features.blog).
    static let shown: [PostPlatform] = allCases.filter { Features.blog || $0 != .article }
    /// The remembered side of the post tab, or LinkedIn when that side is not shown.
    static func stored(_ raw: String) -> PostPlatform {
        PostPlatform(rawValue: raw).flatMap { shown.contains($0) ? $0 : nil } ?? .linkedin
    }
    var name: String {
        switch self {
        case .linkedin: "LinkedIn"
        case .x: "X"
        case .youtube: "YouTube"
        case .vertical: "Vertical"
        case .article: "Article"
        }
    }
    /// The main post, relative to the session.
    var rel: String { self == .linkedin ? "posts/linkedin.md" : "posts/\(rawValue).md" }
    /// Where its variants, hooks and history live.
    var dir: String { self == .linkedin ? "posts" : "posts/\(rawValue)" }
    /// LinkedIn's limit for a post; X Premium's for one tweet; YouTube's for a description;
    /// Instagram's for a caption (the shortest of the three vertical places).
    var limit: Int {
        switch self {
        case .linkedin: 3000
        case .x: 25000
        case .youtube: 5000
        case .vertical: 2200
        case .article: 200_000
        }
    }
    var color: Color {
        switch self {
        case .linkedin: LinkedIn.blue
        case .x: XFeed.ink
        case .youtube: YouTube.red
        case .vertical: .black
        case .article: ArticleLook.orange
        }
    }
    /// The video shape the platform wants.
    var wantsVertical: Bool? {
        switch self {
        case .youtube: false
        case .vertical: true
        default: nil
        }
    }
    /// It has a title above the text: the video title on YouTube, the Shorts title.
    var hasTitle: Bool { self == .youtube || self == .vertical }

    /// The platform whose post file this is (main or variant), if it is one.
    static func of(rel: String) -> PostPlatform? {
        for p in [PostPlatform.x, .youtube, .vertical, .article] where rel == p.rel || rel.hasPrefix(p.dir + "/") { return p }
        if rel == PostPlatform.linkedin.rel || rel.hasPrefix("posts/variants/") { return .linkedin }
        return nil
    }
}

/// The places one vertical video goes, with one caption (posts/vertical.md, front matter `on`).
enum VerticalPlace: String, CaseIterable, Identifiable {
    case tiktok, reels, shorts
    var id: String { rawValue }
    var name: String {
        switch self {
        case .tiktok: "TikTok"
        case .reels: "Reels"
        case .shorts: "Shorts"
        }
    }
    /// The PlatformLogo name.
    var logo: String {
        switch self {
        case .tiktok: "TikTok"
        case .reels: "Instagram"
        case .shorts: "YouTube"
        }
    }
    /// Instagram allows five hashtags on a post (since December 2025).
    static let reelsHashtags = 5
    /// YouTube's limit for a title, Shorts included.
    static let titleLimit = 100
}

enum PostFile {
    static let rel = "posts/linkedin.md"
    /// LinkedIn's limit for a post.
    static let limit = 3000
    /// The feed shows this many lines, then "…more".
    static let feedLines = 3

    /// Front matter keys in the order they are written. The MCP server uses the same order.
    static let fields = ["title", "media", "on", "status", "at", "tz", "scheduled_at", "scheduled_hash", "url"]

    enum Status: String, CaseIterable { case draft, ready, scheduled, posted }

    struct Content: Equatable {
        var text: String
        var meta: [String: String] = [:]

        init(text: String, media: String? = nil) {
            self.text = text
            if let media { meta["media"] = media }
        }

        init(text: String, meta: [String: String]) {
            self.text = text
            self.meta = meta
        }

        var media: String? {
            get { meta["media"] }
            set { meta["media"] = newValue }
        }
        /// YouTube: the video title. Vertical: the Shorts title (empty: YouTube takes the first line).
        var title: String {
            get { meta["title"] ?? "" }
            set { meta["title"] = newValue.isEmpty ? nil : newValue }
        }
        /// Vertical: where the video goes. No field means all three.
        var places: [VerticalPlace] {
            get {
                guard let raw = meta["on"] else { return VerticalPlace.allCases }
                let on = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                return VerticalPlace.allCases.filter { on.contains($0.rawValue) }
            }
            set {
                meta["on"] = newValue.count == VerticalPlace.allCases.count ? nil
                    : newValue.isEmpty ? "none" : VerticalPlace.allCases.filter(newValue.contains).map(\.rawValue).joined(separator: ", ")
            }
        }
        var status: Status {
            get { meta["status"].flatMap(Status.init(rawValue:)) ?? .draft }
            set { meta["status"] = newValue == .draft ? nil : newValue.rawValue }
        }
        var tz: TimeZone { meta["tz"].flatMap(TimeZone.init(identifier:)) ?? .current }
        var at: Date? { meta["at"].flatMap(PostFile.date) }

        /// Sets the time and its zone. nil takes it out of the calendar.
        mutating func plan(_ date: Date?, in zone: TimeZone) {
            meta["at"] = date.map { PostFile.iso($0, zone) }
            meta["tz"] = date == nil ? nil : zone.identifier
        }

        /// Scheduled on LinkedIn, but the time or the text changed since: Claude has to update it.
        var needsUpdate: Bool {
            guard status == .scheduled else { return false }
            return meta["scheduled_at"].flatMap(PostFile.date) != at || meta["scheduled_hash"] != PostFile.hash(text)
        }
    }

    static func iso(_ date: Date, _ zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Runs inside sorts and on every sidebar draw: one formatter, made once.
    static func date(_ s: String) -> Date? { isoFormatter.date(from: s) }
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The same hash as the MCP server: sha1 of the trimmed text, 12 hex digits.
    static func hash(_ text: String) -> String {
        let data = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    static func url(_ session: URL, _ p: PostPlatform = .linkedin) -> URL { session.appending(path: p.rel) }

    static func read(_ session: URL, _ p: PostPlatform = .linkedin) -> Content? {
        guard let raw = try? String(contentsOf: url(session, p), encoding: .utf8) else { return nil }
        let (fields, body) = FrontMatter.parse(raw)
        return Content(text: body, meta: fields.filter { !$0.value.isEmpty })
    }

    static func render(_ c: Content) -> String {
        let meta = c.meta.filter { !$0.value.isEmpty }
        guard !meta.isEmpty else { return c.text }
        let known = fields.compactMap { k in meta[k].map { (k, $0) } }
        let other = meta.filter { !fields.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return FrontMatter.render(known + other, c.text)
    }

    /// Changes the front matter on disk and keeps the text there.
    static func update(_ session: URL, _ p: PostPlatform = .linkedin, _ change: (inout Content) -> Void) {
        guard var c = read(session, p) else { return }
        change(&c)
        write(c, to: session, p)
    }

    static func write(_ c: Content, to session: URL, _ p: PostPlatform = .linkedin) {
        let u = url(session, p)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? render(c).write(to: u, atomically: true, encoding: .utf8)
    }

    /// The picked media, else (X) the LinkedIn post's pick, else the newest edited video, else the
    /// newest thumbnail. YouTube and Vertical skip the LinkedIn pick: it may be the wrong shape.
    /// The MCP server picks the same.
    static func media(_ c: Content?, in session: URL, _ p: PostPlatform = .linkedin) -> URL? {
        if let m = c?.media {
            let u = session.appending(path: m)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if p == .x, let m = read(session)?.media {
            let u = session.appending(path: m)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // Vertical: only an edit that is taller than wide. A wide edit or a thumbnail drew an empty
        // phone, as if a vertical post existed (2026-10-04); with none, the tab shows VerticalEmpty.
        if p == .vertical { return newestPortrait(session.appending(path: "edits")) }
        return newest(session.appending(path: "edits"), .video) ?? newest(session.appending(path: "thumbnails"), .image)
    }

    /// The newest video in `dir` whose frame is taller than wide, as it plays (rotation counted).
    static func newestPortrait(_ dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { Asset.kind(of: $0) == .video }
            .sorted { (Store.modified($0) ?? .distantPast) > (Store.modified($1) ?? .distantPast) }
            .first { isPortrait($0) }
    }

    private static var portraitCache: [String: Bool] = [:]
    private static let portraitLock = NSLock()

    /// Reads the video track's size once per file and version (path + modified date). The read
    /// runs outside the lock, so the main thread never waits for a read on another thread.
    static func isPortrait(_ url: URL) -> Bool {
        let key = url.path + "|" + String(Store.modified(url)?.timeIntervalSince1970 ?? 0)
        portraitLock.lock()
        let hit = portraitCache[key]
        portraitLock.unlock()
        if let hit { return hit }
        var portrait = false
        if let track = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            portrait = abs(r.height) > abs(r.width)
        }
        portraitLock.lock()
        portraitCache[key] = portrait
        portraitLock.unlock()
        return portrait
    }

    /// Reads the shape of every edit in the library in the background after launch. The first read
    /// on the main thread cost 60–130 ms when a session's Post or Assets tab opened (2026-10-06).
    static func warmPortraits(_ root: URL) {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let kids = { (u: URL) in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
            for project in kids(root) {
                for session in kids(project) {
                    for f in kids(session.appending(path: "edits")) where Asset.kind(of: f) == .video { _ = isPortrait(f) }
                }
            }
        }
    }

    /// Picks the video or image the post shows (`rel` inside the session). nil goes back to the
    /// newest edit. With no post yet, it starts an empty one.
    static func pickMedia(_ rel: String?, in session: URL, _ p: PostPlatform = .linkedin) {
        if var c = read(session, p) {
            c.media = rel
            write(c, to: session, p)
        } else if let rel {
            write(Content(text: "", media: rel), to: session, p)
        }
    }

    /// The tweets of an X post: the text split at lines that hold only "---". Same as the server.
    static func tweets(_ text: String, keepEmpty: Bool = false) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = [], cur: [String] = []
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces) == "---" { out.append(cur.joined(separator: "\n")); cur = [] } else { cur.append(l) }
        }
        out.append(cur.joined(separator: "\n"))
        let trimmed = out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if keepEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : trimmed }
        return trimmed.filter { !$0.isEmpty }
    }

    /// Tweets back into one file.
    static func thread(_ tweets: [String]) -> String {
        tweets.map { $0.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func newest(_ dir: URL, _ kind: AssetKind) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { Asset.kind(of: $0) == kind }
            .max { (Store.modified($0) ?? .distantPast) < (Store.modified($1) ?? .distantPast) }
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"(?<![\w/#@])[#@][\p{L}\p{N}_]+|https?://\S*[^\s.,;:!?)]"#)

    /// Hashtags, mentions and links. LinkedIn shows them in blue.
    static func tags(_ text: String) -> [NSRange] {
        tagPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}

/// The post of the open session and its variants. `draft` is the tab on show: "main" or a variant
/// slug. The user's typing is saved after a short pause; a change on disk (Claude's set_post) shows
/// unless he has unsaved typing. His edits go to history before he starts, every 5 minutes while he
/// types, and when he leaves the session.
@MainActor
final class PostStore: ObservableObject {
    @Published private(set) var content: PostFile.Content?
    @Published private(set) var variants: [Variant] = []
    @Published var draft = "main"
    @Published private(set) var historyCount = 0
    private(set) var session: URL?
    private var stamp: Date?
    private var variantStamps: [String: Date] = [:]
    private var pending: Task<Void, Never>?
    private var dirty: Set<String> = []
    private var savedAt: [String: Date] = [:]
    let platform: PostPlatform

    init(_ platform: PostPlatform = .linkedin) { self.platform = platform }

    var text: String { text(of: draft) }

    func text(of d: String) -> String {
        d == "main" ? content?.text ?? "" : variants.first { $0.slug == d }?.text ?? ""
    }

    func name(of d: String) -> String {
        d == "main" ? "Main" : variants.first { $0.slug == d }?.name ?? SessionDoc.titleFromFolder(d)
    }

    func load(_ s: URL) {
        if s != session { close(); draft = "main" } else if pending != nil { return }
        let fresh = s != session
        session = s
        let m = Store.modified(PostFile.url(s, platform))
        if fresh || m != stamp {
            stamp = m
            let c = PostFile.read(s, platform)
            if c != content { content = c }
        }
        let stamps = PostFile.variantStamps(s, platform)
        if fresh || stamps != variantStamps {
            variantStamps = stamps
            let vs = PostFile.variants(s, platform)
            if vs != variants { variants = vs }
            if draft != "main" && !variants.contains(where: { $0.slug == draft }) { draft = "main" }
        }
        let n = PostFile.versionCount(s, platform)
        if n != historyCount { historyCount = n }
    }

    func edit(_ text: String) {
        guard let session, text != self.text else { return }
        if !dirty.contains(draft) {
            PostFile.snapshot(session, draft: draft, text: self.text, note: "Before editing", platform)
            dirty.insert(draft)
            savedAt[draft] = .now
        }
        if draft == "main" {
            guard var c = content else { return }
            c.text = text
            content = c
        } else if let i = variants.firstIndex(where: { $0.slug == draft }) {
            variants[i].text = text
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { self?.flush() }
        }
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard let session else { return }
        if let content, let disk = PostFile.read(session, platform), disk.text != content.text {
            let saved = PostFile.Content(text: content.text, meta: disk.meta)  // the calendar may have changed the rest
            PostFile.write(saved, to: session, platform)
            stamp = Store.modified(PostFile.url(session, platform))
            self.content = saved
        }
        let disk = Dictionary(PostFile.variants(session, platform).map { ($0.slug, $0.text) }, uniquingKeysWith: { a, _ in a })
        for v in variants where dirty.contains(v.slug) && disk[v.slug] != nil && disk[v.slug] != v.text {
            PostFile.writeVariant(v, in: session, platform)
        }
        variantStamps = PostFile.variantStamps(session, platform)
        for d in dirty where Date().timeIntervalSince(savedAt[d] ?? .now) > 300 { save(d, note: "Edited") }
    }

    /// Saves what he typed and puts the edited drafts in history. Leaving the session or the tab.
    func close() {
        flush()
        for d in dirty { save(d, note: "Edited") }
        dirty.removeAll()
    }

    private func save(_ d: String, author: String = "user", note: String) {
        guard let session else { return }
        PostFile.snapshot(session, draft: d, text: text(of: d), author: author, note: note, platform)
        savedAt[d] = .now
        historyCount = PostFile.versionCount(session, platform)
    }

    /// Changes status or time, saving his typing first.
    func update(_ change: (inout PostFile.Content) -> Void) {
        guard let session else { return }
        flush()
        PostFile.update(session, platform, change)
        stamp = nil
        load(session)
    }

    /// A post to write by hand: empty, or starting from a text (the X post from the LinkedIn one).
    func create(in s: URL, text: String = "") {
        session = s
        content = PostFile.Content(text: text, media: nil)
        PostFile.write(content!, to: s, platform)
        stamp = Store.modified(PostFile.url(s, platform))
    }

    // MARK: Variants, hooks, history

    /// A copy of the post on show, as a new tab.
    func newVariant() {
        guard let session else { return }
        flush()
        let taken = Set(variants.map(\.slug))
        var n = variants.count + 1
        while taken.contains("variant-\(n)") { n += 1 }
        let v = Variant(slug: "variant-\(n)", name: "Variant \(n)", author: "user", note: "",
                        created: SessionDoc.iso.string(from: .now), text: text)
        PostFile.writeVariant(v, in: session, platform)
        variants.append(v)
        variantStamps = PostFile.variantStamps(session, platform)
        draft = v.slug
    }

    func rename(_ slug: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !clean.isEmpty, let i = variants.firstIndex(where: { $0.slug == slug }) else { return }
        variants[i].name = clean
        PostFile.writeVariant(variants[i], in: session, platform)
        variantStamps = PostFile.variantStamps(session, platform)
    }

    func delete(_ slug: String) {
        guard let session else { return }
        flush()
        save(slug, note: "Before deleting the variant")
        dirty.remove(slug)
        try? FileManager.default.trashItem(at: PostFile.variantURL(slug, in: session, platform), resultingItemURL: nil)
        variants.removeAll { $0.slug == slug }
        variantStamps = PostFile.variantStamps(session, platform)
        if draft == slug { draft = "main" }
    }

    /// The variant becomes the post that goes out. The old main stays in history.
    func promote(_ slug: String) {
        guard let v = variants.first(where: { $0.slug == slug }), content != nil else { return }
        flush()
        save("main", note: "Before using “\(v.name)” as main")
        draft = "main"
        content?.text = v.text
        dirty.insert("main")
        flush()
        dirty.remove("main")
        save("main", author: v.author.isEmpty ? "user" : v.author, note: "Used “\(v.name)” as main")
        delete(slug)
    }

    func restore(_ version: ScriptVersion) {
        let target = version.draft == "main" || variants.contains(where: { $0.slug == version.draft }) ? version.draft : "main"
        let when = version.created.formatted(date: .abbreviated, time: .shortened)
        flush()
        save(target, note: "Before restoring \(when)")
        draft = target
        replace(with: version.text())
        save(target, note: "Restored \(when)")
    }

    /// Puts the hook in the first paragraph of the post on show.
    func use(_ hook: Hook, known: [String]) {
        flush()
        save(draft, note: "Before a new hook")
        replace(with: HookStore.apply(hook.text, to: text, known: known))
    }

    private func replace(with new: String) {
        if draft == "main" { content?.text = new } else if let i = variants.firstIndex(where: { $0.slug == draft }) {
            variants[i].text = new
        }
        dirty.insert(draft)
        flush()
    }
}

// MARK: - The pane

/// The post tab: the LinkedIn post or the X post of the session, switched in the toolbar. The
/// choice is remembered; opening posts/x.md from Claude's link shows the X side.
struct PostPane: View {
    var doc: SessionDoc
    @AppStorage("postPlatform") private var raw = PostPlatform.linkedin.rawValue
    /// The side before the last switch: the new pane's switch slides its pill over from it.
    @State private var from: String?

    var body: some View {
        let _ = Perf.body("PostPane")
        if let side = Plugins.postSide(raw) {
            // A side a plugin adds.
            side.pane(doc.url, AnyView(PostSideSwitch(doc: doc, current: raw, from: from, pick: pick))).id(raw)
        } else {
            let p = PostPlatform.stored(raw)
            PlatformPostPane(doc: doc, platform: p, from: from, pick: pick).id(p)
        }
    }

    private func pick(_ id: String) {
        from = Plugins.postSide(raw) != nil ? raw : PostPlatform.stored(raw).rawValue
        raw = id
    }
}

/// One platform's post as its feed card. Click the text to edit it. Select text to comment.
struct PlatformPostPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var paneShown
    var doc: SessionDoc
    let platform: PostPlatform
    let from: String?
    let pick: (String) -> Void
    @StateObject private var post: PostStore
    @StateObject private var comments = CommentStore()
    @State private var expanded = false
    @State private var showComponents = false
    @State private var insertComponent: (md: String, token: Int)?
    @State private var selection = ""
    @State private var draft: ReviewPlayer.Draft?
    @State private var focused: String?
    @State private var reveal: (quote: String, token: Int)?
    @State private var focusToken = 0
    @State private var media: URL?
    /// The post was read once; the card reveals after that, not on the empty first frame.
    @State private var loaded = false
    @State private var showHistory = false
    @State private var firstComment = ""
    @StateObject private var hooks: HookStore
    /// The hook under the pointer in the hooks drawer: the post shows it until the pointer leaves.
    @State private var previewHook: Hook?

    init(doc: SessionDoc, platform: PostPlatform, from: String? = nil, pick: @escaping (String) -> Void) {
        self.doc = doc
        self.platform = platform
        self.from = from
        self.pick = pick
        _post = StateObject(wrappedValue: PostStore(platform))
        _hooks = StateObject(wrappedValue: HookStore(file: { PostFile.hooksURL($0, platform) }))
    }

    /// The text on show: the post, or the post with the hovered hook in place.
    private var shownText: Binding<String> {
        Binding(get: {
            if let h = previewHook { return HookStore.apply(h.text, to: post.text, known: hooks.hooks.map(\.text)) }
            return post.text
        }, set: { if previewHook == nil { post.edit($0) } })
    }

    private var file: String { PostFile.rel(of: post.draft, platform) }
    private var postComments: [Comment] { comments.on(file) }

    var body: some View {
        let _ = Perf.body("PlatformPostPane")
        ZStack(alignment: .top) {
            Group {
            if post.content == nil {
                empty.padding(.top, 56)
            } else {
                feedView
                    .overlay(alignment: .topTrailing) {
                        PostSideTabs(hooks: hooks, current: HookStore.current(post.text, hooks.hooks),
                                     comments: postComments, focused: focused,
                                     preview: { h in withAnimation(Theme.motion) { previewHook = h } },
                                     use: { h in
                                         previewHook = nil
                                         withAnimation(Theme.spring) {
                                             post.use(h, known: hooks.hooks.map(\.text))
                                             hooks.markChosen(h, in: doc.url)
                                         }
                                     },
                                     pickComment: { c in
                                         withAnimation(Theme.motion) { draft = nil; focused = c.id; expanded = true }
                                         if let q = c.quote { reveal = (q, (reveal?.token ?? 0) + 1) }
                                     })
                            .padding(.top, 110).padding(.trailing, 16)
                    }
            }
            }
            .reveal(on: post.draft, ready: loaded, settle: media == nil ? 0 : 0.18)
            toolbar
        }
        .background(Theme.canvas)
        .onAppear { load() }
        .onDisappear { post.close() }
        .onChange(of: paneShown) { _, on in if on { load() } else { post.close(); draft = nil } }
        .onChange(of: doc.url) { load(); draft = nil; focused = nil; expanded = false }
        .onChange(of: post.draft) { draft = nil; focused = nil; selection = ""; previewHook = nil }
        .onFilesChanged(in: doc.url) { load() }
        .onExitCommand { withAnimation(Theme.motion) { if draft != nil { draft = nil } else { focused = nil } } }
        .sheet(isPresented: $showHistory) {
            VersionsSheet(title: "Post history", subtitle: doc.meta.title,
                          empty: "Takes saves a version whenever the chat changes the post, and while you edit it.",
                          load: { post.close(); return PostFile.versions(doc.url, platform) },
                          draftName: post.name(of:), restore: post.restore)
        }
    }

    @ViewBuilder private var feedView: some View {
        switch platform {
        case .x: xFeedView
        case .youtube, .vertical: videoFeedView
        case .linkedin: linkedinFeedView
        case .article: articleFeedView
        }
    }

    private func saveTitle(_ t: String) { post.update { $0.title = t } }

    /// YouTube's watch page, or the vertical phone with its caption.
    private var videoFeedView: some View {
        GeometryReader { geo in
        // The phone takes the pane's height, less the bars above and the place switch below.
        let phone = min(max(geo.size.height - 76 - 40 - 60 - 28, 440), 900)
        ScrollView {
            Group {
                if platform == .youtube {
                    YouTubeCard(text: shownText, draft: post.draft, title: post.content?.title ?? "", saveTitle: saveTitle,
                                media: media, expanded: $expanded,
                                highlights: postComments.filter(\.open).compactMap(\.quote),
                                reveal: reveal, focusToken: focusToken,
                                onSelect: { selection = $0 }, onComment: startComment,
                                onExpand: { expanded = true; focusToken += 1 },
                                onCollapse: { withAnimation(Theme.motion) { expanded = false }; releaseKeys() })
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                        .shadow(color: Theme.shadow, radius: 14, y: 6)
                        .frame(maxWidth: 760)
                } else {
                    VerticalCard(text: shownText, draft: post.draft, title: post.content?.title ?? "", saveTitle: saveTitle,
                                 places: post.content?.places ?? VerticalPlace.allCases,
                                 setPlaces: { ps in post.update { $0.places = ps } },
                                 media: media, phoneHeight: phone, expanded: $expanded,
                                 highlights: postComments.filter(\.open).compactMap(\.quote),
                                 reveal: reveal, focusToken: focusToken,
                                 onSelect: { selection = $0 }, onComment: startComment,
                                 onExpand: { expanded = true; focusToken += 1 },
                                 onCollapse: { withAnimation(Theme.motion) { expanded = false }; releaseKeys() })
                }
            }
            .padding(.horizontal, 24).padding(.top, 76).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        }
        .overlay(alignment: .bottomTrailing) { commentPill }
        .overlay(alignment: .bottomLeading) { card.padding(12) }
        .animation(Theme.motion, value: selection.isEmpty)
    }

    /// The thread on X's white timeline.
    private var xFeedView: some View {
        ScrollView {
            XThreadCard(text: shownText, draft: post.draft,
                        media: media, expanded: $expanded,
                        highlights: postComments.filter(\.open).compactMap(\.quote),
                        reveal: reveal, focusToken: focusToken,
                        onSelect: { selection = $0 },
                        onComment: startComment,
                        onExpand: { expanded = true; focusToken += 1 },
                        onCollapse: { withAnimation(Theme.motion) { expanded = false }; releaseKeys() })
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                .shadow(color: Theme.shadow, radius: 14, y: 6)
                .frame(maxWidth: 600)
                .padding(.horizontal, 24).padding(.top, 76).padding(.bottom, 60)
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottomTrailing) { commentPill }
        .overlay(alignment: .bottomLeading) { card.padding(12) }
        .animation(Theme.motion, value: selection.isEmpty)
    }

    @ViewBuilder private var commentPill: some View {
        if !selection.isEmpty && draft == nil {
            Button(action: startComment) {
                Label("Comment", systemImage: "text.bubble")
                    .font(Theme.sans(12.5, .medium))
                    .padding(.horizontal, 12).frame(height: 30)
                    .foregroundStyle(Theme.paper)
                    .background(Theme.ink, in: Capsule())
                    .shadow(color: Theme.shadow, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .help("Comment on the selected text, for Takes")
            .padding(16)
            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    /// The blog's post page, written in place: one view, as the blog shows it (2026-10-04).
    private var articleFeedView: some View {
        ArticleView(markdown: shownText.wrappedValue, head: ArticleHead(post.content), session: doc.url,
                    highlights: postComments.filter(\.open).compactMap(\.quote),
                    reveal: reveal,
                    onSelect: { selection = $0 },
                    onPick: { q in
                        if let c = postComments.first(where: { $0.open && $0.quote == q }) {
                            withAnimation(Theme.motion) { draft = nil; focused = c.id }
                        }
                    },
                    onChange: { shownText.wrappedValue = $0 },
                    onHead: { title, description in
                        post.update { c in
                            c.title = title
                            c.meta["description"] = description.isEmpty ? nil : description
                        }
                    },
                    onCategory: { c in
                        post.update { $0.meta["category"] = Article.categories.first { $0.lowercased() == c } }
                    },
                    insert: insertComponent)
        .padding(.top, 52)
        .overlay(alignment: .bottomTrailing) { commentPill }
        .overlay(alignment: .bottomLeading) { card.padding(12) }
        .animation(Theme.motion, value: selection.isEmpty)
    }

    private var linkedinFeedView: some View {
        ScrollView {
            LinkedInCard(text: shownText, draft: post.draft,
                         media: media, expanded: $expanded,
                         highlights: postComments.filter(\.open).compactMap(\.quote),
                         reveal: reveal, focusToken: focusToken,
                         onSelect: { selection = $0 },
                         onComment: startComment,
                         onExpand: { expanded = true; focusToken += 1 },
                         onCollapse: { withAnimation(Theme.motion) { expanded = false }; releaseKeys() },
                         firstComment: Binding(get: { firstComment }, set: {
                             firstComment = $0
                             PostFile.writeFirstComment(doc.url, $0)
                         }))
                .overlay {
                    // The hovered hook: a warm edge while the post shows it.
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(previewHook == nil ? 0 : 0.55), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: Theme.shadow, radius: 14, y: 6)
                .frame(maxWidth: 555 * TextSize.shared.factor)
                .padding(.horizontal, 24).padding(.top, 76).padding(.bottom, 60)
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottomTrailing) { commentPill }
        .overlay(alignment: .bottomLeading) { card.padding(12) }
        .animation(Theme.motion, value: selection.isEmpty)
    }

    private func load() {
        post.load(doc.url)
        comments.load(doc.url)
        hooks.load(doc.url)
        let m = PostFile.media(post.content, in: doc.url, platform)
        if m != media { media = m }
        let c = platform == .linkedin ? PostFile.firstComment(doc.url) : ""
        if c != firstComment { firstComment = c }
        if !loaded { loaded = true }
    }

    /// The one bar of the post: platform, versions, length, and three quiet actions. It floats.
    private var toolbar: some View {
        HStack(spacing: 14) {
            PostSideSwitch(doc: doc, current: platform.rawValue, from: from, pick: { post.close(); pick($0) })
            if post.content != nil {
                PostDraftBar(post: post, showHistory: $showHistory)
                Spacer(minLength: 8)
                counter
                HStack(spacing: 2) {
                    if platform == .article {
                        Button { showComponents.toggle() } label: { Image(systemName: "square.stack.3d.up").frame(width: 30, height: 28) }
                            .help("Put one of the blog's components in, after the paragraph with the cursor")
                            .popover(isPresented: $showComponents, arrowEdge: .bottom) {
                                ArticleComponentsHelp { md in
                                    showComponents = false
                                    insertComponent = (md, (insertComponent?.token ?? 0) + 1)
                                }
                            }
                    } else {
                    Button {
                        withAnimation(Theme.motion) { expanded.toggle() }
                        if expanded { focusToken += 1 } else { releaseKeys() }
                    } label: {
                        Image(systemName: expanded ? "eye" : "pencil").frame(width: 30, height: 28)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help(expanded ? "Feed view: cut after three lines, as the feed does" : "Show the whole post and edit it")
                    }
                    if platform != .article, let media, Asset.kind(of: media) == .video {
                        CoverPicker(session: doc.url, platform: platform, video: media)
                    }
                    Button { startComment() } label: { Image(systemName: "text.bubble").frame(width: 30, height: 28) }
                        .help("Comment for Takes: on the selected text, or on the whole post")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(post.text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
                        app.show(toast: "Post copied")
                    } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 28) }
                        .help(platform == .article ? "Copy the article's markdown" : "Copy the post text, to paste into \(platform.name)")
                }
                .buttonStyle(IconButtonStyle())
                .font(.system(size: 13))
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 20).frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Rule().opacity(0.6) }
    }

    /// LinkedIn: characters of 3,000, with a ring. X: posts in the thread and the longest one.
    @ViewBuilder private var counter: some View {
        if platform == .article {
            let words = Article.words(shownText.wrappedValue)
            let minutes = Article.minutes(words: words)
            ViewThatFits(in: .horizontal) {
                Text("\(words.formatted()) words · \(minutes) min read")
                Text("\(minutes) min read")
                Color.clear.frame(width: 0)
            }
                .lineLimit(1)
                .font(Theme.sans(12)).monospacedDigit()
                .foregroundStyle(Theme.faint)
                .contentTransition(.numericText(value: Double(words)))
                .animation(Theme.spring, value: words)
                .help("Words in the article, and the reading time the blog gives it (200 words a minute)")
        } else if platform == .youtube || platform == .vertical {
            let count = shownText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count
            let over = count > platform.limit
            Text("\(count.formatted()) / \(platform.limit.formatted())")
                .font(Theme.sans(12)).monospacedDigit()
                .foregroundStyle(over ? Theme.accentInk : Theme.faint)
                .contentTransition(.numericText(value: Double(count)))
                .animation(Theme.spring, value: count)
                .help(platform == .youtube ? "Characters in the description, of YouTube's \(platform.limit.formatted())"
                                           : "Characters in the caption, of Instagram's \(platform.limit.formatted()) (TikTok and Shorts allow more)")
        } else if platform == .x {
            let ts = PostFile.tweets(post.text)
            let longest = ts.map(\.count).max() ?? 0
            Text("\(ts.count) post\(ts.count == 1 ? "" : "s") · longest \(longest)")
                .font(Theme.sans(12)).monospacedDigit()
                .foregroundStyle(longest > PostPlatform.x.limit ? Theme.accentInk : Theme.faint)
                .contentTransition(.numericText())
                .animation(Theme.motion, value: longest)
                .help("The timeline shows \(XFeed.feedCut) characters of a post, then Show more. X Premium allows \(PostPlatform.x.limit.formatted()).")
        } else {
            let count = shownText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count
            let over = count > PostFile.limit
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, CGFloat(count) / CGFloat(PostFile.limit)))
                        .stroke(over ? Theme.accent : Theme.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                Text(count.formatted())
                    .contentTransition(.numericText(value: Double(count)))
            }
            .font(Theme.sans(12)).monospacedDigit()
            .foregroundStyle(over ? Theme.accentInk : Theme.faint)
            .animation(Theme.spring, value: count)
            .help(over ? "LinkedIn cuts posts over \(PostFile.limit) characters"
                       : "\(count) characters, of LinkedIn's \(PostFile.limit.formatted())")
        }
    }

    private var empty: some View {
        let linkedin = platform != .linkedin ? PostFile.read(doc.url)?.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return VStack(spacing: 12) {
            Mascot(size: 64)
            Text(platform == .vertical ? "No vertical post yet" : "No \(platform.name) post yet")
                .font(Theme.display(28)).foregroundStyle(Theme.ink)
            Text(emptyHint)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 8) {
                // Takes drafts first: Jeremy read the empty post as "write it yourself" (2026-10-06).
                Button("Draft it with Takes") {
                    app.chats.chat(doc.url).send(draftAsk, title: doc.meta.title, onStage: nil)
                    app.chats.open = true
                }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                Button("Write one yourself") {
                    post.create(in: doc.url)
                    expanded = true
                    focusToken += 1
                }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
                if let linkedin, !linkedin.isEmpty {
                    Button("Start from the LinkedIn post") {
                        post.create(in: doc.url, text: linkedin + "\n")
                        expanded = true
                        focusToken += 1
                    }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                    .help("Copy the LinkedIn text here to cut it down for \(platform == .vertical ? "a caption" : platform.name)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GiantLogos(platform: platform).id(platform) }
    }

    private var emptyHint: String {
        switch platform {
        case .x: "Takes writes the post (one post or a thread) from your video, and it shows here as on X."
        case .youtube: "For the long wide video: Takes writes a title and a description from your video."
        case .vertical: "One caption for TikTok, Instagram Reels and YouTube Shorts, with the vertical edit. Takes writes it from your video."
        case .linkedin: "Takes writes the post from your video, and it shows here as on LinkedIn."
        case .article: "A post for your blog, shown as your blog shows it, in markdown with the blog's components. Later it goes out as a LinkedIn and an X article."
        }
    }

    /// What "Draft it with Takes" asks the chat.
    private var draftAsk: String {
        switch platform {
        case .linkedin: "Draft the LinkedIn post for this video (set_post). Use the script and the takes for what I say."
        case .x: "Draft the X post for this video (set_post platform=x): one post, or a short thread if it needs one."
        case .youtube: "Draft the YouTube title and description for this video (set_post platform=youtube)."
        case .vertical: "Draft the caption for the vertical video (set_post platform=vertical), for TikTok, Reels and Shorts."
        case .article: "Draft the blog article for this video (set_post platform=article, with title, description and category). "
            + "Read two or three of my blog posts first for my voice. Use the blog's components where they help."
        }
    }

    private func startComment() {
        let quote = selection.isEmpty ? nil : selection
        withAnimation(Theme.motion) { focused = nil; draft = ReviewPlayer.Draft(quote: quote, timed: false) }
    }

    @ViewBuilder private var card: some View {
        if let d = draft {
            Composer(draft: Composer.bind($draft, d),
                     onSend: {
                         let text = (draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                         guard !text.isEmpty else { return }
                         if let c = comments.add(text: file, quote: draft?.quote, text: text) {
                             app.show(toast: "Comment \(c.id) saved for Takes")
                         }
                         withAnimation(Theme.motion) { draft = nil }
                     },
                     onCancel: { withAnimation(Theme.motion) { draft = nil } },
                     onArea: {}, areas: false)
        } else if let id = focused, let i = postComments.firstIndex(where: { $0.id == id }) {
            let c = postComments[i]
            CommentCard(comment: c, number: i + 1,
                        onReply: { comments.reply(id, $0) },
                        onResolve: { comments.setResolved(id, c.open) },
                        onDelete: { comments.delete(id); focused = nil },
                        onClose: { withAnimation(Theme.motion) { focused = nil } },
                        onJump: { app.jump(to: doc.url.appending(path: $0), at: $1) })
        }
    }
}

/// Draft → [schedule]: pick when it goes out, right here. Ready, scheduled, posted: a pill with
/// the plan; a click opens the same panel to change it.
struct StatusControl: View {
    let content: PostFile.Content
    @ObservedObject var post: PostStore
    @State private var open = false

    var body: some View {
        Group {
            if content.status == .draft {
                Button { open = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 11.5, weight: .semibold))
                        Text("Schedule")
                    }
                }
                .buttonStyle(AccentButtonStyle(kind: .solid))
                .help("Pick when the post goes out. Then Takes schedules it on \(post.platform.name)")
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Button { open = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
                        Text(label).lineLimit(1)
                    }
                }
                .buttonStyle(AccentButtonStyle(kind: content.status == .posted ? .quiet : .accent))
                .fixedSize()
                .help(help)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SchedulePanel(content: content, post: post, close: { open = false })
        }
    }

    private var icon: String {
        content.needsUpdate ? "exclamationmark.circle" : content.status == .scheduled ? "checkmark"
            : content.status == .posted ? "paperplane" : "clock"
    }

    private var label: String {
        let when = content.at.map { PostFile.label($0, content.tz) }
        switch content.status {
        case .draft: return ""
        case .ready: return when ?? "Ready, no time"
        case .scheduled: return content.needsUpdate ? "Needs update" : when ?? "Scheduled"
        case .posted: return "Posted" + (when.map { " · " + $0 } ?? "")
        }
    }

    private var place: String { post.platform == .x ? "X" : "LinkedIn" }

    private var help: String {
        switch content.status {
        case .ready: return content.at == nil ? "Ready. Click to give it a time."
                                              : "Ready. Ask Takes to schedule your posts; it puts this one on \(place) for this time."
        case .scheduled: return content.needsUpdate
            ? "Scheduled on \(place), but you changed the time or text since. Ask Takes to update it."
            : "Scheduled on \(place). Click to change the time; Takes then moves it there too."
        default: return "Click for the time"
        }
    }
}

/// When the post goes out: a day, a time and a zone. Saving makes it ready for Claude.
struct SchedulePanel: View {
    let content: PostFile.Content
    @ObservedObject var post: PostStore
    let close: () -> Void
    @Environment(AppModel.self) var app
    @State private var date = Date()
    @State private var zoneID = TimeZone.current.identifier

    private var zone: TimeZone { TimeZone(identifier: zoneID) ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.status == .posted ? "Posted" : "When does it go out?").font(Theme.sans(15, .bold))
            DatePicker("", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical).labelsHidden()
                .environment(\.timeZone, zone)
            HStack(spacing: 8) {
                DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                    .labelsHidden().environment(\.timeZone, zone)
                Picker("", selection: Binding(get: { zoneID }, set: { id in
                    if let to = TimeZone(identifier: id) { date = PostFile.moved(date, from: zone, to: to) }
                    zoneID = id
                })) {
                    ForEach(PostFile.zones(with: zone), id: \.identifier) { z in Text(PostFile.zoneName(z)).tag(z.identifier) }
                }
                .labelsHidden()
            }
            if zone.identifier != TimeZone.current.identifier {
                Text("That is \(PostFile.label(date, .current)) here.").font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            }
            Text(content.status == .scheduled
                 ? "It is on \(post.platform.name) for \(content.at.map { PostFile.label($0, content.tz) } ?? "a time"). A new time here: ask Takes to move it."
                 : "Then tell Takes \"schedule my posts\". It schedules the post on \(post.platform.name) for this time and marks it scheduled here.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Menu {
                    if content.status == .draft {
                        Button("Ready, No Time Yet") { post.update { $0.status = .ready }; close() }
                    }
                    if content.at != nil, content.status != .posted {
                        Button("Remove the Time") { post.update { $0.plan(nil, in: $0.tz) }; close() }
                    }
                    if content.status != .draft {
                        Button("Back to Draft") { post.update { $0.status = .draft; $0.plan(nil, in: $0.tz) }; close() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                Button(content.at == nil ? "Set time" : "Save") {
                    let (d, z) = (date, zone)
                    post.update { c in
                        c.plan(d, in: z)
                        if c.status == .draft { c.status = .ready }
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AccentButtonStyle(kind: .solid))
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.paper)
        .tint(Theme.accent)
        .onAppear {
            zoneID = content.tz.identifier
            date = content.at ?? Self.nextMorning(in: content.tz)
        }
    }

    /// Tomorrow at 9:00 in the zone: a good first guess.
    static func nextMorning(in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - The card

/// LinkedIn's colours and type (the web feed, light mode).
enum LinkedIn {
    static let feed = Color(red: 0.957, green: 0.949, blue: 0.933)       // #F4F2EE
    static let card = Color.white
    static let line = Color.black.opacity(0.08)
    static let ink = Color.black.opacity(0.9)
    static let muted = Color.black.opacity(0.6)
    static let blue = Color(red: 10 / 255, green: 102 / 255, blue: 194 / 255)  // #0A66C2
    static let inkNS = NSColor(white: 0, alpha: 0.9)
    static let blueNS = NSColor(srgbRed: 10 / 255, green: 102 / 255, blue: 194 / 255, alpha: 1)
    /// The preview follows the app's text size (⌘+ / ⌘−), like the rest of Takes.
    static var textFont: NSFont { NSFont.systemFont(ofSize: 14 * TextSize.shared.factor) }
    static var lineHeight: CGFloat { (20 * TextSize.shared.factor).rounded() }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * TextSize.shared.factor, weight: weight) }

    /// Your photo, kept with the app's settings (it is not part of any session or library).
    static let photoURL: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "Takes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "linkedin-photo.jpg")
    }()

    /// The photo, read from disk once: the cards redraw on every keystroke. `photoChanged()` reloads it.
    @MainActor static var photo: NSImage? {
        if !photoLoaded { photoImage = NSImage(contentsOf: photoURL); photoLoaded = true }
        return photoImage
    }
    @MainActor static var photoImage: NSImage?
    @MainActor static var photoLoaded = false
    @MainActor static func photoChanged() { photoLoaded = false }

    /// The post text with hashtags, mentions and links in blue.
    static func styled(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        for r in PostFile.tags(text) {
            ns.addAttribute(.foregroundColor, value: blueNS, range: r)
            ns.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .semibold), range: r)
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }
}

struct LinkedInCard: View {
    @Binding var text: String
    var draft = ""
    let media: URL?
    @Binding var expanded: Bool
    let highlights: [String]
    let reveal: (quote: String, token: Int)?
    let focusToken: Int
    let onSelect: (String) -> Void
    let onComment: () -> Void
    let onExpand: () -> Void
    var onCollapse: () -> Void = {}
    /// The comment you post under it first. nil hides the section.
    var firstComment: Binding<String>?
    @AppStorage("linkedinName") private var name = "You"
    @AppStorage("linkedinHeadline") private var headline = ""
    @State private var editingProfile = false
    @State private var liked = false
    @State private var photoStamp = Date()

    private var photoURL: URL { LinkedIn.photoURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 12)
            textBlock.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
            if let media { PostMedia(url: media).padding(.top, 4) }
            counts.padding(.horizontal, 16).padding(.vertical, 8)
            Rectangle().fill(LinkedIn.line).frame(height: 1).padding(.horizontal, 16)
            actions.padding(.horizontal, 8).padding(.vertical, 4)
            if let firstComment {
                FirstCommentRow(text: firstComment, name: name, headline: headline, initials: initials, photoStamp: photoStamp)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
            }
        }
        .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .environment(\.colorScheme, .light)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(LinkedIn.font(14, .semibold)).foregroundStyle(LinkedIn.ink)
                    Text("• You").font(LinkedIn.font(14)).foregroundStyle(LinkedIn.muted)
                }
                Text(headline).font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted).lineLimit(1)
                HStack(spacing: 3) {
                    Text("Now •").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
                    Image(systemName: "globe.americas.fill").font(.system(size: 11)).foregroundStyle(LinkedIn.muted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editingProfile = true }
            .help("Change the name, headline or photo")
            Spacer(minLength: 8)
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(LinkedIn.muted)
                .padding(.top, 4)
        }
        .popover(isPresented: $editingProfile, arrowEdge: .bottom) { profileEditor }
    }

    private var avatar: some View {
        Group {
            if let img = LinkedIn.photo {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinkedIn.blue.opacity(0.85)
                    Text(initials).font(LinkedIn.font(17, .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .id(photoStamp)
        .onTapGesture { editingProfile = true }
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How you appear").font(Theme.sans(13, .bold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Headline", text: $headline, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Button("Choose photo…", action: choosePhoto)
                if FileManager.default.fileExists(atPath: photoURL.path) {
                    Button("Remove photo") {
                        try? FileManager.default.removeItem(at: photoURL)
                        LinkedIn.photoChanged()
                        photoStamp = Date()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Pick your LinkedIn profile photo"
        guard panel.runModal() == .OK, let src = panel.url, let img = NSImage(contentsOf: src),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpg.write(to: photoURL, options: .atomic)
        LinkedIn.photoChanged()
        photoStamp = Date()
    }

    // MARK: Text

    @ViewBuilder private var textBlock: some View {
        if expanded {
            VStack(alignment: .trailing, spacing: 4) {
                PostEditor(text: $text, identity: draft, highlights: highlights, reveal: reveal, focusToken: focusToken,
                           onSelect: onSelect, onComment: onComment)
                Button("show less", action: onCollapse)
                    .buttonStyle(.plain)
                    .font(LinkedIn.font(14)).foregroundStyle(LinkedIn.muted)
                    .help("Back to the feed view, cut after three lines")
            }
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("What do you want to talk about?").font(LinkedIn.font(14)).foregroundStyle(LinkedIn.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)
        } else {
            FeedText(text: text, onMore: onExpand)
        }
    }

    // MARK: Counts and actions

    private var counts: some View {
        HStack(spacing: 4) {
            HStack(spacing: -4) {
                reaction("hand.thumbsup.fill", LinkedIn.blue)
                reaction("heart.fill", Color(red: 0.87, green: 0.33, blue: 0.2))
                reaction("lightbulb.fill", Color(red: 0.96, green: 0.73, blue: 0.2))
            }
            Text(liked ? "You and 127 others" : "128").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
            Spacer()
            Text("24 comments • 6 reposts").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
        }
    }

    private func reaction(_ icon: String, _ color: Color) -> some View { LinkedIn.reaction(icon, color) }
}

extension LinkedIn {
    static func reaction(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
    }
}

extension LinkedInCard {
    private var actions: some View {
        HStack(spacing: 0) {
            action(liked ? "hand.thumbsup.fill" : "hand.thumbsup", "Like", tint: liked ? LinkedIn.blue : nil) {
                liked.toggle()
            }
            action("text.bubble", "Comment", help: "Comment for Takes: on the selected text, or on the whole post",
                   perform: onComment)
            action("arrow.2.squarepath", "Repost") {}
            action("paperplane.fill", "Send") {}
        }
    }

    private func action(_ icon: String, _ label: String, tint: Color? = nil, help: String? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 16))
                Text(label).font(LinkedIn.font(14, .semibold))
            }
            .foregroundStyle(tint ?? LinkedIn.muted)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(LinkedInActionStyle())
        .help(help ?? label)
    }
}

struct LinkedInActionStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(configuration.isPressed ? 0.1 : hover ? 0.05 : 0)))
            .onHover { hover = $0 }
    }
}

/// The text as the feed shows it: three lines, then "…more".
struct FeedText: View {
    let text: String
    var help = "Click to see the whole post and edit it"
    let onMore: () -> Void
    @State private var cut = false

    var body: some View {
        let shown = LinkedIn.styled(text.trimmingCharacters(in: .whitespacesAndNewlines))
        Text(shown)
            .font(LinkedIn.font(14)).foregroundStyle(LinkedIn.ink)
            .lineSpacing(3)
            .lineLimit(PostFile.feedLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The whole text, unseen, to learn whether three lines cut it.
                GeometryReader { box in
                    Text(shown).font(LinkedIn.font(14)).lineSpacing(3)
                        .frame(width: box.size.width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { full in
                            Color.clear.onAppear { cut = full.size.height > box.size.height + 1 }
                                .onChange(of: full.size.height) { _, h in cut = h > box.size.height + 1 }
                        })
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if cut {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.white.opacity(0), .white], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                        Text("…more").font(LinkedIn.font(14)).foregroundStyle(LinkedIn.muted)
                            .background(.white)
                    }
                    .frame(height: 18)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onMore)
            .help(help)
    }
}

// MARK: - Media

/// The video as the feed shows it, at most 4:5 tall. It waits on its first frame until you click it
/// (2026-09-28: The user asked for no autoplay). In a session it is the review player: a timeline to
/// move through it, and comments on a moment or an area, as on the Assets tab (2026-10-02).
/// Outside one it loops muted, and the speaker turns the sound on.
struct PostMedia: View {
    let url: URL
    @State private var ratio: CGFloat = 4.0 / 5.0
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var muted = true
    @State private var paused = true
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        Group {
            if Asset.kind(of: url) == .image {
                ZStack {  // not a Group: an empty Group never appears, so its .task would never run
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(max(ratio, 4.0 / 5.0), contentMode: .fit)
                            .clipped()
                    }
                }
                .task(id: url) {
                    let img = NSImage(contentsOf: url)
                    if let img, img.size.height > 0 { ratio = img.size.width / img.size.height }
                    image = img
                }
            } else if let root = Self.commentRoot(url) {
                ReviewPlayer(url: url, session: root, embedded: true).id(url)
                    .background(Theme.stage)
            } else {
                ZStack {
                    Color.black
                    if let player { PostVideo(player: player) }
                    if paused {
                        Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white)
                            .frame(width: 60, height: 60).background(.black.opacity(0.5), in: Circle())
                    }
                }
                .aspectRatio(max(ratio, 4.0 / 5.0), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .overlay(alignment: .bottomTrailing) {
                    Button { muted.toggle(); player?.isMuted = muted } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(.black.opacity(0.6), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help(muted ? "Sound on" : "Sound off")
                }
                .task(id: url) { await start() }
                .onDisappear { player?.pause(); player = nil; looper = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            // Which file this is: edits often start on the same frame (2026-10-04).
            if hover {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Theme.sans(11, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(Theme.motion) { hover = h } }
        .help(url.lastPathComponent)
    }

    /// Where comments on the video live: the library it sits in, else its session.
    static func commentRoot(_ url: URL) -> URL? {
        if let lib = StyleLib.root(containing: url) { return lib }
        var dir = url.deletingLastPathComponent()
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "session.json").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func start() async {
        let item = AVPlayerItem(url: url)
        let p = AVQueuePlayer()
        p.isMuted = muted
        looper = AVPlayerLooper(player: p, templateItem: item)
        player = p
        paused = true
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let s = size.applying(transform)
            if abs(s.height) > 0 { ratio = abs(s.width) / abs(s.height) }
        }
    }

    private func toggle() {
        guard let player else { return }
        if paused {
            // Play means watch it as posted: with sound. The speaker button still mutes it.
            muted = false
            player.isMuted = false
            player.play()
        } else {
            player.pause()
        }
        paused.toggle()
    }
}

/// The video of a post preview. It fades in once its first frame is ready, so it never pops in
/// over a card that is still blurring in (SwiftUI's blur does not reach an AppKit layer).
struct PostPlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        if !layer.isReadyForDisplay {
            layer.opacity = 0
            context.coordinator.ready = layer.observe(\.isReadyForDisplay) { l, _ in
                guard l.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.3
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    l.opacity = 1
                    l.add(fade, forKey: "fadeIn")
                }
            }
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v.layer as? AVPlayerLayer)?.player = player
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var ready: NSKeyValueObservation? }
}

/// A post's video. Screenshots can't see a player layer, so with `stills` on it shows a frame
/// of the file instead, clipped and overlaid like the video.
struct PostVideo: View {
    let player: AVPlayer
    nonisolated(unsafe) static var stills = false
    @State private var still: CGImage?

    var body: some View {
        if Self.stills {
            Color.clear
                .overlay { if let still { Image(decorative: still, scale: 1).resizable().scaledToFill() } }
                .clipped()
                .task {
                    // A looper hands its first item to the player a moment later.
                    for _ in 0..<30 where player.currentItem == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    guard let asset = player.currentItem?.asset else { return }
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    still = try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
                }
        } else {
            PostPlayerLayer(player: player)
        }
    }
}

// MARK: - Editor

/// The type a post editor writes in: LinkedIn's or X's.
struct EditorLook {
    let font: NSFont
    let lineHeight: CGFloat
    let ink: NSColor
    let tag: NSColor
    /// What gets the tag colour: hashtags, mentions and links; the article's markdown marks.
    var marks: (String) -> [NSRange] = PostFile.tags
    static var linkedin: EditorLook { EditorLook(font: LinkedIn.textFont, lineHeight: LinkedIn.lineHeight, ink: LinkedIn.inkNS, tag: LinkedIn.blueNS) }
    static var x: EditorLook { EditorLook(font: XFeed.textFont, lineHeight: XFeed.lineHeight, ink: XFeed.inkNS, tag: XFeed.blueNS) }
}

/// The post text, editable, in the platform's type. It grows with the text; the pane scrolls.
struct PostEditor: NSViewRepresentable {
    @Binding var text: String
    /// Which draft this is (main or a variant slug). A new one always replaces the text, even while
    /// you type: clicking a variant tab does not end editing (2026-09-28).
    var identity = ""
    var highlights: [String]
    var reveal: (quote: String, token: Int)?
    var focusToken: Int
    var onSelect: (String) -> Void
    var onComment: () -> Void
    var look = EditorLook.linkedin
    var placeholder = ""
    /// false: a new editor does not take the keyboard (the other tweets of a thread).
    var autofocus = true

    var attributes: [NSAttributedString.Key: Any] { Self.attributes(look) }

    static func attributes(_ look: EditorLook) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = look.lineHeight
        p.maximumLineHeight = look.lineHeight
        return [.font: look.font, .foregroundColor: look.ink, .paragraphStyle: p]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GrowingTextView {
        let tv = GrowingTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.insertionPointColor = .black
        tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.74, green: 0.84, blue: 0.98, alpha: 1)]
        tv.typingAttributes = attributes
        tv.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        tv.lineHeight = look.lineHeight
        tv.placeholder = placeholder.isEmpty ? nil : NSAttributedString(string: placeholder, attributes: [
            .font: look.font, .foregroundColor: look.ink.withAlphaComponent(0.4)])
        set(tv, text)
        return tv
    }

    private func set(_ tv: NSTextView, _ s: String) {
        tv.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: attributes))
        tv.invalidateIntrinsicContentSize()
    }

    func updateNSView(_ tv: GrowingTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if identity != c.identity {
            c.identity = identity
            if tv.string != text {
                set(tv, text)
                tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
            }
        } else if tv.string != text && !c.editing { set(tv, text) }
        if look.font.pointSize != c.fontSize {
            c.fontSize = look.font.pointSize
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            tv.textStorage?.setAttributes(attributes, range: all)
            tv.typingAttributes = attributes
            tv.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
            tv.lineHeight = look.lineHeight
            if let p = tv.placeholder {
                tv.placeholder = NSAttributedString(string: p.string, attributes: [
                    .font: look.font, .foregroundColor: look.ink.withAlphaComponent(0.4)])
            }
            tv.invalidateIntrinsicContentSize()
        }
        c.decorate(tv, highlights)
        if let reveal, reveal.token != c.lastReveal {
            c.lastReveal = reveal.token
            let r = (tv.string as NSString).range(of: reveal.quote)
            if r.location != NSNotFound {
                DispatchQueue.main.async {
                    tv.setSelectedRange(r)
                    tv.scrollRangeToVisible(r)
                    tv.showFindIndicator(for: r)
                }
            }
        }
        if focusToken != c.lastFocus {
            c.lastFocus = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: GrowingTextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
        return CGSize(width: w, height: tv.height(for: w))
    }

    final class GrowingTextView: NSTextView {
        var lineHeight = LinkedIn.lineHeight
        /// Grey text while it is empty.
        var placeholder: NSAttributedString?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty, let placeholder {
                // Wrapped at the view's width, so a long hint stays inside the box.
                placeholder.draw(with: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
                                 options: [.usesLineFragmentOrigin])
            }
        }

        func height(for width: CGFloat) -> CGFloat {
            guard let lm = layoutManager, let tc = textContainer else { return lineHeight }
            tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            let h = max(lineHeight, ceil(lm.usedRect(for: tc).height))
            // SwiftUI measures at trial widths too. Wrap at the real width again, or the text
            // stays in a narrow column (2026-09-28).
            if bounds.width > 0 && bounds.width != width {
                tc.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
            }
            return h
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: height(for: max(bounds.width, 100)))
        }
        override func didChangeText() {
            super.didChangeText()
            invalidateIntrinsicContentSize()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PostEditor
        var editing = false
        var identity: String
        var lastReveal = 0
        var lastFocus: Int
        /// The type size the text has: a new text size (⌘+ / ⌘−) restyles it in place.
        var fontSize: CGFloat
        private var lit: (String, [String])?

        init(_ p: PostEditor) { parent = p; identity = p.identity; fontSize = p.look.font.pointSize; lastFocus = p.autofocus ? p.focusToken - 1 : p.focusToken }

        func textDidBeginEditing(_ notification: Notification) { editing = true }
        func textDidEndEditing(_ notification: Notification) { editing = false }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            decorate(tv, parent.highlights)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            let s = r.length > 0 ? (tv.string as NSString).substring(with: r) : ""
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.parent.onSelect(trimmed) }
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let item = NSMenuItem(title: view.selectedRange().length > 0 ? "Comment for Takes…" : "Comment on the Post for Takes…",
                                  action: #selector(comment), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func comment() { parent.onComment() }

        /// Blue tags and marked comment quotes. Temporary attributes: never saved, never typed over.
        func decorate(_ tv: NSTextView, _ quotes: [String]) {
            guard lit == nil || lit!.0 != tv.string || lit!.1 != quotes, let lm = tv.layoutManager else { return }
            lit = (tv.string, quotes)
            let s = tv.string as NSString
            let all = NSRange(location: 0, length: s.length)
            for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .foregroundColor] {
                lm.removeTemporaryAttribute(key, forCharacterRange: all)
            }
            for r in parent.look.marks(tv.string) {
                lm.addTemporaryAttribute(.foregroundColor, value: parent.look.tag, forCharacterRange: r)
            }
            for q in quotes where !q.isEmpty {
                let r = s.range(of: q)
                guard r.location != NSNotFound else { continue }
                lm.addTemporaryAttributes([.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.18),
                                           .underlineStyle: NSUnderlineStyle.single.rawValue,
                                           .underlineColor: NSColor(Theme.accent)], forCharacterRange: r)
            }
        }
    }
}

/// Big faint logos of the platform behind an empty post. They drift in from nothing, one after another,
/// then rest. Vertical shows TikTok, Reels and Shorts. No endless drift: a repeatForever animation
/// redraws the whole window every frame (Motion.swift).
struct GiantLogos: View {
    let platform: PostPlatform
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still

    private struct Slot { let x, y, size, turn: CGFloat }
    // Where each giant rests, as parts of the pane. The last two are cut by the edges.
    private let slots = [Slot(x: 0.16, y: 0.42, size: 0.34, turn: -14), Slot(x: 0.5, y: 0.17, size: 0.27, turn: 5),
                         Slot(x: 0.85, y: 0.5, size: 0.32, turn: 11), Slot(x: 0.06, y: 0.97, size: 0.24, turn: 18),
                         Slot(x: 0.97, y: 0.99, size: 0.2, turn: -10)]

    private var logos: [String] {
        switch platform {
        case .vertical: ["tiktok", "instagram", "youtube"]
        default: [platform.name]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height * 1.3)
            ZStack {
                ForEach(slots.indices, id: \.self) { i in
                    let s = slots[i]
                    let up: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                    PlatformLogo(platform: logos[i % logos.count], size: side * s.size)
                        .saturation(0.85)
                        .opacity(shown ? (i < 3 ? 0.085 : 0.055) : 0)
                        .blur(radius: shown ? 0 : 18)
                        .scaleEffect(shown ? 1 : 0.82)
                        .rotationEffect(.degrees(shown ? s.turn : s.turn - 8 * up))
                        .offset(y: shown ? 0 : 40)
                        .animation(still ? nil : .spring(duration: 1.6, bounce: 0.12).delay(0.08 + Double(i) * 0.14), value: shown)
                        .position(x: geo.size.width * s.x, y: geo.size.height * s.y)
                }
                // A soft clearing in the middle, so the words stay clean.
                RadialGradient(colors: [Theme.canvas, Theme.canvas.opacity(0)], center: .center,
                               startRadius: 0, endRadius: side * 0.42)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { shown = true }
    }
}

/// LinkedIn | X | YouTube | Vertical, then the sides a plugin adds. A dot marks the sides that have a post.
struct PostSideSwitch: View {
    /// The Plugins board can turn a plugin off: draw again without it.
    @AppStorage(Plugins.removedKey) private var pluginsRemoved = ""
    var doc: SessionDoc
    /// The side on show: a platform's raw value or a plugin side's id.
    let current: String
    let pick: (String) -> Void
    /// Where the pill stands. It starts on the side before and springs to this one (2026-10-04):
    /// each side is a new pane, so without it the pill jumped.
    @State private var pill: String
    @Namespace private var switchNS

    init(doc: SessionDoc, current: String, from: String?, pick: @escaping (String) -> Void) {
        self.doc = doc
        self.current = current
        self.pick = pick
        _pill = State(initialValue: from ?? current)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PostPlatform.shown) { p in
                let has = FileManager.default.fileExists(atPath: PostFile.url(doc.url, p).path)
                item(p.rawValue, p.name, has: has, mark: AnyView(PlatformLogo(platform: p.name, size: 11)),
                     help: p == .vertical ? "One vertical video and caption for TikTok, Instagram Reels and YouTube Shorts"
                         : p.rawValue == pill ? "The \(p.name) post" : has ? "Show the \(p.name) post" : "No \(p.name) post yet: show that side")
            }
            ForEach(Plugins.postSides) { s in
                item(s.id, s.name, has: s.has(doc.url), mark: s.mark(), help: s.help)
            }
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .onAppear {
            guard pill != current else { return }
            DispatchQueue.main.async { withAnimation(Theme.spring) { pill = current } }
        }
    }

    private func item(_ id: String, _ name: String, has: Bool, mark: AnyView, help: String) -> some View {
        let on = id == pill
        return Button { if id != current { pick(id) } } label: {
            HStack(spacing: 6) {
                mark
                    .opacity(on || has ? 1 : 0.45)
                    .overlay(alignment: .topTrailing) {
                        if has && !on { Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(x: 3, y: -2) }
                    }
                if on { Text(name).font(Theme.sans(12.5, .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(on ? Theme.ink : Theme.faint)
            .padding(.horizontal, on ? 10 : 8).frame(height: 24)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.paper)
                        .shadow(color: Theme.shadow, radius: 2, y: 1)
                        .matchedGeometryEffect(id: "platform", in: switchNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
