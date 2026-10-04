import AppKit
import SwiftUI

// A session is "published" once its video is live on social media. The user marks it in the header
// (or Claude does, with the MCP tool set_published). Then "Clean up" trashes what is no longer
// needed: by default everything except the newest edit, after a confirmation sheet where he can
// pick what else to keep.
//
// session.json: "published": [{"platform": "LinkedIn", "url": "https://…", "at": "2026-09-28T15:00:00Z"}]
// platform and url are optional. The MCP server writes the same shape.

struct Post: Codable, Hashable {
    var platform: String?
    var url: String?
    var at: Date
    /// Numbers over time, oldest first. Claude adds one with set_post_stats.
    var stats: [PostStat]?

    var label: String { platform ?? "Published" }
    var latest: PostStat? { stats?.last }
}

/// The numbers of one post at one moment. A platform leaves out what it does not show.
struct PostStat: Codable, Hashable {
    var at: Date
    var impressions: Int?
    var views: Int?
    var likes: Int?
    var comments: Int?
    var reposts: Int?

    /// Impressions, or views where the platform counts those.
    var reach: Int? { impressions ?? views }
    var engagement: Int { (likes ?? 0) + (comments ?? 0) + (reposts ?? 0) }
}

enum Platforms {
    static let all = ["LinkedIn", "X", "YouTube", "Instagram", "TikTok"]
}

extension SessionDoc {
    var posts: [Post] { meta.published ?? [] }
    var isPublished: Bool { !posts.isEmpty }

    /// Adds a post, or updates the one on the same platform.
    func markPublished(_ platform: String?, url: String? = nil, at: Date = Date()) {
        meta.published = Self.adding(Post(platform: platform, url: url, at: at), to: posts)
        save()
    }

    /// Switches one platform on or off. nil is "somewhere else".
    func setPublished(_ platform: String?, _ on: Bool) {
        if on { markPublished(platform); return }
        let rest = posts.filter { $0.platform?.lowercased() != platform?.lowercased() }
        meta.published = rest.isEmpty ? nil : rest
        save()
    }

    /// The link to the live post. Empty removes it.
    func setURL(_ platform: String?, _ url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = posts.firstIndex(where: { $0.platform?.lowercased() == platform?.lowercased() }),
              (posts[i].url ?? "") != clean else { return }
        meta.published?[i].url = clean.isEmpty ? nil : clean
        save()
    }

    func unpublish() {
        meta.published = nil
        save()
    }

    /// Marking the same platform again keeps its first date, its link and its numbers.
    nonisolated static func adding(_ post: Post, to list: [Post]) -> [Post] {
        var post = post
        if let old = list.first(where: { $0.platform?.lowercased() == post.platform?.lowercased() }) {
            post.at = old.at
            post.url = post.url ?? old.url
            post.stats = post.stats ?? old.stats
        }
        var next = list.filter { $0.platform?.lowercased() != post.platform?.lowercased() }
        if post.platform != nil { next.removeAll { $0.platform == nil } }  // "somewhere" becomes the real place
        next.append(post)
        return next
    }

    /// Moves take files to the Trash and drops them from session.json. Unlike trashTake, this can
    /// trash only the screen file of a take and keep its camera file.
    func trashTakeFiles(_ files: Set<String>) {
        for t in meta.takes where files.contains(t.file) {
            try? FileManager.default.trashItem(at: fileURL(t), resultingItemURL: nil)
        }
        meta.takes.removeAll { files.contains($0.file) }
        save()
    }
}

extension Library {
    /// Marks each session published on `platform`. nil only marks the ones not yet published.
    func markPublished(_ urls: Set<URL>, on platform: String? = nil) {
        for u in urls {
            let doc = current?.url == u ? current! : SessionDoc(url: u)
            if platform != nil || !doc.isPublished { doc.markPublished(platform) }
        }
        loadSessions()
    }
}

// MARK: - Cleanup

enum Cleanup {
    /// What stays by default: the newest edit. No edits: the starred takes, else the newest take.
    static func defaultKeep(_ assets: [Asset], takes: [Take]) -> Set<URL> {
        if let edit = assets.filter({ $0.group == "edits" && $0.kind == .video }).max(by: { $0.modified < $1.modified }) {
            return [edit.url]
        }
        let files = Set(assets.filter(\.take).map(\.name))
        let present = takes.filter { files.contains($0.file) }
        let starred = present.filter(\.keeper)
        let newest = present.map(\.number).max()
        let pick = starred.isEmpty ? present.filter { $0.number == newest } : starred
        let keep = Set(pick.map(\.file))
        return Set(assets.filter { $0.take && keep.contains($0.name) }.map(\.url))
    }

    /// Transcripts and subtitles that sit next to a video and go with it.
    static func sidecars(of url: URL) -> [URL] {
        let stem = url.deletingPathExtension()
        return [".words.json", ".srt", ".vtt"].map { URL(fileURLWithPath: stem.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves `items` to the Trash. Takes go through the session so session.json drops them.
    /// Folders left empty go too. Returns the bytes freed.
    @MainActor @discardableResult
    static func run(_ items: [Asset], in doc: SessionDoc) -> Int64 {
        doc.trashTakeFiles(Set(items.filter(\.take).map(\.name)))
        for a in items where !a.take {
            for u in [a.url] + sidecars(of: a.url) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        }
        for g in Set(items.map(\.group)) where !g.isEmpty && g != "takes" {
            removeIfEmpty(doc.url.appending(path: g))
        }
        return items.reduce(0) { $0 + $1.size }
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in walk where f.lastPathComponent != ".DS_Store" && !f.hasDirectoryPath { return }
        try? fm.removeItem(at: dir)
    }
}

// MARK: - Views

/// The header control: "Mark published", or once published, the logos of where it is live.
/// A click opens a list of platforms: switch on each one it went out on.
struct PublishMenu: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            if doc.isPublished {
                HStack(spacing: 6) {
                    PlatformLogos(posts: doc.posts, size: 15)
                    Text("Published").foregroundStyle(Theme.accentInk)
                }
            } else {
                Label("Mark published", systemImage: "paperplane")
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .font(Theme.sans(12, .medium))
        .disabled(app.isRecording)
        .help(doc.isPublished ? "Posted on \(doc.posts.map(\.label).joined(separator: ", ")). Click to change or clean up."
                              : "Mark where this video is posted, then clean up the session")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "published on").padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ForEach(Platforms.all, id: \.self) { p in row(p) }
            if doc.posts.contains(where: { $0.platform == nil }) { row(nil) }
            Rule().padding(.vertical, 6)
            HStack {
                Button("Clean up…") { open = false; app.cleaningUp = true }
                    .buttonStyle(BracketButtonStyle(active: doc.isPublished))
                    .help("Pick what to keep and move the rest to the Trash")
                Spacer()
                if doc.isPublished {
                    Button("None") { doc.unpublish(); app.library.loadSessions() }
                        .buttonStyle(BracketButtonStyle(active: false))
                        .help("Mark as not published")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 250)
        .background(Theme.paper)
        .tint(Theme.accent)
    }

    private func row(_ platform: String?) -> some View {
        let post = doc.posts.first { $0.platform?.lowercased() == platform?.lowercased() }
        let on = post != nil
        return VStack(alignment: .leading, spacing: 4) {
            check(platform, post)
            if let post {
                PostURLField(doc: doc, platform: platform, saved: post.url ?? "")
                    .padding(.leading, 42).padding(.trailing, 12).padding(.bottom, 4)
            }
        }
        .animation(Theme.motion, value: on)
    }

    private func check(_ platform: String?, _ post: Post?) -> some View {
        let on = post != nil
        return HStack(spacing: 10) {
            PlatformLogo(platform: platform, size: 20).opacity(on ? 1 : 0.35)
            Text(platform ?? "Somewhere else").font(Theme.sans(13, on ? .semibold : .regular)).foregroundStyle(Theme.ink)
            Spacer()
            if let s = post?.url, let url = URL(string: s) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                    .help("Open the post on \(platform ?? "the web")")
            }
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(on ? Theme.accent : Theme.border)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { doc.setPublished(platform, !on); app.library.loadSessions() }
    }
}

/// The link to the live post. It saves as you type, so nothing is lost when the popover closes.
private struct PostURLField: View {
    var doc: SessionDoc
    let platform: String?
    let saved: String
    @State private var text = ""

    var body: some View {
        TextField("Paste the post link", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            .onAppear { text = saved }
            .onChange(of: saved) { _, s in if s != text { text = s } }
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { doc.setURL(platform, text) }
            }
            .onDisappear { doc.setURL(platform, text) }
            .onSubmit { doc.setURL(platform, text) }
            .help("The link to the post. Open it from here or from the session's right-click menu.")
    }
}

/// The platform logos: the real marks from BrandMark, else simple marks drawn in SwiftUI.
struct PlatformLogo: View {
    let platform: String?
    var size: CGFloat = 16

    var body: some View {
        let r = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            if let real = BrandMark.image(platform?.lowercased() ?? "") {
                Image(nsImage: real).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
            switch platform?.lowercased() {
            case "article":
                r.fill(ArticleLook.orange)
                Image(systemName: "text.alignleft").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            case "linkedin":
                r.fill(Color(red: 0.04, green: 0.4, blue: 0.76))
                Text("in").font(.system(size: size * 0.62, weight: .heavy)).foregroundStyle(.white).offset(y: -size * 0.02)
            case "x":
                r.fill(Color.black)
                Text("𝕏").font(.system(size: size * 0.62, weight: .bold)).foregroundStyle(.white)
            case "youtube":
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color(red: 1, green: 0, blue: 0))
                    .frame(height: size * 0.72)
                Image(systemName: "play.fill").font(.system(size: size * 0.34)).foregroundStyle(.white)
            case "instagram":
                r.fill(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.3), Color(red: 0.98, green: 0.3, blue: 0.3),
                                               Color(red: 0.8, green: 0.2, blue: 0.6), Color(red: 0.45, green: 0.25, blue: 0.85)],
                                      startPoint: .bottomLeading, endPoint: .topTrailing))
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .strokeBorder(.white, lineWidth: max(1, size * 0.08)).frame(width: size * 0.64, height: size * 0.64)
                Circle().strokeBorder(.white, lineWidth: max(1, size * 0.08)).frame(width: size * 0.3, height: size * 0.3)
                Circle().fill(.white).frame(width: size * 0.08, height: size * 0.08).offset(x: size * 0.16, y: -size * 0.16)
            case "tiktok":
                r.fill(Color.black)
                ZStack {
                    Image(systemName: "music.note").foregroundStyle(Color(red: 0.15, green: 0.95, blue: 0.95)).offset(x: -size * 0.04, y: -size * 0.03)
                    Image(systemName: "music.note").foregroundStyle(Color(red: 1, green: 0.17, blue: 0.33)).offset(x: size * 0.04, y: size * 0.03)
                    Image(systemName: "music.note").foregroundStyle(.white)
                }
                .font(.system(size: size * 0.52, weight: .bold))
            case "vertical":
                // A wireframe of a tall screen, in the text colour beside it.
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .strokeBorder(lineWidth: max(1.2, size * 0.11))
                    .frame(width: size * 0.6, height: size * 0.96)
            default:
                r.fill(Theme.accent)
                Image(systemName: "paperplane.fill").font(.system(size: size * 0.48)).foregroundStyle(.white)
            }
            }
        }
        .frame(width: size, height: size)
        .help(platform ?? "Published")
    }
}

/// The logos of every place a session is published, side by side.
struct PlatformLogos: View {
    let posts: [Post]
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 3) {
            ForEach(posts, id: \.self) { PlatformLogo(platform: $0.platform, size: size) }
        }
    }
}

/// Confirmation before the cleanup: every file, what stays checked. Click a file to keep it or not.
struct CleanupSheet: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AssetStore()
    @State private var keep: Set<URL> = []
    @State private var ready = false

    var body: some View {
        let trash = store.assets.filter { !keep.contains($0.url) }
        let kept = store.assets.filter { keep.contains($0.url) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Clean up").font(Theme.display(25))
                    Text(doc.meta.title).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    if doc.isPublished {
                        Tag(text: "Published · " + doc.posts.map(\.label).joined(separator: ", "), accent: true)
                    }
                }
                Text("Checked files stay. Everything else goes to the Trash. Click a file to change it. The script, comments and history stay.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            }
            .padding(16)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.assets.isEmpty && ready {
                        Text("This session has no files to clean up.").font(Theme.sans(14)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(store.groups.enumerated()), id: \.element.name) { i, g in
                        section(i + 1, g.name, g.assets)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surface)
            Rule()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep \(kept.count) · \(size(kept))").font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink)
                    Text("Trash \(trash.count) · \(size(trash))").font(Theme.mono(11)).foregroundStyle(Theme.accentInk)
                }
                .fixedSize()
                Button("Only the newest edit") { keep = Cleanup.defaultKeep(store.assets, takes: doc.meta.takes) }
                    .buttonStyle(BracketButtonStyle(active: false))
                    .help("Back to the default: keep the newest video in edits/")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                Button(trash.isEmpty ? "Nothing to trash" : "Move \(trash.count) to Trash") { run(trash) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle(kind: .solid))
                    .disabled(trash.isEmpty || app.isRecording)
            }
            .padding(14)
        }
        .frame(width: 880, height: 620)
        .background(Theme.paper)
        .presentationBackground(Theme.paper)
        .tint(Theme.accent)
        .font(Theme.body)
        .onAppear {
            store.scan(doc)
            keep = Cleanup.defaultKeep(store.assets, takes: doc.meta.takes)
            ready = true
        }
    }

    private func section(_ n: Int, _ name: String, _ items: [Asset]) -> some View {
        let all = items.allSatisfy { keep.contains($0.url) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(number: String(format: "%02d", n), text: name.isEmpty ? "session folder" : name)
                Text("\(items.filter { keep.contains($0.url) }.count) of \(items.count) kept")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                Spacer()
                Button(all ? "keep none" : "keep all") {
                    let urls = Set(items.map(\.url))
                    if all { keep.subtract(urls) } else { keep.formUnion(urls) }
                }
                .buttonStyle(BracketButtonStyle(active: false))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(items) { a in
                    let on = keep.contains(a.url)
                    AssetTile(asset: a, selected: false, picked: on)
                        .opacity(on ? 1 : 0.45)
                        .overlay(alignment: .topLeading) {
                            if !on {
                                Image(systemName: "trash.circle.fill").font(.system(size: 16))
                                    .foregroundStyle(.white, Theme.muted)
                                    .padding(5)
                            }
                        }
                        .onTapGesture { if on { keep.remove(a.url) } else { keep.insert(a.url) } }
                }
            }
        }
    }

    private func size(_ items: [Asset]) -> String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file)
    }

    private func run(_ items: [Asset]) {
        if let p = app.preview, items.contains(where: { $0.url == p }) { app.preview = nil }
        let freed = Cleanup.run(items, in: doc)
        app.library.loadSessions()
        app.show(toast: "Moved \(items.count) file\(items.count == 1 ? "" : "s") to the Trash · \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed")
        dismiss()
    }
}
