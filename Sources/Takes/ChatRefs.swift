import AppKit
import SwiftUI

// Previews in the chat (2026-09-30). A line of Claude's reply that is only a file path or only a
// LinkedIn or X post link shows as a card: a video or image with its frame, a post with its text
// and numbers. Click a file to open it in Takes; click a post to open it on the platform.
// The system prompt (Chat.swift) tells Claude to write references this way.

enum ChatPiece: Equatable {
    case text(String)
    case file(URL)
    case post(URL)
}

enum ChatRefs {
    /// What Claude is told, in both chats.
    static let howTo = """
    To show the user a file (an edit, a take, a still, a thumbnail, a post file), put its absolute \
    path alone on its own line. To show a published LinkedIn or X post, put its URL alone on its \
    own line. The panel turns each such line into a preview card he can click, so whenever you \
    name a specific video, image or post, add its line right after.
    """

    /// `split` for the views, remembered per text: the same reply redraws often.
    @MainActor static func pieces(_ text: String) -> [ChatPiece] {
        if let hit = splitCache[text] { return hit }
        if splitCache.count > 500 { splitCache.removeAll(keepingCapacity: true) }
        let p = split(text)
        splitCache[text] = p
        return p
    }
    @MainActor private static var splitCache: [String: [ChatPiece]] = [:]

    /// Splits a reply into text and reference lines. `isFile` is injectable for tests.
    static func split(_ text: String, isFile: (String) -> Bool = ChatRefs.isFile) -> [ChatPiece] {
        var pieces: [ChatPiece] = []
        var buffer: [String] = []
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.text(t)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if let ref = reference(line, isFile: isFile) {
                flush()
                pieces.append(ref)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return pieces
    }

    /// A line that is only a path or a post link, in backticks, angle brackets or a markdown link.
    static func reference(_ line: String, isFile: (String) -> Bool) -> ChatPiece? {
        var s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "• "] where s.hasPrefix(bullet) { s = String(s.dropFirst(bullet.count)) }
        if s.hasPrefix("["), s.hasSuffix(")"), let mid = s.range(of: "](") {
            s = String(s[mid.upperBound..<s.index(before: s.endIndex)])
        }
        for (open, close) in [("`", "`"), ("<", ">")] where s.hasPrefix(open) && s.hasSuffix(close) && s.count > 2 {
            s = String(s.dropFirst().dropLast())
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") || s.hasPrefix("/") || s.hasPrefix("~/") else { return nil }
        if s.hasPrefix("~/") { s = FileManager.default.homeDirectoryForCurrentUser.path + String(s.dropFirst()) }
        if s.hasPrefix("/") {
            return isFile(s) ? .file(URL(fileURLWithPath: s)) : nil
        }
        if let url = URL(string: s), ["http", "https"].contains(url.scheme ?? ""), platform(url) != nil {
            return .post(url)
        }
        return nil
    }

    /// Blocks split at blank lines; a list item also starts a block of its own kind.
    static func paragraphs(_ text: String) -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { out.append(cur); cur = [] }
            } else if let last = cur.last, (bullet(last) == nil) != (bullet(line) == nil) {
                out.append(cur); cur = [line]
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The text of a "- " or "* " list item, else nil.
    static func bullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for p in ["- ", "* ", "• "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }

    static func isFile(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }

    /// "LinkedIn" or "X" for a post link, else nil.
    static func platform(_ url: URL) -> String? {
        let host = (url.host ?? "").lowercased()
        if host.hasSuffix("linkedin.com") { return "LinkedIn" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") { return "X" }
        return nil
    }

    /// The same post with or without a query, a trailing slash or www.
    static func key(_ s: String) -> String {
        var k = s.lowercased()
        if let q = k.firstIndex(of: "?") { k = String(k[..<q]) }
        while k.hasSuffix("/") { k.removeLast() }
        for p in ["https://", "http://", "www."] where k.hasPrefix(p) { k = String(k.dropFirst(p.count)) }
        return k.replacingOccurrences(of: "twitter.com", with: "x.com")
    }

    /// A post's text without its blank lines, for a short preview.
    static func compact(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    static func open(_ file: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "takes"; c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return c.url
    }
}

/// Claude's reply: text with inline markdown, and a card for each reference line.
/// No AppModel here: every change to it redrew and reparsed every reply of the chat. The
/// panel around the replies opens their links (ChatReply.links).
struct ChatReply: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(ChatRefs.pieces(text).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let t):
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(ChatRefs.paragraphs(t).enumerated()), id: \.offset) { i, para in
                            // A bold line alone reads as a heading: more room above it.
                            paragraph(para)
                                .padding(.top, i > 0 && para.count == 1 && para[0].hasPrefix("**") && para[0].hasSuffix("**") ? 10 : 0)
                        }
                    }
                case .file(let url): FileRefCard(url: url).padding(.vertical, 4)
                case .post(let url): PostRefCard(url: url).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @MainActor private static var linksCache: (ObjectIdentifier, OpenURLAction)?
    /// A markdown link to a file opens it in Takes, not in Finder. One action per app, made once:
    /// a new one on every redraw changed the environment of the whole transcript (2026-10-03).
    @MainActor static func links(_ app: AppModel) -> OpenURLAction {
        if let (id, action) = linksCache, id == ObjectIdentifier(app) { return action }
        let action = OpenURLAction { [weak app] url in
            guard let app else { return .systemAction }
            if url.isFileURL, let t = ChatRefs.open(url) { app.handle(url: t); return .handled }
            if url.scheme == "takes" { app.handle(url: url); return .handled }
            return .systemAction
        }
        linksCache = (ObjectIdentifier(app), action)
        return action
    }

    /// A paragraph, or a list with a hanging bullet per item.
    @ViewBuilder private func paragraph(_ lines: [String]) -> some View {
        if lines.allSatisfy({ ChatRefs.bullet($0) != nil }) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.faint)
                        prose(ChatRefs.bullet(line) ?? line)
                    }
                }
            }
        } else {
            prose(lines.joined(separator: "\n"))
        }
    }

    private func prose(_ s: String) -> some View {
        Text(Self.markdown(s)).font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A streaming reply redraws 10 times a second; its earlier paragraphs do not change, so
    /// their parsed text comes from here.
    @MainActor private static var parsed: [String: AttributedString] = [:]

    @MainActor static func markdown(_ s: String) -> AttributedString {
        if let hit = parsed[s] { return hit }
        if parsed.count > 3000 { parsed.removeAll(keepingCapacity: true) }
        let a = parse(s)
        parsed[s] = a
        return a
    }

    private static func parse(_ s: String) -> AttributedString {
        // An absolute path as a link target becomes a file link.
        let fixed = s.replacingOccurrences(of: "](/", with: "](file:///")
        return (try? AttributedString(markdown: fixed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A card that lifts a little on hover.
private struct RefCard<Content: View>: View {
    let help: String
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Theme.muted.opacity(0.35) : Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(hover ? 0.08 : 0), radius: 8, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help(help)
    }
}

/// The look of a RefCard around content that is not one button: a frame or a player inside.
private struct CardShell: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Theme.muted.opacity(0.35) : Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(hover ? 0.08 : 0), radius: 8, y: 3)
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
    }
}

/// A file from a session: its frame (video, image) or its text (a post file).
///
/// The card has its final size from the start: a picture that loads later fills the space kept
/// for it. The disk is read once per file, not on every redraw while a reply streams in.
struct FileRefCard: View {
    @Environment(AppModel.self) var app
    let url: URL
    private let asset: Asset
    private let session: String?
    @State private var image: NSImage?
    @State private var duration: Double?
    @State private var postText: String?
    /// The video plays in the card, with sound and controls (2026-10-03).
    @State private var playing = false

    init(url: URL) {
        self.url = url
        let found = Self.look(url)
        asset = found.asset
        session = found.session
        _image = State(initialValue: Thumbs.shared.cached(found.asset))
    }

    /// Recent lookups. A streaming reply redraws the card many times a second; a few seconds
    /// later the file is read again, so a file changed in place shows its new frame.
    @MainActor private static var known: [URL: (asset: Asset, session: String?, at: Date)] = [:]

    @MainActor private static func look(_ url: URL) -> (asset: Asset, session: String?) {
        if let k = known[url], Date().timeIntervalSince(k.at) < 3 { return (k.asset, k.session) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let asset = Asset(url: url, group: "", name: url.lastPathComponent,
                          size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                          modified: attrs?[.modificationDate] as? Date ?? .distantPast)
        // The session folder above the file, for its title.
        var session: String?
        var dir = url.deletingLastPathComponent()
        while dir.pathComponents.count > 2 {
            if let meta = Store.readMeta(dir) { session = meta.title; break }
            dir = dir.deletingLastPathComponent()
        }
        known[url] = (asset, session, Date())
        return (asset, session)
    }

    private var postPlatform: PostPlatform? {
        PostPlatform.allCases.first { url.path.hasSuffix("/" + $0.rel) }
    }

    var body: some View {
        Group {
            if visual { mediaCard } else { refCard }
        }
        .overlay(alignment: .topTrailing) {
            if asset.kind == .image, Cover.can(url) { CoverButton(image: url).padding(8) }
        }
        // A vertical or square frame makes a narrow card; a wide one takes the chat's width.
        .frame(maxWidth: visual && ratio < 1.2 ? (ratio < 0.9 ? 210 : 280) : .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url) {
            if let p = postPlatform {
                postText = PostFile.read(url.deletingLastPathComponent().deletingLastPathComponent(), p)
                    .map { ChatRefs.compact($0.text) }
                return
            }
            let a = asset
            image = Thumbs.shared.cached(a)
            if image == nil { image = await Thumbs.shared.image(a) }
            if a.kind == .video || a.kind == .audio { duration = await Thumbs.shared.duration(a) }
        }
    }

    private var visual: Bool { asset.kind == .video || asset.kind == .image }

    /// In Takes when the file is in a session; else (a file dropped into the chat) in its own app.
    private func open() {
        if AppModel.session(containing: url) == nil { NSWorkspace.shared.open(url); return }
        if let t = ChatRefs.open(url) { app.handle(url: t) }
    }

    /// A frame or a video: the video plays right here in the glass player; the name below opens
    /// the file in Takes. Not one big button, so a click on the video never bounces the card.
    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The frame in its own format: no dark bars beside a vertical video (2026-10-03).
            Theme.stage
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    if playing {
                        GlassPlayer(url: url, onOpen: open)
                    } else {
                        ZStack {
                            if let image { Image(nsImage: image).resizable().scaledToFill() }
                            if asset.kind == .video {
                                Button { playing = true } label: { GlassPlayButton(size: 52) }
                                    .buttonStyle(PressScale())
                                    .help("Play here, with sound")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if asset.kind == .video { playing = true } else { open() } }
                    }
                }
                .clipped()
            Button(action: open) {
                caption.padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(url.lastPathComponent) in Takes")
        }
        .modifier(CardShell())
    }

    private var refCard: some View {
        RefCard(help: "Open \(url.lastPathComponent) in Takes") {
            if let postPlatform {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        PlatformLogo(platform: postPlatform.name, size: 14)
                        Text("\(postPlatform.name) post").font(Theme.sans(12, .semibold))
                        if let session { Text("· \(session)").font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1) }
                    }
                    if let postText {
                        Text(postText).font(Theme.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(4)
                    }
                }
                .padding(12)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(width: 34, height: 34)
                        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
                    caption
                }
                .padding(10)
            }
        } action: { open() }
    }


    /// Width over height: the frame's, else a guess from the name ("(V)" is a vertical clip).
    private var ratio: CGFloat {
        if let image, image.size.height > 0 { return min(max(image.size.width / image.size.height, 0.5), 2.2) }
        let name = url.lastPathComponent
        if name.contains("(V)") || name.contains("vertical") { return 9.0 / 16.0 }
        return 16.0 / 9.0
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text((url.lastPathComponent as NSString).deletingPathExtension)
                    .font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let session { Text(session).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Text(duration.map(SessionDoc.clock) ?? url.pathExtension.uppercased())
                .font(Theme.mono(11.5)).foregroundStyle(Theme.faint).fixedSize()
        }
    }

    private var icon: String {
        switch asset.kind {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }
}

/// A published post: its text and numbers when Takes or the dashboard knows it.
struct PostRefCard: View {
    @Environment(AppModel.self) var app
    let url: URL
    @State private var found: Found?

    struct Found: Equatable {
        var title: String
        var detail: String?
        var session: URL?
        var reach: Int?
        var engagements: Int?
        var rate: Double?
    }

    private var platform: String { ChatRefs.platform(url) ?? "Post" }

    var body: some View {
        RefCard(help: "Open the post on \(platform)") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    PlatformLogo(platform: platform, size: 14)
                    Text(found?.title ?? "\(platform) post").font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(Theme.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                if let d = found?.detail {
                    Text(d).font(Theme.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(3)
                }
                if let f = found, f.reach != nil || f.engagements != nil {
                    HStack(spacing: 14) {
                        if let r = f.reach { stat(r.formatted(), platform == "X" ? "views" : "impressions") }
                        if let e = f.engagements { stat(e.formatted(), "engagements") }
                        if let r = f.rate { stat(String(format: "%.1f%%", r), "rate") }
                    }
                } else if found == nil {
                    Text(url.absoluteString).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let s = found?.session {
                    Button("Open in Takes") {
                        let p = PostPlatform.allCases.first { $0.name == platform } ?? .linkedin
                        if let t = ChatRefs.open(s.appending(path: p.rel)) { app.handle(url: t) }
                    }
                    .buttonStyle(.plain).font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
                }
            }
            .padding(12)
        } action: {
            NSWorkspace.shared.open(url)
        }
        .task(id: url) { found = lookup() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
            Text(label).font(Theme.sans(11)).foregroundStyle(Theme.faint)
        }
    }

    /// A session's post first (its text and latest numbers), then the dashboard's lists.
    private func lookup() -> Found? {
        let k = ChatRefs.key(url.absoluteString)
        let root = app.library.root
        if app.performance.items.isEmpty { app.performance.scan(root) }
        if let item = app.performance.items.first(where: { $0.post.url.map(ChatRefs.key) == k }) {
            let p = PostPlatform.allCases.first { $0.name == item.post.platform } ?? .linkedin
            let text = PostFile.read(item.session, p).map { ChatRefs.compact($0.text) }
            let s = item.post.latest
            let eng = s?.engagement
            let rate = s.flatMap { st in st.reach.flatMap { $0 > 0 ? Double(eng ?? 0) / Double($0) * 100 : nil } }
            return Found(title: item.title, detail: text, session: item.session,
                         reach: s?.reach, engagements: eng, rate: rate)
        }
        if let social = app.performance.social ?? SocialData.read(root) {
            let all = social.recent + social.top_linkedin + social.top_x + social.patterns.values.flatMap(\.top)
            if let e = all.first(where: { ChatRefs.key($0.url) == k }) {
                let day = (try? Date(e.date, strategy: .iso8601.year().month().day()))?
                    .formatted(.dateTime.month(.abbreviated).day().year()) ?? e.date
                return Found(title: e.title, detail: day, reach: e.reach, engagements: e.engagements, rate: e.rate)
            }
        }
        return nil
    }
}
