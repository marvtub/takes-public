import AppKit
import AVFoundation
import AVKit
import SwiftUI

// The user's own b-roll, shared by every session (2026-10-03):
//
//   <root>/_library/broll/<N Folder>/<YYYY-MM Shot name (V|H)>.mov
//   <root>/_library/broll/<N Folder>/.reel.mp4    1 s of each clip, played on hover (made here)
//   <root>/_library/broll/<N Folder>/.reel.txt    the clips the reel was made from
//
// The number in front of a folder only sets the order. Each clip carries its description and
// keywords in its own metadata (title, description, keywords), written when Gemini sorted the
// clips; the MCP's list_broll reads the same tags. "Add to session" puts an APFS clone in
// <session>/broll/, so it shows on the Assets tab and costs no disk space.

struct BrollClip: Identifiable, Hashable {
    let url: URL
    let folder: String
    var id: URL { url }

    /// "2023-11 High-Angle Typing at Desk (V)" → "High-Angle Typing at Desk".
    var title: String {
        var s = url.deletingPathExtension().lastPathComponent
        if let r = s.range(of: #"^\d{4}-\d{2} "#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #" \((V|H)\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    var month: String? {
        let s = url.lastPathComponent
        return s.range(of: #"^\d{4}-\d{2}"#, options: .regularExpression).map { String(s[$0]) }
    }

    var vertical: Bool? {
        let s = url.deletingPathExtension().lastPathComponent
        if s.hasSuffix("(V)") { return true }
        if s.hasSuffix("(H)") { return false }
        return nil
    }
}

struct BrollFolder: Identifiable, Hashable {
    let url: URL
    let clips: [BrollClip]
    var id: URL { url }
    /// "1 Desk work" → "Desk work".
    var name: String { Self.title(url.lastPathComponent) }

    static func title(_ folder: String) -> String {
        folder.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
    }
}

struct BrollInfo: Hashable {
    var duration: Double = 0
    var description: String?
    var keywords: String?
}

enum BrollLib {
    static let exts: Set<String> = ["mov", "mp4", "m4v"]

    static func dir(root: URL) -> URL { StyleLib.user(root: root).appending(path: "broll") }

    static func sessionDir(_ session: URL) -> URL { session.appending(path: "broll") }

    /// The library's folders ("1 Desk work"), in tab order.
    static func folderNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// One entry per subfolder, in name order; loose clips go in a folder named after the library.
    static func scan(_ dir: URL) -> [BrollFolder] {
        let fm = FileManager.default
        guard let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        func clips(_ d: URL) -> [BrollClip] {
            ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
                .map { BrollClip(url: $0, folder: d.lastPathComponent) }
                .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedDescending }
        }
        return subs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { BrollFolder(url: $0, clips: clips($0)) }
            .filter { !$0.clips.isEmpty }
    }

    // MARK: Info and frames

    @MainActor private static var infos: [URL: BrollInfo] = [:]
    @MainActor private static var posters: [URL: NSImage] = [:]

    @MainActor static func cachedPoster(_ url: URL) -> NSImage? { posters[url] }
    @MainActor static func cachedInfo(_ url: URL) -> BrollInfo? { infos[url] }

    @MainActor static func info(_ url: URL) async -> BrollInfo {
        if let hit = infos[url] { return hit }
        let asset = AVURLAsset(url: url)
        var out = BrollInfo()
        out.duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        for item in (try? await asset.load(.metadata)) ?? [] {
            let key = (item.key as? String)?.lowercased() ?? item.commonKey?.rawValue.lowercased()
            guard let key, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            if key == "description" || (key == "comment" && out.description == nil) { out.description = value }
            if key == "keywords" { out.keywords = value }
        }
        infos[url] = out
        return out
    }

    /// A frame a third of the way in, at most 480 px.
    @MainActor static func poster(_ url: URL) async -> NSImage? {
        if let hit = posters[url] { return hit }
        let asset = AVURLAsset(url: url)
        let secs = (try? await asset.load(.duration).seconds) ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let at = CMTime(seconds: secs.isFinite && secs > 0 ? secs / 3 : 0, preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        posters[url] = img
        return img
    }

    // MARK: Reels

    static let reelSize = (w: 360, h: 450)
    static let reelSeconds = 0.8
    static let reelMax = 16

    static func reel(_ folder: URL) -> URL { folder.appending(path: ".reel.mp4") }

    /// What the reel is made of: the clip names and their dates. A new, renamed or removed clip
    /// makes a new reel.
    static func reelKey(_ f: BrollFolder) -> String {
        f.clips.prefix(reelMax).map { c in
            let d = (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return "\(c.url.lastPathComponent)|\(Int(d.timeIntervalSince1970))"
        }.joined(separator: "\n")
    }

    static func reelIsFresh(_ f: BrollFolder) -> Bool {
        let key = f.url.appending(path: ".reel.txt")
        return FileManager.default.fileExists(atPath: reel(f.url).path)
            && (try? String(contentsOf: key, encoding: .utf8)) == reelKey(f)
    }

    /// One reel at a time: each decodes up to 16 clips, some 4K.
    private static let reels = ReelQueue()

    static func makeReel(_ f: BrollFolder) async -> URL? {
        if reelIsFresh(f) { return reel(f.url) }
        return await reels.run { await build(f) }
    }

    private static func build(_ f: BrollFolder) async -> URL? {
        if reelIsFresh(f) { return reel(f.url) }
        let clips = Array(f.clips.prefix(reelMax))
        var args = ["-v", "error", "-y"]
        var chains: [String] = []
        for (i, c) in clips.enumerated() {
            let d = (try? await AVURLAsset(url: c.url).load(.duration).seconds) ?? 0
            let start = d.isFinite && d > reelSeconds * 2 ? d * 0.35 : 0
            args += ["-ss", String(format: "%.2f", start), "-t", String(reelSeconds), "-i", c.url.path]
            chains.append("[\(i):v]scale=\(reelSize.w):\(reelSize.h):force_original_aspect_ratio=increase,"
                          + "crop=\(reelSize.w):\(reelSize.h),setsar=1,fps=30,format=yuv420p[v\(i)]")
        }
        let joined = (0..<clips.count).map { "[v\($0)]" }.joined()
        let tmp = f.url.appending(path: ".reel-tmp.mp4")
        args += ["-filter_complex", chains.joined(separator: ";") + ";\(joined)concat=n=\(clips.count):v=1:a=0[out]",
                 "-map", "[out]", "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
                 "-movflags", "+faststart", tmp.path]
        do {
            try await Cover.ffmpeg(args)
            let fm = FileManager.default
            try? fm.removeItem(at: reel(f.url))
            try fm.moveItem(at: tmp, to: reel(f.url))
            try reelKey(f).write(to: f.url.appending(path: ".reel.txt"), atomically: true, encoding: .utf8)
            return reel(f.url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSLog("B-roll reel for \(f.name) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Sessions

    /// Clones the clip into <session>/broll/ (APFS: no extra space). Returns the new file.
    @discardableResult
    static func add(_ clip: BrollClip, to session: URL) throws -> URL {
        let dir = sessionDir(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let have = inSession(clip, session) { return have }
        let target = AssetStore.free(dir.appending(path: clip.url.lastPathComponent))
        try FileManager.default.copyItem(at: clip.url, to: target)
        return target
    }

    /// Takes the clip out of the session: its copy in <session>/broll/ goes to the Trash.
    static func remove(_ clip: BrollClip, from session: URL) throws {
        guard let have = inSession(clip, session) else { return }
        try FileManager.default.trashItem(at: have, resultingItemURL: nil)
    }

    static func inSession(_ clip: BrollClip, _ session: URL) -> URL? {
        let u = sessionDir(session).appending(path: clip.url.lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

/// Runs one job at a time, in order.
actor ReelQueue {
    private var tail: Task<Void, Never>?
    func run<T: Sendable>(_ job: @escaping @Sendable () async -> T) async -> T {
        let prev = tail
        let task = Task { () -> T in
            await prev?.value
            return await job()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

// MARK: - Views

struct BrollPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var shown
    var doc: SessionDoc
    @State private var folders: [BrollFolder] = []
    @State private var open: URL?
    @State private var playing: BrollClip?
    /// The hovered tile draws over its neighbours.
    @State private var front: URL?
    @State private var inSession: Set<String> = []

    private var dir: URL { BrollLib.dir(root: app.library.root) }

    var body: some View {
        let _ = Perf.body("BrollPane")
        VStack(alignment: .leading, spacing: 0) {
            header
            if folders.isEmpty {
                empty
            } else if let open, let f = folders.first(where: { $0.url == open }) {
                clips(f)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let playing {
                BrollPlayer(clip: playing, added: inSession.contains(playing.url.lastPathComponent),
                            add: { add(playing) }, remove: { remove(playing) },
                            trash: { trash(playing) }, close: { self.playing = nil })
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion, value: playing)
        .task(id: doc.url) { scan() }
        .onFilesChanged(in: dir) { scan() }
        .onFilesChanged(in: BrollLib.sessionDir(doc.url)) { scanSession() }
        .onChange(of: shown) { _, on in if !on { playing = nil } }
    }

    private func scan() {
        folders = BrollLib.scan(dir)
        if let o = open, !folders.contains(where: { $0.url == o }) { open = nil }
        scanSession()
    }

    private func scanSession() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: BrollLib.sessionDir(doc.url).path)) ?? []
        inSession = Set(names)
    }

    private func add(_ c: BrollClip) {
        do {
            try BrollLib.add(c, to: doc.url)
            scanSession()
            app.show(toast: "Added to this session's broll/")
        } catch {
            app.show(toast: "Could not add it: \(error.localizedDescription)")
        }
    }

    private func remove(_ c: BrollClip) {
        do {
            try BrollLib.remove(c, from: doc.url)
            scanSession()
            app.show(toast: "Removed from this session")
        } catch {
            app.show(toast: "Could not remove it: \(error.localizedDescription)")
        }
    }

    /// Out of the library, into the Trash (recoverable). The session copies stay.
    private func trash(_ c: BrollClip) {
        if playing == c { playing = nil }
        do {
            try FileManager.default.trashItem(at: c.url, resultingItemURL: nil)
            app.show(toast: "\(c.title) moved to the Trash")
        } catch {
            app.show(toast: "Could not move it to the Trash: \(error.localizedDescription)")
        }
        scan()
    }

    private func trash(_ f: BrollFolder) {
        do {
            try FileManager.default.trashItem(at: f.url, resultingItemURL: nil)
            app.show(toast: "\(f.name) moved to the Trash")
        } catch {
            app.show(toast: "Could not move it to the Trash: \(error.localizedDescription)")
        }
        scan()
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let open, let f = folders.first(where: { $0.url == open }) {
                Button { self.open = nil } label: {
                    Label("All folders", systemImage: "chevron.left").font(Theme.sans(13, .medium))
                }
                .buttonStyle(BracketButtonStyle())
                Text(f.name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text("·").foregroundStyle(Theme.faint)
                Text("\(f.clips.count) clips").font(Theme.sans(13)).foregroundStyle(Theme.muted)
            } else {
                Text("B-roll").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text("·").foregroundStyle(Theme.faint)
                let n = folders.reduce(0) { $0 + $1.clips.count }
                Text("\(n) clips in \(folders.count) folders").font(Theme.sans(13)).foregroundStyle(Theme.muted)
            }
            if !inSession.isEmpty {
                Text("·").foregroundStyle(Theme.faint)
                Text("\(inSession.count) in this session").font(Theme.sans(13)).foregroundStyle(Theme.live)
            }
            Spacer()
            Button { NSWorkspace.shared.open(open ?? dir) } label: {
                Label("Show in Finder", systemImage: "folder").font(Theme.sans(12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            .help("Add or remove clips there; the tab follows")
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20)], spacing: 22) {
                ForEach(folders) { f in
                    BrollFolderTile(folder: f, front: $front, trash: { trash(f) }) { open = f.url }
                        .zIndex(front == f.url ? 1 : 0)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 90)
        }
    }

    private func clips(_ f: BrollFolder) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 20) {
                ForEach(f.clips) { c in
                    BrollClipTile(clip: c, added: inSession.contains(c.url.lastPathComponent), front: $front,
                                  play: { playing = c }, add: { add(c) }, remove: { remove(c) },
                                  trash: { trash(c) })
                        .zIndex(front == c.url ? 1 : 0)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 90)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 30)).foregroundStyle(Theme.faint)
            Text("No b-roll yet").font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
            Text("Put clips in folders under _library/broll/, one folder per kind of shot.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A folder: its first clip's frame; on hover, a reel of all its clips, about a second each.
struct BrollFolderTile: View {
    let folder: BrollFolder
    @Binding var front: URL?
    let trash: () -> Void
    let open: () -> Void
    @State private var hover = false
    @State private var poster: NSImage?
    @State private var reel: URL?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                // The 4:5 box sets the size; the frame and the reel only fill it, whatever their shape.
                Theme.stage
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .overlay {
                        if let poster { Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .overlay {
                        if hover, let reel { LoopingVideo(url: reel) }
                        if hover && reel == nil { ProgressView().controlSize(.small).tint(.white) }
                    }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(hover ? Theme.accent : Theme.border,
                                                                                    lineWidth: hover ? 2 : 1))
                .overlay(alignment: .bottomLeading) {
                    Text("\(folder.clips.count)")
                        .font(Theme.sans(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
                .scaleEffect(hover ? 1.015 : 1)
                Text(folder.name).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0; if $0 { front = folder.url } }
        .animation(Theme.motion, value: hover)
        .help("Hover to see the clips; click to open")
        .contextMenu {
            Button("Open", action: open)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
            Divider()
            Button("Move Folder to Trash", role: .destructive, action: trash)
        }
        .task(id: BrollLib.reelKey(folder)) {
            if let first = folder.clips.first { poster = await BrollLib.poster(first.url) }
            reel = await BrollLib.makeReel(folder)
        }
    }
}

/// A clip: its frame; on hover, the clip plays muted. Click for the big player.
struct BrollClipTile: View {
    let clip: BrollClip
    let added: Bool
    @Binding var front: URL?
    let play: () -> Void
    let add: () -> Void
    let remove: () -> Void
    let trash: () -> Void
    @State private var hover = false
    @State private var poster: NSImage?
    @State private var info: BrollInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HoverVideo(poster: poster, video: clip.url, from: 0.2, hover: hover)
            .overlay(alignment: .topTrailing) {
                Button(action: added ? remove : add) {
                    Image(systemName: added && hover ? "minus" : added ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(added ? Theme.live : .black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hover || added ? 1 : 0)
                .padding(8)
                .help(added ? "In this session's broll/ folder. Click to remove it from the session"
                            : "Add to this session (broll/ folder, no extra disk space)")
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if let v = clip.vertical { Text(v ? "V" : "H") }
                    if let d = info?.duration, d > 0 { Text(Self.clock(d)) }
                }
                .font(Theme.sans(10.5, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: play)
            Text(clip.title).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
            if let d = info?.description {
                Text(d).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(3)
            }
            if let m = clip.month { Text(m).font(Theme.sans(11)).foregroundStyle(Theme.faint) }
        }
        .onHover { hover = $0; if $0 { front = clip.url } }
        .animation(Theme.motion, value: hover)
        .help(info?.description ?? clip.title)
        .contextMenu {
            if added {
                Button("Remove from This Session", action: remove)
            } else {
                Button("Add to This Session", action: add)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clip.url.path, forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive, action: trash)
        }
        .task(id: clip.url) {
            info = BrollLib.cachedInfo(clip.url)
            poster = BrollLib.cachedPoster(clip.url)
            if poster == nil { poster = await BrollLib.poster(clip.url) }
            if info == nil { info = await BrollLib.info(clip.url) }
        }
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// A 4:5 tile: the frame, and on hover the video plays muted, with an accent ring. B-roll clips
/// and the Assets tab use it. Pass no video for a still.
struct HoverVideo: View {
    let poster: NSImage?
    var video: URL?
    var from: Double = 0
    let hover: Bool
    /// Wide stills sit whole on the dark stage; everything else fills the tile.
    var fit = false
    var icon = "film"
    /// Picked or shown in the player: the ring stays.
    var ringed = false

    var body: some View {
        Theme.stage
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                } else {
                    Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .overlay { if hover, let video { LoopingVideo(url: video, from: from) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover || ringed ? Theme.accent : Theme.border,
                                                                      lineWidth: hover || ringed ? 2 : 1))
    }
}

/// The clip big, with sound and controls, its description and the add button.
struct BrollPlayer: View {
    let clip: BrollClip
    let added: Bool
    let add: () -> Void
    let remove: () -> Void
    let trash: () -> Void
    let close: () -> Void
    @State private var info: BrollInfo?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture(perform: close)
            HStack(alignment: .top, spacing: 22) {
                GlassPlayer(url: clip.url).id(clip.url)
                    .aspectRatio(clip.vertical == false ? 16.0 / 9.0 : 9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 12) {
                    Text(clip.title).font(Theme.display(20)).foregroundStyle(Theme.ink)
                    HStack(spacing: 6) {
                        if let m = clip.month { Text(m) }
                        if let v = clip.vertical { Text("·"); Text(v ? "Vertical" : "Horizontal") }
                        if let d = info?.duration, d > 0 { Text("·"); Text(BrollClipTile.clock(d)) }
                    }
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    if let d = info?.description {
                        Text(d).font(Theme.sans(13)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    if let k = info?.keywords {
                        Text(k).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Button(added ? "Remove from session" : "Add to session", action: added ? remove : add)
                            .buttonStyle(AccentButtonStyle(kind: added ? .quiet : .accent))
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                        Spacer(minLength: 0)
                        Button(action: trash) { Image(systemName: "trash") }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                            .help("Move this clip to the Trash (out of the library)")
                    }
                }
                .frame(width: 280)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.paper))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(10)
            }
            .padding(40)
            .frame(maxWidth: 1100, maxHeight: 760)
        }
        .task(id: clip.url) { info = await BrollLib.info(clip.url) }
    }
}

/// A video that loops, from `from` (a share of its length) on. Fills its frame. Muted unless
/// `sound` (the storyboard's speaker button, 2026-10-04).
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var from: Double = 0
    var sound = false

    final class Box: NSView {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var url: URL?
    }

    func makeNSView(context: Context) -> Box {
        let v = Box()
        v.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        layer.masksToBounds = true
        v.layer = layer
        start(v)
        return v
    }

    func updateNSView(_ v: Box, context: Context) {
        if v.url != url { start(v) }
        v.player?.isMuted = !sound
    }

    static func dismantleNSView(_ v: Box, coordinator: ()) {
        // A duration still loading must not start the looper after the hover ended.
        v.url = nil
        v.player?.pause()
        v.looper = nil
        v.player = nil
    }

    private func start(_ v: Box) {
        v.url = url
        let p = AVQueuePlayer()
        p.isMuted = !sound
        let item = AVPlayerItem(url: url)
        let from = from
        if from > 0 {
            Task { @MainActor in
                let d = (try? await AVURLAsset(url: url).load(.duration)) ?? .zero
                guard d.isNumeric, d.seconds > 2, v.url == url else { return }
                let start = CMTime(seconds: d.seconds * from, preferredTimescale: 600)
                v.looper = AVPlayerLooper(player: p, templateItem: item, timeRange: CMTimeRange(start: start, end: d))
                p.play()
            }
        } else {
            v.looper = AVPlayerLooper(player: p, templateItem: item)
            p.play()
        }
        v.player = p
        (v.layer as? AVPlayerLayer)?.player = p
    }
}
