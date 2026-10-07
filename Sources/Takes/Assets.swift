import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Everything in a session folder that is not the script system or a raw take is an asset:
//
//   edits/       cut or edited versions of the video, made by Claude, as <slug>-vN.mp4
//   thumbnails/  thumbnail images for an edit, made by Claude, as <slug>-vN.png
//   stills/      frames you saved from a paused video (S, or the "Save frame" button)
//   assets/      files you dropped onto the Assets tab
//   takes        the raw recordings (shown here too; they stay in the session folder)
// Reusable style (logos, icons, motion graphics, the style guide) lives in the library, not here.
//   anything else Claude or you put in the folder, grouped by its top-level folder

enum AssetKind { case video, image, audio, other }

struct Asset: Identifiable, Hashable {
    let url: URL
    let group: String   // top-level folder, "" = session folder itself
    let name: String    // path inside the group
    let size: Int64
    let modified: Date
    var take = false    // a raw recording from the take list
    var id: URL { url }
    /// Path inside the session folder (the key comments use).
    var rel: String { take || group.isEmpty ? name : "\(group)/\(name)" }

    var kind: AssetKind { Self.kind(of: url) }

    static func kind(of url: URL) -> AssetKind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        return .other
    }
}

@MainActor
final class AssetStore: ObservableObject {
    @Published private(set) var assets: [Asset] = []
    private(set) var url: URL?
    /// Files the script system and the take list own. Not shown here.
    nonisolated static let skipFiles: Set<String> = ["script.md", "session.json", "SESSION.md", ".order.json", "hooks.json", "comments.json", "evergreen.json", "cuts.json"]
    nonisolated static let skipFolders: Set<String> = ["variants", "history", "comments", "posts", "voice", "storyboard"]
    /// Shown first, in this order. Other folders follow A–Z, loose files last.
    static let known = ["edits", "thumbnails", "stills", "assets", "takes"]

    private var walking: Task<Void, Never>?

    /// The last list of each session this run: a tab that opens shows it at once, then checks.
    private static var last: [URL: [Asset]] = [:]

    /// Reads the folder now. After a click or a drop, so the list is right at once.
    func scan(_ doc: SessionDoc) {
        walking?.cancel()
        url = doc.url
        let found = Self.walk(doc.url, takeFiles: Set(doc.meta.takes.map(\.file)))
        Self.last[doc.url] = found
        if found != assets { assets = found }
    }

    /// Shows the list from the last visit, if there is one, and reads the folder off the main
    /// thread. Opening the tab no longer waits for the walk (2026-10-02).
    func open(_ doc: SessionDoc) {
        guard let hit = Self.last[doc.url] else { scan(doc); return }
        url = doc.url
        if hit != assets { assets = hit }
        refresh(doc)
    }

    /// Reads the folder on a background thread. For file changes from outside (Claude rendering),
    /// which come often: the walk never blocks the main thread.
    func refresh(_ doc: SessionDoc) {
        let root = doc.url, takeFiles = Set(doc.meta.takes.map(\.file))
        walking?.cancel()
        walking = Task {
            let found = await Task.detached(priority: .utility) { Self.walk(root, takeFiles: takeFiles) }.value
            guard !Task.isCancelled, url == root else { return }
            Self.last[root] = found
            if found != assets { assets = found }
        }
    }

    nonisolated private static func walk(_ root: URL, takeFiles: Set<String>) -> [Asset] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [Asset] = []
        let base = root.standardizedFileURL.pathComponents.count
        for case let file as URL in walk {
            let parts = Array(file.standardizedFileURL.pathComponents.dropFirst(base))
            guard let first = parts.first else { continue }
            if parts.count == 1 && Self.skipFiles.contains(first) { continue }
            // A "_" folder (a render's work files) is not shown: do not walk into it either.
            if Self.skipFolders.contains(first) || (parts.count == 1 && first.hasPrefix("_")) { walk.skipDescendants(); continue }
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  !first.hasPrefix("_"), !file.lastPathComponent.hasSuffix(".words.json") else { continue }  // transcripts
            let take = parts.count == 1 && takeFiles.contains(first)
            found.append(Asset(url: file,
                               group: take ? "takes" : parts.count == 1 ? "" : first,
                               name: parts.count == 1 ? first : parts.dropFirst().joined(separator: "/"),
                               size: Int64(v.fileSize ?? 0),
                               modified: v.contentModificationDate ?? .distantPast,
                               take: take))
            if found.count >= 1000 { break }
        }
        found.sort { ($0.group, $1.modified) < ($1.group, $0.modified) }  // newest first inside a group
        return found
    }

    var groups: [(name: String, assets: [Asset])] {
        let byGroup = Dictionary(grouping: assets, by: \.group)
        let order = Self.known.filter { byGroup[$0] != nil }
            + byGroup.keys.filter { !$0.isEmpty && !Self.known.contains($0) }.sorted()
            + (byGroup[""] != nil ? [""] : [])
        return order.map { ($0, byGroup[$0]!) }
    }

    /// Copies dropped files into assets/. Never moves or overwrites the originals.
    func add(_ urls: [URL]) {
        guard let root = url else { return }
        let dir = root.appending(path: "assets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for u in urls where !u.path.hasPrefix(root.path) {
            try? FileManager.default.copyItem(at: u, to: Self.free(dir.appending(path: u.lastPathComponent)))
        }
    }

    /// `name.ext`, or `name-2.ext`, … if that exists.
    nonisolated static func free(_ url: URL) -> URL {
        var target = url, n = 2
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appending(path: "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return target
    }
}

// MARK: - Frames

enum FrameGrabber {
    /// Writes the exact frame at `time` to <session>/stills/<video>-00m12.40s.png.
    static func save(video: URL, at time: CMTime, session: URL) async throws -> URL {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (image, actual) = try await gen.image(at: time)
        let dir = session.appending(path: "stills")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secs = max(0, actual.seconds.isFinite ? actual.seconds : time.seconds)
        let stamp = String(format: "%02dm%05.2fs", Int(secs) / 60, secs.truncatingRemainder(dividingBy: 60))
        let name = "\(video.deletingPathExtension().lastPathComponent)-\(stamp).png"
        let target = AssetStore.free(dir.appending(path: name))
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RecorderError("Could not write \(name).") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RecorderError("Could not write \(name).") }
        return target
    }
}

// MARK: - Thumbnails

@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, NSImage>()
    private var durations: [String: Double] = [:]

    private func key(_ a: Asset) -> String { "\(a.url.path)|\(a.modified.timeIntervalSince1970)" }

    func cached(_ a: Asset) -> NSImage? { cache.object(forKey: key(a) as NSString) }
    func cachedDuration(_ a: Asset) -> Double? { durations[key(a)] }

    func image(_ a: Asset) async -> NSImage? {
        if let hit = cached(a) { return hit }
        if a.kind == .video, let frame = await Self.frame(a.url) {
            cache.setObject(frame, forKey: key(a) as NSString)
            return frame
        }
        let req = QLThumbnailGenerator.Request(fileAt: a.url, size: CGSize(width: 480, height: 600),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache.setObject(rep.nsImage, forKey: key(a) as NSString)
        return rep.nsImage
    }

    /// A frame a little way in: edits often open on a plain title card.
    private static func frame(_ url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let secs = (try? await asset.load(.duration).seconds) ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        let at = CMTime(seconds: secs.isFinite && secs > 0 ? min(3, secs * 0.2) : 0, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func duration(_ a: Asset) async -> Double? {
        if let d = durations[key(a)] { return d }
        guard let d = try? await AVURLAsset(url: a.url).load(.duration), d.isNumeric else { return nil }
        durations[key(a)] = d.seconds
        return d.seconds
    }
}

// MARK: - Views

struct AssetsPane: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    /// The whole window (nothing open), or the column beside the stage.
    var wide = false
    @StateObject private var store = AssetStore()
    @StateObject private var comments = CommentStore()
    /// The b-roll library's folders, for "Save to B-roll".
    @State private var brollFolders: [String] = []
    @State private var dropping = false
    /// Files you picked: ⌘- or ⇧-click adds or removes one; drag a box on the empty space around
    /// the tiles to pick what it touches.
    @State private var picked: Set<URL> = []
    @State private var anchor: URL?
    @State private var band: (start: CGPoint, end: CGPoint)?
    @State private var bandBase: Set<URL> = []
    /// Every tile's frame, for the rubber band. A box, not state: tiles report frames on every
    /// layout, and state would redraw the whole grid each time.
    @State private var frames = TileFrameBox()
    /// The file each post shows, and the file he picked for it (else it is the newest edit). Each
    /// platform has its own: one video on LinkedIn, another on X.
    @State private var postMedia: [PostPlatform: URL] = [:]
    @State private var postPick: [PostPlatform: String] = [:]
    /// The thumbnail the post's video starts with (Cover.swift).
    /// Thumbnails a post uses as its cover (Post tab > Cover).
    @State private var coverRels: Set<String> = []

    var body: some View {
        let _ = Perf.body("AssetsPane")
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 30 : 22) {
                    StyleChip(doc: doc, showLink: true)
                    if store.assets.isEmpty {
                        empty
                    } else {
                        ForEach(store.groups, id: \.name) { g in
                            section(g.name, g.assets)
                        }
                    }
                }
                .padding(.horizontal, wide ? 28 : 16).padding(.vertical, wide ? 24 : 16)
                .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                .background { bandSurface }
                .overlay(alignment: .topLeading) { bandBox }
                .coordinateSpace(name: "assets")
                .onPreferenceChange(TileFrames.self) { frames.frames = $0 }
            }
            Rule()
            footer
        }
        .background(wide ? Theme.canvas : Theme.paper)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.accentSoft.opacity(0.5))
                    .overlay(Text("Drop to copy into assets/").font(Theme.sans(13, .medium)).foregroundStyle(Theme.accentInk))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                store.add(urls)
                store.scan(doc)
            }
            return true
        }
        .onAppear {
            store.open(doc); comments.load(doc.url); readPost()
            brollFolders = BrollLib.folderNames(BrollLib.dir(root: app.library.root))
        }
        .onChange(of: doc.url) { picked = []; anchor = nil; store.open(doc); comments.load(doc.url); readPost() }
        .onChange(of: store.assets) { _, now in
            let live = Set(now.map(\.url))
            if !picked.isSubset(of: live) { picked.formIntersection(live) }
        }
        .onChange(of: app.stillsSaved) { store.scan(doc) }
        .onFilesChanged(in: doc.url) {
            if !app.isRecording { store.refresh(doc); comments.load(doc.url); readPost() }
        }
    }

    private func readPost() {
        var shows: [PostPlatform: URL] = [:], picks: [PostPlatform: String] = [:], covers: Set<String> = []
        for p in PostPlatform.allCases {
            let c = PostFile.read(doc.url, p)
            if let cover = c?.meta["cover"] { covers.insert(cover) }
            // A platform with no post yet shows nothing; LinkedIn is the post by default.
            guard p == .linkedin || c != nil else { continue }
            picks[p] = c?.media
            shows[p] = PostFile.media(c, in: doc.url, p)?.standardizedFileURL
        }
        if picks != postPick { postPick = picks }
        if covers != coverRels { coverRels = covers }
        if shows != postMedia { postMedia = shows }
    }

    /// The posts that show this file, in platform order.
    private func posts(showing a: Asset) -> [PostPlatform] {
        let path = a.url.standardizedFileURL
        return PostPlatform.allCases.filter { postMedia[$0] == path }
    }

    /// Puts a video or image on one platform's post, or takes it off (that post shows the newest
    /// edit again; X shows LinkedIn's pick).
    private func pin(_ a: Asset, _ p: PostPlatform) {
        PostFile.pickMedia(postPick[p] == a.rel ? nil : a.rel, in: doc.url, p)
        readPost()
    }

    private var empty: some View { AssetsEmpty() }

    /// "4 videos", "2 images", else "3 files".
    private func count(_ items: [Asset]) -> String {
        let kinds = Set(items.map(\.kind))
        let n = items.count
        let noun: String
        switch kinds.count == 1 ? kinds.first : nil {
        case .video: noun = n == 1 ? "video" : "videos"
        case .image: noun = n == 1 ? "image" : "images"
        case .audio: noun = n == 1 ? "sound" : "sounds"
        default: noun = n == 1 ? "file" : "files"
        }
        return "\(n) \(noun)"
    }

    private func section(_ name: String, _ items: [Asset]) -> some View {
        // Once per section, not once per tile.
        let open = Dictionary(grouping: comments.all.filter(\.open), by: \.file).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                let title = name.isEmpty ? "Session folder" : name.prefix(1).uppercased() + name.dropFirst()
                Text(title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.muted)
                Spacer()
                Text(count(items)).font(Theme.sans(12)).foregroundStyle(Theme.faint)
                Button { reveal(name.isEmpty || name == "takes" ? doc.url : doc.url.appending(path: name)) } label: {
                    Image(systemName: "folder").font(.system(size: 11)).frame(width: 22, height: 22)
                }
                .buttonStyle(IconButtonStyle())
                .help("Show this folder in Finder")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 160 : 130, maximum: 260), spacing: wide ? 18 : 12)],
                      alignment: .leading, spacing: wide ? 22 : 16) {
                ForEach(items) { a in
                    AssetTile(asset: a, selected: app.preview == a.url, picked: picked.contains(a.url) && picked.count > 1,
                              openComments: open[a.rel] ?? 0,
                              inPost: posts(showing: a),
                              pinned: PostPlatform.allCases.filter { postPick[$0] == a.rel },
                              isCover: coverRels.contains(a.rel),
                              onPin: a.kind == .video || a.kind == .image ? { pin(a, $0) } : nil)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TileFrames.self, value: [a.url: g.frame(in: .named("assets"))])
                        })
                        // Act on the first click. A plain onTapGesture next to a double-tap waits out the
                        // double-click interval (~0.4 s) first. The second click of a double is skipped.
                        .gesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.openSoon(a.url) })
                        .simultaneousGesture(TapGesture().onEnded { if NSApp.firstClick { click(a) } })
                        .onDrag { NSItemProvider(contentsOf: a.url) ?? NSItemProvider() }
                        .contextMenu {
                            if picked.count > 1 && picked.contains(a.url) { bulkMenu } else { menu(a) }
                        }
                }
            }
        }
    }

    private func draft(_ text: String) {
        app.chats.chat(doc.url).draft = text
        app.chats.open = true
    }

    @ViewBuilder private func menu(_ a: Asset) -> some View {
        if a.kind == .video || a.kind == .image || a.kind == .audio {
            Button("Show in Player") { app.preview = a.url }
        }
        if a.kind == .video || a.kind == .image {
            Menu("Use in Post") {
                ForEach(PostPlatform.shown) { p in
                    Toggle("\(p.name) post", isOn: Binding(get: { postPick[p] == a.rel }, set: { _ in pin(a, p) }))
                }
            }
        }
        if a.kind == .video || a.kind == .image {
            // Puts the ask in the chat box; the user types what to change (2026-10-06).
            // Images go to GPT Image directly, videos to Higgsfield.
            Button(a.kind == .video ? "Change with Higgsfield…" : "Change Image…") {
                let chat = app.chats.chat(doc.url)
                chat.draft = a.kind == .video ? Higgsfield.changeDraft(a.rel) : Higgsfield.imageDraft(a.rel)
                app.chats.open = true
            }
        }
        if a.kind == .video || a.kind == .audio {
            // ElevenLabs (2026-10-06): the ask goes in the chat box, the user finishes it.
            Button("Fix Words…") { draft(ElevenLabs.fixDraft(a.rel)) }
            Button("Change Voice…") { draft(ElevenLabs.voiceDraft(a.rel)) }
        }
        Button("Open") { NSWorkspace.shared.openSoon(a.url) }
        Button("Reveal in Finder") { reveal(a.url) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.url.path, forType: .string)
        }
        if a.kind == .video { saveMenu([a.url]) }
        Divider()
        if a.take, let t = doc.meta.takes.first(where: { $0.file == a.name }) {
            // Through the session, so session.json drops it too (camera and screen go together).
            Button("Move Take \(t.number) to Trash", role: .destructive) {
                if doc.meta.takes.contains(where: { $0.number == t.number && doc.fileURL($0) == app.preview }) {
                    app.preview = nil
                }
                doc.trashTake(t.number)
                store.scan(doc)
            }
            .disabled(app.isRecording)
        } else {
            Button("Move to Trash", role: .destructive) {
                if app.preview == a.url { app.preview = nil }
                try? FileManager.default.trashItem(at: a.url, resultingItemURL: nil)
                store.scan(doc)
            }
        }
    }

    // MARK: B-roll library

    /// Saves videos into a b-roll folder (an APFS clone). Gemini then describes and names each one.
    @ViewBuilder private func saveMenu(_ urls: [URL]) -> some View {
        Divider()
        Menu(urls.count == 1 ? "Save to B-roll" : "Save \(urls.count) to B-roll") {
            ForEach(brollFolders, id: \.self) { f in
                Button(BrollFolder.title(f)) { saveBroll(urls, to: f) }
            }
            if brollFolders.isEmpty { Button("Clips") { saveBroll(urls, to: "Clips") } }
        }
    }

    private func saveBroll(_ urls: [URL], to folder: String) {
        for u in urls { _ = Voice.launch(["--broll-save", u.path, folder]) }
        let n = urls.count
        app.show(toast: "Saving \(n == 1 ? "it" : "\(n) clips") to B-roll · \(BrollFolder.title(folder)). Gemini names it in about a minute")
    }

    // MARK: Picking several

    /// Every file in screen order.
    private var ordered: [Asset] { store.groups.flatMap(\.assets) }
    private var pickedAssets: [Asset] { ordered.filter { picked.contains($0.url) } }

    private func click(_ a: Asset) {
        Perf.mark("asset \(a.kind)")
        let mods = NSEvent.modifierFlags
        let adding = mods.contains(.command) || mods.contains(.shift)
        picked = AssetPick.click(a.url, picked: picked, anchor: anchor,
                                 command: mods.contains(.command), shift: mods.contains(.shift))
        anchor = a.url
        if !adding { show(a) }
    }

    /// The empty space behind the tiles: click to drop the picks, drag to pick with a box.
    private var bandSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { picked = []; anchor = nil }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("assets"))
                .onChanged { g in
                    if band == nil {
                        let mods = NSEvent.modifierFlags
                        bandBase = mods.contains(.command) || mods.contains(.shift) ? picked : []
                    }
                    band = (g.startLocation, g.location)
                    let box = AssetPick.box(g.startLocation, g.location)
                    picked = AssetPick.band(box, frames: frames.frames, base: bandBase)
                }
                .onEnded { _ in
                    band = nil
                    anchor = pickedAssets.first?.url
                })
    }

    @ViewBuilder private var bandBox: some View {
        if let band {
            let r = AssetPick.box(band.start, band.end)
            Rectangle().fill(Theme.accent.opacity(0.1))
                .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var bulkMenu: some View {
        let n = picked.count
        Button("Reveal \(n) in Finder") { NSWorkspace.shared.revealSoon(pickedAssets.map(\.url)) }
        Button("Copy \(n) Paths") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pickedAssets.map(\.url.path).joined(separator: "\n"), forType: .string)
        }
        let media = pickedAssets.filter { $0.kind == .video }.map(\.url)
        if !media.isEmpty {
            saveMenu(media)
        }
                Button("Select All") { picked = Set(ordered.map(\.url)) }
        Button("Deselect All") { picked = []; anchor = nil }
        Divider()
        Button("Move \(n) to Trash", role: .destructive) { trashPicked() }
            .disabled(app.isRecording && pickedAssets.contains(where: \.take))
    }

    /// Takes go through the session, so session.json drops them too (camera and screen together).
    private func trashPicked() {
        let items = pickedAssets
        if let p = app.preview, picked.contains(p) { app.preview = nil }
        let takeNumbers = Set(items.filter(\.take).compactMap { a in doc.meta.takes.first { $0.file == a.name }?.number })
        if !takeNumbers.isEmpty, !app.isRecording {
            if doc.meta.takes.contains(where: { takeNumbers.contains($0.number) && doc.fileURL($0) == app.preview }) {
                app.preview = nil
            }
            for n in takeNumbers.sorted() { doc.trashTake(n) }
        }
        for a in items where !a.take {
            try? FileManager.default.trashItem(at: a.url, resultingItemURL: nil)
        }
        app.show(toast: "Moved \(items.count) file\(items.count == 1 ? "" : "s") to the Trash")
        picked = []
        anchor = nil
        store.scan(doc)
    }

    /// Videos, images and audio play in the left pane. Other files open in their app.
    private func show(_ a: Asset) {
        switch a.kind {
        case .video, .image, .audio: app.preview = a.url
        case .other: if DocReview.handles(a.url) { app.preview = a.url } else { NSWorkspace.shared.openSoon(a.url) }
        }
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.revealSoon([url]) }
    }

    @ViewBuilder private var footer: some View {
        if picked.count > 1 { bulkFooter } else { plainFooter }
    }

    private var bulkFooter: some View {
        HStack(spacing: 10) {
            let total = pickedAssets.reduce(Int64(0)) { $0 + $1.size }
            Text("\(picked.count) selected · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                .font(Theme.sans(12, .medium)).foregroundStyle(Theme.accentInk)
            Spacer()
            Button("Reveal") { NSWorkspace.shared.revealSoon(pickedAssets.map(\.url)) }
                .buttonStyle(BracketButtonStyle(active: false))
                .help("Show the selected files in Finder")
            Button("Trash") { trashPicked() }
                .buttonStyle(BracketButtonStyle(active: false))
                .disabled(app.isRecording && pickedAssets.contains(where: \.take))
                .help("Move the selected files to the Trash (takes leave the take list too)")
            Button("Done") { picked = []; anchor = nil }
                .buttonStyle(BracketButtonStyle(active: true))
                .help("Deselect all")
        }
        .padding(.horizontal, wide ? 22 : 10).padding(.vertical, 8)
        .background(Theme.accentSoft)
        .tint(Theme.ink)
    }

    private var plainFooter: some View {
        HStack(spacing: 10) {
            let total = store.assets.reduce(Int64(0)) { $0 + $1.size }
            Text("\(store.assets.count) file\(store.assets.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                .font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            Spacer()
            Text("⌘-click or drag a box to pick several")
                .font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1)
                .help("Click to view · double-click to open · ⌘- or ⇧-click, or drag a box on the empty space, to pick several · drag out to use")
            Button("Clean up") { app.cleaningUp = true }
                .buttonStyle(BracketButtonStyle(active: false))
                .fixedSize()
                .disabled(app.isRecording || store.assets.isEmpty)
                .help("Pick what to keep and move the rest to the Trash (after you posted the video)")
            Button { reveal(doc.url) } label: { Image(systemName: "folder").frame(width: 24, height: 24) }
                .buttonStyle(IconButtonStyle())
                .help("Open the session folder in Finder")
        }
        .padding(.horizontal, wide ? 22 : 10).padding(.vertical, 6)
        .background(wide ? Theme.canvas : Theme.surface)
        .tint(Theme.ink)
    }
}

/// Where each tile sits, for picking with a box.
struct TileFrames: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Picking several files, as plain decisions so tests can pin them down.
enum AssetPick {
    /// ⌘- or ⇧-click adds or removes one file, as in Finder's icon view. A plain click picks only
    /// that file. The file you clicked before (`anchor`) counts as picked.
    static func click(_ url: URL, picked: Set<URL>, anchor: URL?, command: Bool, shift: Bool) -> Set<URL> {
        guard command || shift else { return [url] }
        var next = picked
        if next.isEmpty, let anchor, anchor != url { next.insert(anchor) }
        if next.contains(url) { next.remove(url) } else { next.insert(url) }
        return next
    }

    static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The tiles the box touches, on top of what was picked before (⌘ or ⇧ held at the start).
    static func band(_ box: CGRect, frames: [URL: CGRect], base: Set<URL>) -> Set<URL> {
        base.union(frames.filter { $0.value.intersects(box) }.map(\.key))
    }
}

struct AssetTile: View {
    let asset: Asset
    let selected: Bool
    var picked = false
    var openComments = 0
    /// The posts that show this file. `pinned`: the ones he picked it for; else it is the newest edit.
    var inPost: [PostPlatform] = []
    var pinned: [PostPlatform] = []
    /// The post's video starts with this thumbnail.
    var isCover = false
    var onPin: ((PostPlatform) -> Void)?
    // From the cache at once: a tab that opens again shows its pictures in the first frame,
    // not icons that turn into pictures.
    @State private var image: NSImage?
    @State private var duration: Double?
    @State private var hover = false
    /// The AI model that made it (generated/), in small grey type.
    @State private var model: String?

    init(asset: Asset, selected: Bool, picked: Bool = false, openComments: Int = 0, inPost: [PostPlatform] = [],
         pinned: [PostPlatform] = [], isCover: Bool = false,
         onPin: ((PostPlatform) -> Void)? = nil) {
        self.asset = asset; self.selected = selected; self.picked = picked; self.openComments = openComments
        self.inPost = inPost; self.pinned = pinned; self.isCover = isCover; self.onPin = onPin
        _image = State(initialValue: Thumbs.shared.cached(asset))
        _duration = State(initialValue: Thumbs.shared.cachedDuration(asset))
    }

    /// "On post" for LinkedIn alone, else the platforms: "On X", "On LinkedIn, X".
    private var onPostLabel: String { inPost == [.linkedin] ? "On post" : "On \(Self.names(inPost))" }

    static func names(_ ps: [PostPlatform]) -> String { ps.map(\.name).joined(separator: ", ") }

    /// Portrait images fill the tile; wide ones sit whole on the dark stage.
    private var portrait: Bool { image.map { $0.size.height > $0.size.width } ?? false }

    var body: some View {
        let _ = Perf.body("AssetTile")
        VStack(alignment: .leading, spacing: 8) {
            HoverVideo(poster: image, video: asset.kind == .video ? asset.url : nil, hover: hover,
                       fit: asset.kind != .video && !portrait, icon: icon, ringed: selected || picked)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) {
                if let duration, duration > 0 {
                    Text(SessionDoc.clock(duration))
                        .font(Theme.sans(10.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if openComments > 0 {
                        Label("\(openComments)", systemImage: "text.bubble.fill")
                            .help("\(openComments) open comment\(openComments == 1 ? "" : "s") for Takes")
                    }
                    if !inPost.isEmpty { Text(onPostLabel) }
                    if isCover { Text("Cover") }
                }
                .font(Theme.sans(10.5, .bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
                .opacity(openComments > 0 || !inPost.isEmpty || isCover ? 1 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                if let onPin, hover || !pinned.isEmpty {
                    Menu {
                        Section("Show on") {
                            ForEach(PostPlatform.shown) { p in
                                Toggle("\(p.name) post", isOn: Binding(get: { pinned.contains(p) }, set: { _ in onPin(p) }))
                            }
                        }
                    } label: {
                        Image(systemName: pinned.isEmpty ? "star" : "star.fill").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(pinned.isEmpty ? .white : Theme.accent)
                            .frame(width: 26, height: 26)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(8)
                    .transition(.opacity)
                    .help(pinned.isEmpty ? "Pick the posts that show this: LinkedIn, X, YouTube or Vertical"
                          : "Shows on the \(Self.names(pinned)) post. Click to change")
                }
            }
            .overlay(alignment: .topLeading) {
                if picked {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                        .foregroundStyle(.white, Theme.accent)
                        .padding(7)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fileTitle).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let model {
                    Text(model).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1)
                        .layoutPriority(-1)
                }
                if let badge { Text(badge).font(Theme.mono(12)).foregroundStyle(Theme.faint).fixedSize() }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help("\(asset.url.path)\n\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file)) · \(SessionList.when(asset.modified))\(model.map { "\nMade with \($0)" } ?? "")")
        .task(id: asset) {
            model = asset.group == "generated" ? MadeWith.label(for: asset.url) : nil
            if let hit = Thumbs.shared.cached(asset) {
                if image !== hit { image = hit }
                if asset.kind == .video || asset.kind == .audio { duration = await Thumbs.shared.duration(asset) }
                return
            }
            // A video Claude still renders changes every second for minutes: each change made a new
            // picture of the half-written file. Wait until it rests 3 s (2026-10-03).
            let rest = 3 - Date().timeIntervalSince(asset.modified)
            if rest > 0, asset.kind != .image {
                try? await Task.sleep(for: .seconds(rest))
                if Task.isCancelled { return }
            }
            image = await Thumbs.shared.image(asset)
            if asset.kind == .video || asset.kind == .audio { duration = await Thumbs.shared.duration(asset) }
        }
    }

    /// The file name without its extension (the badge says what it is).
    private var fileTitle: String { (asset.name as NSString).deletingPathExtension }

    private var icon: String {
        switch asset.kind {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }

    /// Videos show their length on the frame; other files say what they are.
    private var badge: String? {
        if duration != nil { return nil }
        let ext = asset.url.pathExtension.uppercased()
        return ext.isEmpty ? nil : ext
    }
}

/// A still, shown in the left pane like a video.
struct StillView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

final class TileFrameBox {
    var frames: [URL: CGRect] = [:]
}

/// No files yet: the four folders as tiles, each saying what lands in it (2026-10-04).
struct AssetsEmpty: View {
    @State private var shown = false

    private var folders: [(name: String, icon: String, text: String, tint: Color)] {
        [("edits", "film.stack", "Cut and edited versions from Takes.", Theme.accent),
         ("thumbnails", "photo.on.rectangle.angled", "Covers for the post, from Takes.", Color(red: 0.55, green: 0.38, blue: 0.95)),
         ("stills", "camera.viewfinder", "Pause a video and press S to keep a frame.", Theme.warn),
         ("assets", "tray.and.arrow.down", "Drop any file on this page.", Theme.live)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing here yet").font(Theme.display(34)).foregroundStyle(Theme.ink)
                Text("What you and Takes make for this video lands here, sorted by folder.")
                    .font(Theme.sans(14)).foregroundStyle(Theme.muted)
            }
            .arrive(shown)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                ForEach(Array(folders.enumerated()), id: \.offset) { i, f in
                    FolderTile(name: f.name, icon: f.icon, text: f.text, tint: f.tint, drop: f.name == "assets")
                        .arrive(shown, i + 1)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .padding(.top, 8)
        .onAppear { shown = true }
    }
}

private struct FolderTile: View {
    let name: String
    let icon: String
    let text: String
    let tint: Color
    /// The folder you drop into: drawn as a dashed drop zone.
    let drop: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(hover ? 1.06 : 1)
                .rotationEffect(.degrees(hover ? -4 : 0))
            HStack(spacing: 0) {
                Text(name).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
                Text("/").font(Theme.sans(14)).foregroundStyle(Theme.faint)
            }
            .padding(.top, 34)
            Text(text).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(18)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if drop {
                shape.fill(Theme.paper.opacity(hover ? 1 : 0.55))
                    .overlay(shape.strokeBorder(hover ? tint.opacity(0.7) : Theme.border,
                                                style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            } else {
                shape.fill(Theme.paper)
                    .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
                    .shadow(color: Theme.shadow.opacity(hover ? 1.6 : 0.8), radius: hover ? 16 : 8, y: hover ? 8 : 3)
            }
        }
        .offset(y: hover ? -2 : 0)
        .onHover { hover = $0 }
        .animation(Theme.spring, value: hover)
    }
}
