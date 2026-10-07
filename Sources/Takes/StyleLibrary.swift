import AppKit
import AVFoundation
import CoreText
import SwiftUI

// The style library: a style guide, design tokens and reusable assets, for Claude to build on and for
// you to review and comment on.
//
//   <root>/_library/styles/<Style>/     your named styles (Magazine, …); each project picks one
//   <root>/<project>/_library/          one project's own additions (win over the style)
//   <root>/<project>/_library/project.json   {"style": "<Style>"}: the project's pick
//
// Each style and each project library has the layout of a claude.ai Design System, so it exports cleanly:
//
//   README.md                          the style guide
//   tokens.json                        colours, type, spacing, radius as lists of {name, value, usage}
//   assets/<Group>/<name>-vN.<ext>     logos, icons, images, motion graphics (rendered .mp4)
//   fonts/                             font files
//   src/                               sources, e.g. HyperFrames compositions (not shown)
//   comments.json, comments/           your comments, same format as a session's
//   style.json                         (styles only) {"template", "description", "source", "status": "new"}
//   preview.mp4, preview.png           (styles only) the shared sample clip in this style
//   assets.json                        each asset's note and the session it came from (save_to_library)
//
// A video can pick its own style (session.json "style"); else it uses its project's.
//
// Folders whose name starts with "_" are never projects or sessions.

enum StyleLib {
    static let folder = "_library"

    static func user(root: URL) -> URL { root.appending(path: folder) }
    static func project(_ project: URL) -> URL { project.appending(path: folder) }
    static func styles(root: URL) -> URL { user(root: root).appending(path: "styles") }
    static func style(_ name: String, root: URL) -> URL { styles(root: root).appending(path: name) }

    /// Your styles, A–Z.
    static func styleNames(root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: styles(root: root), includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter(\.hasDirectoryPath).map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The style a project uses: its pick, else Magazine, else the first one.
    static func chosen(project: URL, root: URL) -> String? {
        let names = styleNames(root: root)
        let file = self.project(project).appending(path: "project.json")
        if let data = try? Data(contentsOf: file),
           let pick = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["style"] as? String,
           names.contains(pick) { return pick }
        return names.contains("Magazine") ? "Magazine" : names.first
    }

    /// The style a video uses: its own pick, else its project's.
    static func chosen(session: URL, pick: String?, root: URL) -> String? {
        if let pick, styleNames(root: root).contains(pick) { return pick }
        return chosen(project: session.deletingLastPathComponent(), root: root)
    }

    /// Every style with what the Styles gallery shows. Walks the sessions: call it off the main thread.
    static func cards(root: URL) -> [StyleCard] {
        let fm = FileManager.default
        let names = styleNames(root: root)
        var used: [String: [URL]] = [:]
        let projects = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") }
        for p in projects {
            let projectStyle = chosen(project: p, root: root)
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where s.hasDirectoryPath && !s.lastPathComponent.hasPrefix("_") {
                let edits = (try? fm.contentsOfDirectory(atPath: s.appending(path: "edits").path)) ?? []
                guard edits.contains(where: { ["mp4", "mov"].contains(($0 as NSString).pathExtension.lowercased()) }) else { continue }
                let pick = json(s.appending(path: "session.json"))["style"] as? String
                if let name = pick.flatMap({ names.contains($0) ? $0 : nil }) ?? projectStyle {
                    used[name, default: []].append(s)
                }
            }
        }
        return names.map { n in
            let dir = style(n, root: root)
            let meta = json(dir.appending(path: "style.json"))
            let file = { (name: String) -> URL? in
                let u = dir.appending(path: name)
                return fm.fileExists(atPath: u.path) ? u : nil
            }
            return StyleCard(name: n, description: meta["description"] as? String ?? "",
                             source: meta["source"] as? String, isNew: meta["status"] as? String == "new",
                             video: file("preview.mp4"), poster: file("preview.png"), usedBy: (used[n] ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent })
        }
    }

    static func json(_ url: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    /// He keeps a new style: it loses its "New" mark.
    static func keep(_ name: String, root: URL) {
        let url = style(name, root: root).appending(path: "style.json")
        var meta = json(url)
        meta["status"] = nil
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url, options: .atomic)
        }
    }

    static func choose(_ name: String, project: URL) {
        let dir = self.project(project)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["style": name], options: [.prettyPrinted]) {
            try? data.write(to: dir.appending(path: "project.json"), options: .atomic)
        }
    }

    /// The library folder a file sits in, if any: a style folder, or a project's _library.
    static func root(containing url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.lastIndex(of: folder) else { return nil }
        let end = parts.count > i + 3 && parts[i + 1] == "styles" ? i + 2 : i
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...end])))
    }

    /// The folder that holds the _library a file sits in: a project, or the Takes root for a style.
    static func owner(containing url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.lastIndex(of: folder), i > 0 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<i])))
    }

    /// "logo-v3.svg" -> ("logo", 3). No -vN -> version nil.
    static func split(_ name: String) -> (base: String, version: Int?) {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        guard let r = stem.range(of: #"-v(\d+)$"#, options: .regularExpression),
              let n = Int(stem[r].dropFirst(2)) else { return (stem + ext, nil) }
        return (String(stem[..<r.lowerBound]) + ext, n)
    }
}

/// A style as the gallery shows it.
struct StyleCard: Identifiable, Hashable {
    let name: String
    let description: String
    let source: String?
    let isNew: Bool
    let video: URL?
    /// preview.png: the best frame. The video's first frame is often a blank title card.
    let poster: URL?
    /// What a click opens: preview.mp4, else preview.png.
    var preview: URL? { video ?? poster }
    /// Sessions with edits that use this style.
    let usedBy: [URL]
    var id: String { name }
}

/// One asset with all its versions, oldest first.
struct LibItem: Identifiable, Hashable {
    let group: String
    let name: String        // "logo.svg", without the version
    var versions: [Asset]
    var id: String { "\(group)/\(name)" }
    var latest: Asset { versions[versions.count - 1] }
}

struct AssetNote: Hashable {
    let note: String
    let from: String?
}

struct Swatch: Hashable {
    let name: String
    let value: String
    let usage: String
    let color: Color?
}

struct TypeSample: Hashable {
    let name: String
    let family: String      // first family in the stack
    let size: CGFloat
    let weight: Int
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var exists = false
    @Published private(set) var readme: String?
    @Published private(set) var swatches: [Swatch] = []
    @Published private(set) var type: [TypeSample] = []
    @Published private(set) var others: [(family: String, count: Int)] = []
    @Published private(set) var groups: [(name: String, items: [LibItem])] = []
    @Published private(set) var hasTokens = false
    /// assets.json: path in the library -> what it is, and the session it came from.
    @Published private(set) var notes: [String: AssetNote] = [:]
    var hasContent: Bool { exists && (readme != nil || hasTokens || !groups.isEmpty) }
    private(set) var url: URL?
    private var stamp: String = ""
    private static var registered: Set<String> = []

    func scan(_ dir: URL) {
        url = dir
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            if exists || url != dir { reset() }
            return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [Asset] = []
        if let walk = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let base = dir.standardizedFileURL.pathComponents.count
            for case let file as URL in walk {
                let parts = Array(file.standardizedFileURL.pathComponents.dropFirst(base))
                if parts.count == 1 && ["comments", "src"].contains(parts[0]) { walk.skipDescendants(); continue }
                guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files.append(Asset(url: file, group: parts.first ?? "", name: parts.dropFirst().joined(separator: "/"),
                                   size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
                if files.count >= 2000 { break }
            }
        }
        // Rebuild only when something changed on disk.
        let fresh = files.map { "\($0.url.path)|\($0.modified.timeIntervalSince1970)" }.sorted().joined(separator: "\n")
        guard fresh != stamp || !exists else { return }
        stamp = fresh
        exists = true

        let readmeURL = dir.appending(path: "README.md")
        readme = try? String(contentsOf: readmeURL, encoding: .utf8)
        registerFonts(files.filter { $0.group == "fonts" })
        readTokens(dir.appending(path: "tokens.json"))
        notes = StyleLib.json(dir.appending(path: "assets.json")).compactMapValues { v in
            guard let m = v as? [String: Any] else { return nil }
            return AssetNote(note: m["note"] as? String ?? "", from: m["from"] as? String)
        }

        var byItem: [String: LibItem] = [:]
        for f in files where f.group == "assets" {
            let parts = f.name.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let group = parts[0]
            let (base, _) = StyleLib.split(parts[1])
            let a = Asset(url: f.url, group: group, name: parts[1], size: f.size, modified: f.modified)
            byItem["\(group)/\(base)", default: LibItem(group: group, name: base, versions: [])].versions.append(a)
        }
        let items = byItem.values.map { item -> LibItem in
            var i = item
            i.versions.sort { (StyleLib.split($0.name).version ?? 0, $0.modified) < (StyleLib.split($1.name).version ?? 0, $1.modified) }
            return i
        }
        let grouped = Dictionary(grouping: items, by: \.group)
        groups = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { g in (g, grouped[g]!.sorted { $0.latest.modified > $1.latest.modified }) }
    }

    private func reset() {
        exists = false; readme = nil; swatches = []; type = []; others = []; groups = []; hasTokens = false; stamp = ""
        notes = [:]
    }

    private func registerFonts(_ fonts: [Asset]) {
        for f in fonts where ["otf", "ttf", "woff", "woff2"].contains(f.url.pathExtension.lowercased()) {
            guard !Self.registered.contains(f.url.path) else { continue }
            Self.registered.insert(f.url.path)
            CTFontManagerRegisterFontsForURL(f.url as CFURL, .process, nil)
        }
    }

    /// Reads the list shape a claude.ai Design System uses. Unknown values are shown as text.
    private func readTokens(_ file: URL) {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            hasTokens = false; swatches = []; type = []; others = []; return
        }
        hasTokens = true
        let color = json["color"] as? [String: Any]
        swatches = (color?["tokens"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let raw: String
            if let s = t["value"] as? String { raw = s }
            else if let m = t["value"] as? [String: Any] {
                let first = ((color?["themes"] as? [[String: Any]])?.first?["id"] as? String) ?? "light"
                raw = (m[first] as? String) ?? (m.values.first as? String) ?? ""
            } else { raw = "" }
            return Swatch(name: name, value: raw, usage: t["usage"] as? String ?? "", color: Self.color(raw))
        }
        var samples: [TypeSample] = []
        if let t = json["type"] as? [String: Any] {
            let families = t["families"] as? [String: String] ?? [:]
            for g in t["groups"] as? [[String: Any]] ?? [] {
                let stack = families[g["family"] as? String ?? ""] ?? (g["family"] as? String ?? "")
                let family = stack.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } ?? ""
                for s in g["styles"] as? [[String: Any]] ?? [] {
                    let size = Double(String(describing: s["fontSize"] ?? "16").replacingOccurrences(of: "px", with: "")) ?? 16
                    let weight = (s["fontWeight"] as? Int) ?? Int(String(describing: s["fontWeight"] ?? "400")) ?? 400
                    samples.append(TypeSample(name: s["name"] as? String ?? "", family: family, size: size, weight: weight))
                }
            }
        }
        type = samples
        others = json.keys.filter { !["color", "type", "name", "version", "meta"].contains($0) }.sorted().map { k in
            (k, ((json[k] as? [String: Any])?["tokens"] as? [Any])?.count ?? 0)
        }
    }

    /// #rgb, #rrggbb, #rrggbbaa. Anything else: nil (shown as text).
    static func color(_ s: String) -> Color? {
        var h = s.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let (r, g, b, a) = h.count == 6
            ? ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, UInt64(255))
            : ((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - Pane

/// The Styles board: fills the window like Performance. Every style side by side, then the open
/// style's guide, tokens and parts (with Claude's notes). A picked file plays on the left, where
/// you comment on it. Styles belong to no one video: a video picks its style on its Assets tab.
struct StylesBoard: View {
    @Environment(AppModel.self) var app
    let root: URL
    @StateObject private var store = LibraryStore()
    @StateObject private var comments = CommentStore()
    @State private var names: [String] = []
    @State private var cards: [StyleCard] = []
    /// The library whose parts show below the gallery: a style, or one project's own additions.
    @State private var opened: URL?
    @State private var projects: [URL] = []
    @State private var asking = false
    @State private var example = ""

    private var openDir: URL? { opened ?? names.first.map { StyleLib.style($0, root: root) } }
    private var openName: String? { openDir.map { dir in
        dir.lastPathComponent == StyleLib.folder ? "only \(dir.deletingLastPathComponent().lastPathComponent)" : dir.lastPathComponent } }

    var body: some View {
        HStack(spacing: 0) {
            if let f = app.styleFile {
                stage(f).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    gallery
                    if let dir = openDir, let openName {
                        LibrarySection(number: "01", title: openName,
                                       subtitle: dir.lastPathComponent == StyleLib.folder ? "Wins over the style" : "Guide, colours, type and parts",
                                       dir: dir, store: store, comments: comments,
                                       copyTargets: copyTargets(from: dir), onShow: { app.styleFile = $0 })
                    }
                    if !projects.isEmpty { projectList }
                }
                .padding(.horizontal, app.styleFile == nil ? 32 : 20).padding(.vertical, app.styleFile == nil ? 28 : 20)
                .frame(maxWidth: app.styleFile == nil ? 1100 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: app.styleFile == nil ? nil : 440)
            .frame(maxWidth: app.styleFile == nil ? .infinity : 440)
        }
        .background(Theme.paper)
        .onAppear { focus(); scan() }
        .onChange(of: app.styleFile) { focus() }
        .onChange(of: opened) { scan() }
        .onFilesChanged(in: StyleLib.user(root: root)) { if !app.isRecording { scan() } }
        .onExitCommand { app.styleFile = nil }
    }

    /// A file opened from elsewhere (a link, get_library): open its library too.
    private func focus() {
        if let f = app.styleFile, let lib = StyleLib.root(containing: f), lib != opened { opened = lib }
    }

    @ViewBuilder private func stage(_ url: URL) -> some View {
        let commentRoot = StyleLib.root(containing: url) ?? root
        ZStack(alignment: .topTrailing) {
            Group {
                if Asset.kind(of: url) == .image { StillReview(url: url, session: commentRoot).id(url) }
                else if Asset.kind(of: url) == .video { ReviewPlayer(url: url, session: commentRoot).id(url) }
                else if DocReview.handles(url) { DocReview(url: url, root: commentRoot).id(url) }
                else { PlayerView(url: url) { _ in }.id(url) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.stage)
            Button { app.styleFile = nil } label: { StagePill(text: "Close", icon: "xmark") }
                .buttonStyle(.plain).padding(12)
                .help("Close the player (Esc)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Styles").font(Theme.display(28)).foregroundStyle(Theme.ink)
                Text("Each video picks its style on its Assets tab.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { asking = true } label: { Label("New style", systemImage: "plus") }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
                .help("Takes makes a new style from your example: a link, a video, an image, or words")
                .popover(isPresented: $asking, arrowEdge: .bottom) { examplePopover }
        }
    }

    // MARK: Gallery

    private var gallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)], alignment: .leading, spacing: 24) {
            ForEach(cards) { c in card(c) }
        }
    }

    /// A style: its preview, its name, and the videos that use it. The rest is in the tooltip.
    private func card(_ c: StyleCard) -> some View {
        let dir = StyleLib.style(c.name, root: root)
        let isOpen = dir.standardizedFileURL == openDir?.standardizedFileURL
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if c.preview != nil {
                    StylePoster(video: c.video, poster: c.poster, selected: isOpen) { opened = dir }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Theme.faint)
                        Button("Make a preview") { ask(Self.previewAsk(c.name)) }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                            .help("Takes renders the shared sample clip in this style")
                    }
                    .frame(maxWidth: .infinity).aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isOpen ? Theme.accent : Theme.border, lineWidth: isOpen ? 2 : 1))
                    .onTapGesture { opened = dir }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.name).font(Theme.display(15)).foregroundStyle(Theme.ink).lineLimit(1)
                    if c.isNew {
                        Text("New").font(Theme.sans(10, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accent, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if c.usedBy.isEmpty {
                        Text("Not used yet").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    } else {
                        Menu {
                            ForEach(c.usedBy, id: \.self) { s in
                                Button(s.lastPathComponent) { app.board = nil; app.go(s) }
                            }
                        } label: {
                            Text("In \(c.usedBy.count) video\(c.usedBy.count == 1 ? "" : "s")").font(Theme.sans(11.5))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("The videos with edits in this style. Pick one to open it.")
                    }
                    Spacer(minLength: 0)
                    if c.isNew {
                        Button("Keep") { StyleLib.keep(c.name, root: root); scan() }
                            .buttonStyle(BracketButtonStyle(active: false))
                            .help("Keep this style. It loses the New mark.")
                        Button("Trash") { trash(c) }
                            .buttonStyle(BracketButtonStyle(active: false))
                            .help("Move this style to the Trash")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { opened = dir }
        .help([c.description, c.source.map { "From \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.revealSoon([dir]) }
            if let p = c.preview { Button("Open to comment on it") { opened = dir; app.styleFile = p } }
            if c.preview != nil { Button("Render the preview again") { ask(Self.previewAsk(c.name)) } }
            Divider()
            Button("Move to Trash") { trash(c) }
        }
    }

    private var examplePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New style from an example").font(Theme.sans(13, .semibold))
            Text("Paste a link, drop a video or an image, or describe the look.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            TextField("https://… or “big yellow captions, black cards”", text: $example, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit(make)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }.buttonStyle(AccentButtonStyle(kind: .quiet))
                Button("Make it", action: make).buttonStyle(AccentButtonStyle(kind: .solid))
                    .disabled(example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in example += (example.isEmpty ? "" : " ") + url.path }
                }
            }
            return true
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "looks only one project has")
            ForEach(projects, id: \.self) { p in
                let dir = StyleLib.project(p)
                Button { opened = dir } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.faint)
                        Text(p.lastPathComponent).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(dir.standardizedFileURL == openDir?.standardizedFileURL ? Theme.accentSoft : Theme.surface,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func make() {
        let x = example.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty else { return }
        ask("""
        Make a new style from this example: \(x)
        Call create_style (name it yourself, 1-3 words) and follow every step it returns: the guide, the \
        tokens, the parts (each kept with save_to_library), and preview.mp4 + preview.png from the shared sample.
        """)
        example = ""
        asking = false
    }

    static func previewAsk(_ name: String) -> String {
        "Render preview.mp4 and preview.png for my style \(name): the shared sample clip (get_library gives its path) with this style's title card, a caption and the lower third on it."
    }

    private func ask(_ text: String) {
        app.chats.styles.send(text, title: "Styles", onStage: nil)
        app.chats.open = true
        app.show(toast: "Sent to Takes")
    }

    private func trash(_ c: StyleCard) {
        let dir = StyleLib.style(c.name, root: root)
        if let f = app.styleFile, f.path.hasPrefix(dir.path + "/") { app.styleFile = nil }
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        if opened == dir { opened = nil }
        app.show(toast: "\(c.name) moved to the Trash")
        scan()
    }

    private func scan() {
        names = StyleLib.styleNames(root: root)
        projects = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { p in
                guard p.hasDirectoryPath, !p.lastPathComponent.hasPrefix("_") else { return false }
                let items = (try? FileManager.default.contentsOfDirectory(atPath: StyleLib.project(p).path)) ?? []
                return items.contains { $0 != "project.json" && !$0.hasPrefix(".") }
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let openDir {
            store.scan(openDir)
            comments.load(openDir)
        }
        let r = root
        Task {
            let found = await Task.detached(priority: .utility) { StyleLib.cards(root: r) }.value
            if found != cards { cards = found }
        }
    }

    /// Other libraries a file can go to: every style, then every project's own library.
    private func copyTargets(from dir: URL) -> [(name: String, dir: URL)] {
        let all = names.map { ("Style: \($0)", StyleLib.style($0, root: root)) }
            + projects.map { ("Only \($0.lastPathComponent)", StyleLib.project($0)) }
        return all.filter { $0.1.standardizedFileURL != dir.standardizedFileURL }
    }
}

/// "Style [Magazine ▾] · from the project": the style one video uses, on its Assets tab.
struct StyleChip: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    var showLink = false
    @State private var names: [String] = []

    private var projectURL: URL { doc.url.deletingLastPathComponent() }
    private var rootURL: URL { projectURL.deletingLastPathComponent() }
    /// Read from disk on appear and on changes, not in every draw (it lists the styles folder).
    @State private var projectStyle: String?
    private var own: String? { doc.meta.style.flatMap { names.contains($0) ? $0 : nil } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Style").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.faint)
            if names.isEmpty {
                Text("none yet").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            } else {
                Menu {
                    Button { set(nil) } label: {
                        let t = "Same as the project (\(projectStyle ?? "none"))"
                        if own == nil { Label(t, systemImage: "checkmark") } else { Text(t) }
                    }
                    Divider()
                    ForEach(names, id: \.self) { n in
                        Button { set(n) } label: {
                            if n == own { Label(n, systemImage: "checkmark") } else { Text(n) }
                        }
                    }
                    if let own, own != projectStyle {
                        Divider()
                        Button("Use \(own) for All of \(projectURL.lastPathComponent)") {
                            StyleLib.choose(own, project: projectURL)
                            readProjectStyle()
                            set(nil)
                        }
                    }
                } label: {
                    // Our own label: the system button drew dark text on the dark theme (2026-10-06).
                    HStack(spacing: 4) {
                        Text(own ?? projectStyle ?? "none").font(Theme.sans(12.5, .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("The style Takes edits this video in")
                Text(own == nil ? "from the project" : "this video only")
                    .font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
            if showLink {
                Button { app.board = .styles } label: { Text("styles") }
                    .buttonStyle(BracketButtonStyle(active: false))
                    .help("See every style side by side")
            }
        }
        .onAppear { names = StyleLib.styleNames(root: rootURL); readProjectStyle() }
        .onFilesChanged(in: StyleLib.user(root: rootURL)) { names = StyleLib.styleNames(root: rootURL); readProjectStyle() }
        .onFilesChanged(in: projectURL) { readProjectStyle() }
    }

    private func readProjectStyle() {
        let s = StyleLib.chosen(project: projectURL, root: rootURL)
        if s != projectStyle { projectStyle = s }
    }

    private func set(_ name: String?) {
        doc.meta.style = name
        doc.save()
    }
}

struct LibrarySection: View {
    @Environment(AppModel.self) var app
    let number: String
    let title: String
    let subtitle: String
    let dir: URL
    @ObservedObject var store: LibraryStore
    @ObservedObject var comments: CommentStore
    let copyTargets: [(name: String, dir: URL)]
    /// Plays or reads a file. Default: the stage.
    var onShow: ((URL) -> Void)? = nil
    @State private var picked: [String: URL] = [:]   // item id -> the version on show

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.display(20)).foregroundStyle(Theme.ink)
                Text(subtitle).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
            }
            .contextMenu {
                if store.exists { Button("Show in Finder") { NSWorkspace.shared.revealSoon([dir]) } }
            }
            if !store.hasContent {
                empty
            } else {
                guide
                if store.hasTokens { tokens }
                ForEach(store.groups, id: \.name) { g in group(g.name, g.items) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Empty. Ask Takes to build it, or to copy from another library.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
            Text("README.md style guide · tokens.json colours and type · assets/<Group>/ logos, icons, motion")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft)
        .builderBorder()
    }

    private func open(_ path: String) -> Int { comments.on(path).filter(\.open).count }

    // MARK: Style guide

    @ViewBuilder private var guide: some View {
        if let readme = store.readme {
            let url = dir.appending(path: "README.md")
            Button { show(url) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label("Style guide", systemImage: "text.book.closed").font(Theme.sans(12, .semibold))
                            .foregroundStyle(Theme.accentInk)
                        Spacer()
                        badge(open("README.md"))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    Text(Self.preview(readme)).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                        .lineSpacing(2).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(app.preview == url ? Theme.accentSoft : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read and comment on README.md")
            .contextMenu { fileMenu(url, "README.md") }
        }
    }

    /// The first lines of prose, without Markdown marks.
    static func preview(_ md: String) -> String {
        md.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("---") }
            .prefix(5)
            .map { $0.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    // MARK: Tokens

    private var tokens: some View {
        let url = dir.appending(path: "tokens.json")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Colours and type", systemImage: "swatchpalette").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.accentInk)
                Spacer()
                badge(open("tokens.json"))
                Button { show(url) } label: { Text("tokens.json").font(Theme.sans(11.5)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint)
                    .help("Read and comment on the raw tokens")
            }
            if !store.swatches.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58, maximum: 72), spacing: 10)], alignment: .leading, spacing: 12) {
                    ForEach(store.swatches, id: \.self) { s in
                        VStack(spacing: 5) {
                            Circle()
                                .fill(s.color ?? .clear)
                                // Stronger than a hairline, so a colour near the page (ink in dark mode) still shows.
                                .overlay(Circle().strokeBorder(Theme.faint.opacity(0.45)))
                                .overlay { if s.color == nil { Text("?").font(Theme.sans(10)).foregroundStyle(Theme.muted) } }
                                .frame(width: 30, height: 30)
                            Text(s.name).font(Theme.sans(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .help(s.usage.isEmpty ? "\(s.name) \(s.value)" : "\(s.name) \(s.value)\n\(s.usage)")
                    }
                }
            }
            if !store.type.isEmpty {
                Divider().overlay(Theme.border)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.type, id: \.self) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(t.name).font(Theme.sans(11)).foregroundStyle(Theme.faint).frame(width: 64, alignment: .leading)
                                .lineLimit(1)
                            Text("Four days and 75 updates")
                                .font(Font(Self.font(t)))
                                .foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .help("\(t.family) · \(Int(t.size))px · \(t.weight)\(NSFont(name: t.family, size: 12) == nil && NSFontManager.shared.font(withFamily: t.family, traits: [], weight: 5, size: 12) == nil ? " · font not installed" : "")")
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .contextMenu { fileMenu(url, "tokens.json") }
    }

    static func font(_ t: TypeSample) -> NSFont {
        let size = min(22, max(11, t.size))
        // NSFontManager weights run 0-15; 5 is regular, 9 is bold.
        let w = t.weight >= 700 ? 9 : t.weight >= 600 ? 8 : t.weight >= 500 ? 6 : t.weight <= 300 ? 3 : 5
        return NSFontManager.shared.font(withFamily: t.family, traits: [], weight: w, size: size)
            ?? NSFont(name: t.family, size: size) ?? .systemFont(ofSize: size)
    }

    // MARK: Assets

    private func group(_ name: String, _ items: [LibItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(name.capitalized).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.accentInk)
                Text("\(items.count)").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 12)], alignment: .leading, spacing: 14) {
                ForEach(items) { item in tile(item) }
            }
        }
    }

    private func shown(_ item: LibItem) -> Asset {
        item.versions.first { $0.url == picked[item.id] } ?? item.latest
    }

    private func tile(_ item: LibItem) -> some View {
        let a = shown(item)
        let path = "assets/\(item.group)/"
        let openCount = item.versions.reduce(0) { $0 + open(path + $1.name) }
        return VStack(alignment: .leading, spacing: 5) {
            AssetTile(asset: Asset(url: a.url, group: item.group, name: item.name, size: a.size, modified: a.modified),
                      selected: app.preview == a.url, openComments: openCount)
                // Show on the first click, not after the double-click interval.
                .gesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.openSoon(a.url) })
                .simultaneousGesture(TapGesture().onEnded { if NSApp.firstClick { show(a.url) } })
                .onDrag { NSItemProvider(contentsOf: a.url) ?? NSItemProvider() }
                .contextMenu { fileMenu(a.url, path + a.name) }
            if let n = store.notes[path + a.name], !n.note.isEmpty {
                Text(n.note).font(Theme.sans(11)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(n.from.map { "\(n.note)\nFrom \($0)" } ?? n.note)
            }
            if item.versions.count > 1 {
                HStack(spacing: 3) {
                    ForEach(item.versions, id: \.url) { v in
                        let on = v.url == a.url
                        Button { picked[item.id] = v.url; show(v.url) } label: {
                            Text(StyleLib.split(v.name).version.map { "v\($0)" } ?? "–")
                                .font(Theme.mono(9.5, on ? .bold : .regular))
                                .foregroundStyle(on ? Color.white : Theme.muted)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(on ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .help(open(path + v.name) > 0 ? "\(v.name) · \(open(path + v.name)) open" : v.name)
                    }
                }
            }
        }
    }

    private func show(_ url: URL) {
        Perf.mark("style asset")
        if let onShow { onShow(url); return }
        switch Asset.kind(of: url) {
        case .video, .image, .audio: app.preview = url
        case .other: if DocReview.handles(url) { app.preview = url } else { NSWorkspace.shared.openSoon(url) }
        }
    }

    private func badge(_ n: Int) -> some View {
        Group {
            if n > 0 {
                Label("\(n)", systemImage: "text.bubble.fill").font(Theme.mono(10, .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .help("\(n) open comment\(n == 1 ? "" : "s") for Takes")
            }
        }
    }

    // MARK: Menu

    @ViewBuilder private func fileMenu(_ url: URL, _ rel: String) -> some View {
        Button("Open") { NSWorkspace.shared.openSoon(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.revealSoon([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Divider()
        Menu("Copy to Library") {
            ForEach(copyTargets, id: \.dir) { t in
                Button(t.name) { copy(url, rel, to: t.dir, name: t.name) }
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if app.preview == url { app.preview = nil }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            store.scan(dir)
        }
    }

    /// Copies one file to the same place in another library. Never overwrites.
    private func copy(_ url: URL, _ rel: String, to lib: URL, name: String) {
        let target = lib.appending(path: rel)
        if FileManager.default.fileExists(atPath: target.path) {
            app.show(toast: rel == "tokens.json" ? "\(name) has tokens. Ask Takes to merge them."
                                                 : "\(name) already has \(url.lastPathComponent)")
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            app.show(toast: "Copied to \(name)")
        } catch {
            app.show(toast: "Could not copy: \(error.localizedDescription)")
        }
    }
}

// MARK: - Text review

/// A text file (a style guide, tokens) in the stage: read it, select text, comment for Claude.
struct DocReview: View {
    @Environment(AppModel.self) var app
    let url: URL
    let root: URL
    @StateObject private var store = CommentStore()
    @State private var text = ""
    @State private var selection = ""
    @State private var draft: ReviewPlayer.Draft?
    @State private var focused: String?
    @State private var reveal: (quote: String, token: Int)?

    static let kinds: Set<String> = ["md", "markdown", "txt", "json", "css", "html", "svg", "js", "ts", "yaml", "yml"]
    static func handles(_ url: URL) -> Bool { kinds.contains(url.pathExtension.lowercased()) }

    private var file: String { CommentStore.path(of: url, in: root) }
    private var comments: [Comment] { store.on(file) }

    var body: some View {
        VStack(spacing: 0) {
            ScriptCommentList(comments: comments, focused: focused) { c in
                withAnimation(Theme.motion) { draft = nil; focused = c.id }
                if let q = c.quote { reveal = (q, (reveal?.token ?? 0) + 1) }
            }
            Prompter(text: .constant(text), contentKey: url.path, fontSize: 16, scrolling: false, speed: 0,
                     editable: false, resetToken: 0,
                     highlights: comments.filter(\.open).compactMap(\.quote), reveal: reveal,
                     onSelect: { selection = $0 }, onComment: start)
                .overlay(alignment: .bottomLeading) { card.padding(12) }
            bar
        }
        .environment(\.colorScheme, .dark)
        .task(id: url) { load() }
        .onAppear { store.load(root) }
        .onFilesChanged(in: root) { load(); store.load(root) }
        .onExitCommand { withAnimation(Theme.motion) { if draft != nil { draft = nil } else { focused = nil } } }
    }

    private func load() {
        let fresh = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if fresh != text { text = fresh }
    }

    private func start() {
        guard !selection.isEmpty else { return }
        withAnimation(Theme.motion) { focused = nil; draft = ReviewPlayer.Draft(quote: selection, timed: false) }
    }

    @ViewBuilder private var card: some View {
        if let d = draft {
            Composer(draft: Composer.bind($draft, d),
                     onSend: {
                         let t = (draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                         guard !t.isEmpty, let q = draft?.quote else { return }
                         if let c = store.add(script: file, quote: q, text: t) { app.show(toast: "Comment \(c.id) saved for Takes") }
                         withAnimation(Theme.motion) { draft = nil }
                     },
                     onCancel: { withAnimation(Theme.motion) { draft = nil } },
                     onArea: {})
        } else if let id = focused, let i = comments.firstIndex(where: { $0.id == id }) {
            let c = comments[i]
            CommentCard(comment: c, number: i + 1,
                        onReply: { store.reply(id, $0) },
                        onResolve: { store.setResolved(id, c.open) },
                        onDelete: { store.delete(id); focused = nil },
                        onClose: { withAnimation(Theme.motion) { focused = nil } },
                        onJump: { app.jump(to: root.appending(path: $0), at: $1) })
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Text(file).font(Theme.mono(10.5, .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(1).truncationMode(.middle).help(url.path)
            Spacer()
            Button(action: start) {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                    Text("Comment")
                }
                .font(Theme.mono(11, .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.accent.opacity(selection.isEmpty ? 0.35 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
                .foregroundStyle(.white.opacity(selection.isEmpty ? 0.6 : 1))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .help("Select text, then comment on it for Takes")
            Button { app.preview = nil } label: {
                Image(systemName: "xmark").font(.system(size: 13)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            .help(app.camera.paused ? "Close" : "Back to the live camera")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.stage)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
}

/// A style's preview in the gallery: preview.png (the best frame), with a play mark and the length.
/// Without a png, a frame from the middle of the clip: the first one is usually a blank title card.
/// Hover plays the clip in place, muted; a click turns the sound on or off. No player opens.
private struct StylePoster: View {
    let video: URL?
    let poster: URL?
    let selected: Bool
    var onSelect: () -> Void = {}
    @State private var image: NSImage?
    @State private var duration: Double?
    @State private var hover = false
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var sound = false

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Theme.stage)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .scaleEffect(hover && player == nil ? 1.03 : 1)
                        .animation(.easeOut(duration: 0.5), value: hover)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let player, hover {
                    StylePlayerLayer(player: player).transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if video != nil {
                    HStack(spacing: 6) {
                        Image(systemName: hover ? (sound ? "speaker.wave.2.fill" : "speaker.slash.fill") : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                        if hover {
                            Text(sound ? "Sound on" : "Click for sound").font(Theme.sans(11, .semibold))
                        } else if let duration {
                            Text(Self.time(duration)).font(Theme.sans(11, .semibold)).monospacedDigit()
                        }
                    }
                    // On a white pill in light and dark: a fixed dark ink, not the theme's.
                    .foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(hover ? 1 : 0.88), in: Capsule())
                    .padding(10)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
            .shadow(color: Theme.shadow, radius: hover ? 14 : 8, y: hover ? 6 : 3)
            .animation(Theme.motion, value: hover)
            .animation(Theme.motion, value: sound)
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                h ? play() : stop()
            }
            .onTapGesture {
                onSelect()
                guard let player else { return }
                sound.toggle()
                player.isMuted = !sound
            }
            .onDisappear(perform: stop)
            .task(id: [poster, video]) { await load() }
            .help(video == nil ? "" : "Hover to play. Click for sound.")
    }

    private func play() {
        guard let video else { return }
        if player == nil {
            let p = AVQueuePlayer()
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: video))
            player = p
        }
        player?.isMuted = !sound
        player?.seek(to: .zero)
        player?.play()
    }

    private func stop() {
        player?.pause()
        // Let go of the player: each card hovered once kept its looper and decoded copies.
        looper = nil
        player = nil
        sound = false
    }

    private func load() async {
        if let video {
            let asset = AVURLAsset(url: video)
            if let d = try? await asset.load(.duration) { duration = d.seconds.isFinite ? d.seconds : nil }
        }
        let still: NSImage?
        if let poster {
            still = await Task.detached(priority: .utility) { NSImage(contentsOf: poster) }.value
        } else if let video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 800)
            let at = CMTime(seconds: (duration ?? 2) * 0.6, preferredTimescale: 600)
            still = (try? await gen.image(at: at).image).map { NSImage(cgImage: $0, size: .zero) }
        } else { still = nil }
        // A new preview.mp4: drop the old player so the next hover plays the new file.
        player?.pause(); player = nil; looper = nil
        withAnimation(Theme.motion) { image = still }
    }

    private static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return "\(t / 60):\(String(format: "%02d", t % 60))"
    }
}

private struct StylePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v.layer as? AVPlayerLayer)?.player = player
    }
}
