import SwiftUI

// Variants, hooks and history of the post. The MCP server writes the same files:
//
//   posts/variants/<slug>.md                  other versions, shown as tabs (front matter name, author, note, created)
//   posts/hooks.json                          opening options, in the format of the script's hooks.json
//   posts/history/<stamp>-<linkedin|slug>.md  every version (front matter author, note, created, draft)
//
// Only posts/linkedin.md goes out. "Use as Main" copies a variant into it.

@MainActor
extension PostFile {
    static func variantsDir(_ s: URL, _ p: PostPlatform = .linkedin) -> URL { s.appending(path: p.dir + "/variants") }
    static func historyDir(_ s: URL, _ p: PostPlatform = .linkedin) -> URL { s.appending(path: p.dir + "/history") }
    static func hooksURL(_ s: URL, _ p: PostPlatform = .linkedin) -> URL { s.appending(path: p.dir + "/hooks.json") }
    static func variantURL(_ slug: String, in s: URL, _ p: PostPlatform = .linkedin) -> URL {
        variantsDir(s, p).appending(path: "\(slug).md")
    }

    /// The file a comment on this draft points at.
    static func rel(of draft: String, _ p: PostPlatform = .linkedin) -> String {
        draft == "main" ? p.rel : "\(p.dir)/variants/\(draft).md"
    }

    static func variants(_ s: URL, _ p: PostPlatform = .linkedin) -> [Variant] {
        let files = (try? FileManager.default.contentsOfDirectory(at: variantsDir(s, p), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { f -> Variant? in
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
            let (m, body) = FrontMatter.parse(raw)
            let slug = f.deletingPathExtension().lastPathComponent
            return Variant(slug: slug, name: m["name"] ?? SessionDoc.titleFromFolder(slug), author: m["author"] ?? "",
                           note: m["note"] ?? "", created: m["created"] ?? "", text: body)
        }
        .sorted { ($0.created, $0.slug) < ($1.created, $1.slug) }
    }

    static func variantStamps(_ s: URL, _ p: PostPlatform = .linkedin) -> [String: Date] {
        let files = (try? FileManager.default.contentsOfDirectory(at: variantsDir(s, p), includingPropertiesForKeys: nil)) ?? []
        var out: [String: Date] = [:]
        for f in files where f.pathExtension == "md" { out[f.lastPathComponent] = Store.modified(f) ?? .distantPast }
        return out
    }

    static func writeVariant(_ v: Variant, in s: URL, _ p: PostPlatform = .linkedin) {
        try? FileManager.default.createDirectory(at: variantsDir(s, p), withIntermediateDirectories: true)
        let raw = FrontMatter.render([("name", v.name), ("author", v.author), ("note", v.note), ("created", v.created)], v.text)
        try? raw.write(to: variantURL(v.slug, in: s, p), atomically: true, encoding: .utf8)
    }

    /// Newest first. File names start with a stamp that sorts by time.
    static func versions(_ s: URL, _ p: PostPlatform = .linkedin) -> [ScriptVersion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: historyDir(s, p), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { f -> ScriptVersion? in
                guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
                let m = FrontMatter.parse(raw).0
                let created = m["created"].flatMap { SessionDoc.iso.date(from: $0) ?? SessionDoc.isoNoFraction.date(from: $0) }
                return ScriptVersion(url: f, created: created ?? .distantPast, author: m["author"] ?? "",
                                     note: m["note"] ?? "", draft: m["draft"] ?? "main")
            }
    }

    /// How many versions there are, from the file names alone. `versions` reads every file, and
    /// the post reloads on each file change in the session (once a second while Claude renders).
    static func versionCount(_ s: URL, _ p: PostPlatform = .linkedin) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: historyDir(s, p).path)) ?? []).filter { ($0 as NSString).pathExtension == "md" }.count
    }

    /// The server's stamp: local time to the microsecond.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSSSSS"
        return f
    }()

    /// Keeps the text in history, unless it is empty or the same as that draft's last version.
    /// The first comment, posted under the live post. Plain text, one per session (2026-09-28).
    static let firstCommentRel = "posts/first-comment.md"

    static func firstComment(_ s: URL) -> String {
        (try? String(contentsOf: s.appending(path: firstCommentRel), encoding: .utf8)) ?? ""
    }

    /// Writes the text as typed, so reading it back changes nothing. Empty removes the file.
    static func writeFirstComment(_ s: URL, _ text: String) {
        let u = s.appending(path: firstCommentRel)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: u)
            return
        }
        guard firstComment(s) != text else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    @discardableResult
    static func snapshot(_ s: URL, draft: String, text: String, author: String = "user", note: String,
                         _ p: PostPlatform = .linkedin) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              versions(s, p).first(where: { $0.draft == draft })?.text() != text else { return false }
        let dir = historyDir(s, p)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        // DateFormatter stops at milliseconds, so two saves in one millisecond got the same name
        // and one was lost. Write the microseconds ourselves and step past a name that exists.
        let base = String(stamp.string(from: now).prefix(15))   // yyyyMMdd-HHmmss
        var micro = Int((now.timeIntervalSince1970 * 1_000_000).truncatingRemainder(dividingBy: 1_000_000))
        let suffix = draft == "main" ? p.rawValue : draft
        var file: URL { dir.appending(path: "\(base)-\(String(format: "%06d", micro))-\(suffix).md") }
        while FileManager.default.fileExists(atPath: file.path) && micro < 999_999 { micro += 1 }
        let raw = FrontMatter.render([("author", author), ("note", note), ("created", SessionDoc.iso.string(from: now)),
                                      ("draft", draft)], text)
        return (try? raw.write(to: file, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - Tabs

/// Main and the variants as tabs with a sliding underline, a + for a copy, and the history button.
struct PostDraftBar: View {
    @ObservedObject var post: PostStore
    @Binding var showHistory: Bool
    @State private var renaming: String?
    @State private var name = ""
    @FocusState private var renameFocused: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            // The chips at their own width; they scroll only when they do not fit.
            ViewThatFits(in: .horizontal) {
                chips
                ScrollView(.horizontal, showsIndicators: false) { chips }
            }
            .fixedSize(horizontal: false, vertical: true)
            if post.draft != "main" {
                Button("Use as Main") { withAnimation(Theme.spring) { post.promote(post.draft) } }
                    .buttonStyle(BracketButtonStyle())
                    .help("This variant becomes the post that goes out. The old main stays in history.")
                    .transition(.opacity.combined(with: .offset(x: -6)))
            }
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).frame(width: 28, height: 26)
            }
            .buttonStyle(IconButtonStyle())
            .help("Post history: \(post.historyCount) versions")
        }
        .animation(Theme.spring, value: post.draft)
    }

    private var chips: some View {
        HStack(spacing: 2) {
            chip("main", "Main", author: "", note: "The post that goes out")
            ForEach(post.variants) { v in chip(v.slug, v.name, author: v.author, note: v.note) }
            Button { withAnimation(Theme.spring) { post.newVariant() } } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(IconButtonStyle())
            .help("New variant (a copy of what you see)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func chip(_ slug: String, _ label: String, author: String, note: String) -> some View {
        let on = post.draft == slug
        Group {
            if renaming == slug {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .frame(width: max(80, CGFloat(name.count) * 8))
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, f in if !f { commitRename() } }
            } else {
                HStack(spacing: 4) {
                    if author == "claude" { Image(systemName: "sparkles").font(.caption2) }
                    Text(label).lineLimit(1)
                }
            }
        }
        .font(Theme.sans(12.5, .medium))
        .foregroundStyle(on ? Theme.ink : Theme.faint)
        .padding(.horizontal, 9).frame(height: 26)
        .overlay(alignment: .bottom) {
            if on {
                Capsule().fill(Theme.ink).frame(height: 1.5).padding(.horizontal, 9)
                    .matchedGeometryEffect(id: "underline", in: ns)
            }
        }
        .background(HoverBackground())
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { startRename(slug, label) })
        .simultaneousGesture(TapGesture().onEnded {
            if renaming != slug && post.draft != slug { post.flush(); withAnimation(Theme.spring) { post.draft = slug } }
        })
        .help(slug == "main" ? note : "\(note.isEmpty ? label : note) · double-click to rename")
        .contextMenu {
            if slug != "main" {
                Button("Rename…") { startRename(slug, label) }
                Button("Use as Main") { post.promote(slug) }
                Divider()
                Button("Delete Variant", role: .destructive) { post.delete(slug) }
            }
        }
    }

    private func startRename(_ slug: String, _ label: String) {
        guard slug != "main" else { return }
        name = label
        renaming = slug
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let slug = renaming else { return }
        FieldUndo.drop()
        renaming = nil
        post.rename(slug, to: name)
    }
}

// MARK: - Hooks

/// Claude's opening options for the post (MCP set_post_hooks), and the comments on it: two small
/// tabs in the right gutter. Each opens a drawer. Pointing at a hook shows it in the post; a click
/// puts it there (it replaces the first paragraph, the lines the feed shows above "…more").
struct PostSideTabs: View {
    @ObservedObject var hooks: HookStore
    let current: Hook?
    let comments: [Comment]
    let focused: String?
    let preview: (Hook?) -> Void
    let use: (Hook) -> Void
    let pickComment: (Comment) -> Void
    @State private var open: Drawer?

    enum Drawer { case hooks, comments }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if open == nil {
                if !hooks.hooks.isEmpty {
                    tab("Hooks", count: hooks.hooks.count, accent: true) { open = .hooks }
                        .help("The opening lines Takes wrote. Point at one to see it in the post.")
                }
                if !comments.isEmpty {
                    let n = comments.filter(\.open).count
                    tab("Comments", count: n > 0 ? n : comments.count, accent: false) { open = .comments }
                        .help(n > 0 ? "\(n) open for Takes" : "All resolved")
                }
            } else {
                drawer
                    .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)
                                                .combined(with: .offset(x: 10)),
                                            removal: .opacity))
            }
        }
        .animation(Theme.spring, value: open)
        .onExitCommand { open = nil; preview(nil) }
    }

    private func tab(_ title: String, count: Int, accent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { SideTabLabel(title: title, count: count, accent: accent) }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .offset(x: 8)))
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(open == .hooks ? "Hooks" : "Comments").font(Theme.sans(12, .medium)).foregroundStyle(Theme.faint)
                Spacer()
                Button { open = nil; preview(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(IconButtonStyle())
            }
            .padding(.leading, 8).padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 1) {
                    if open == .hooks {
                        ForEach(hooks.hooks) { h in
                            HookDrawerRow(hook: h, current: current?.id == h.id,
                                          hover: { on in preview(on ? h : nil) },
                                          use: { use(h) })
                        }
                    } else {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                            CommentDrawerRow(n: i + 1, comment: c, focused: focused == c.id) { pickComment(c) }
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(width: 290)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
        .onHover { if !$0 { preview(nil) } }
    }
}

/// "Hooks 5": a pill that leans out a little on hover.
private struct SideTabLabel: View {
    let title: String
    let count: Int
    let accent: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.sans(12, .medium))
            Text("\(count)").font(Theme.sans(10.5, .bold)).monospacedDigit()
                .foregroundStyle(accent ? .white : Theme.muted)
                .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
                .background(accent ? Theme.accent : Theme.hover, in: Capsule())
        }
        .foregroundStyle(hover ? Theme.ink : Theme.muted)
        .padding(.leading, 10).padding(.trailing, 5).frame(height: 27)
        .background(Theme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: Theme.shadow, radius: 6, y: 2)
        .offset(x: hover ? -3 : 0)
        .contentShape(Capsule())
        .onHover { h in withAnimation(Theme.spring) { hover = h } }
    }
}

private struct HookDrawerRow: View {
    let hook: Hook
    let current: Bool
    let hover: (Bool) -> Void
    let use: () -> Void
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if current { Circle().fill(Theme.accent).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                Text(hook.text).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack {
                if let note = hook.note, !note.isEmpty {
                    Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(2)
                }
                Spacer(minLength: 6)
                Text(current ? "In the post" : "Use").font(Theme.sans(11, .medium))
                    .foregroundStyle(current ? Theme.faint : Theme.accentInk)
                    .opacity(on || current ? 1 : 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.motion) { on = h }; hover(h) }
        .onTapGesture { if !current { use() } }
        .help(current ? "This hook opens the post now" : "Put this hook at the top of the post")
    }
}

private struct CommentDrawerRow: View {
    let n: Int
    let comment: Comment
    let focused: Bool
    let pick: () -> Void
    @State private var on = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.sans(10, .bold)).foregroundStyle(comment.open ? .white : Theme.muted)
                .frame(minWidth: 17, minHeight: 17)
                .background(comment.open ? Theme.accent : Theme.hover, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.text).font(Theme.sans(12.5)).foregroundStyle(comment.open ? Theme.ink : Theme.faint)
                    .lineLimit(3)
                if let r = comment.replies?.last, r.by != "user" {
                    Text("↳ \(r.text)").font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(on || focused ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.motion) { on = h } }
        .onTapGesture(perform: pick)
        .help(comment.quote.map { "“\($0)”" } ?? comment.text)
    }
}
