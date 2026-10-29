import AVFoundation
import AppKit
import ImageIO
import SwiftUI

/// The right side of the ⌘K results page (2026-10-27): the picked hit, big. A clip plays its
/// moment without sound, over and over; below it every moment the search found in that file.
/// Each kind has its own look (2026-10-28): clips and stills in their own shape, a script as a
/// page, a session as its files, a project as its sessions.
struct SearchPreview: View {
    let hit: MediaSearch.Hit
    let root: URL
    /// The hits in the same file, the picked one among them.
    let moments: [MediaSearch.Hit]
    let open: (MediaSearch.Hit) -> Void
    @State private var image: NSImage?
    @State private var shape: SearchMedia.Shape?
    @State private var script: String?
    @State private var inside: [MediaSearch.Hit] = []

    private var isVideo: Bool { hit.title == nil && SearchMedia.isVideo(hit.path) }
    private var isImage: Bool { hit.title == nil && SearchMedia.isImage(hit.path) }
    private var isScript: Bool { hit.title == nil && (hit.kind == "script" || hit.path.pathExtension.lowercased() == "md") }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picture(tallest: max(240, geo.size.height * 0.6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.title ?? hit.path.lastPathComponent).font(Theme.sans(17, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(hit.title != nil ? kindLine : SearchRow.place(hit, root: root))
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        if let facts, !facts.isEmpty {
                            Text(facts).font(Theme.sans(12).monospacedDigit()).foregroundStyle(Theme.faint).lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    if hit.title == nil, !moments.isEmpty, !isScript {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(moments.sorted { $0.start < $1.start }) { m in
                                Button { open(m) } label: { moment(m) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if hit.kind == "session" || hit.kind == "project" { contents }
                    Button { open(hit) } label: {
                        HStack(spacing: 8) {
                            Text(openTitle)
                            Text("⏎").opacity(0.6)
                        }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .solid))
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: shape)
                .animation(.easeOut(duration: 0.2), value: inside.count)
            }
        }
        .background(Theme.canvas)
        .task(id: hit.id) { await load() }
    }

    private func load() async {
        image = nil; shape = nil; script = nil; inside = []
        let hit = hit
        if isVideo || isImage {
            shape = await SearchMedia.shape(hit.path)
            if isImage { image = await Task.detached { NSImage(contentsOf: hit.path) }.value }
        } else if isScript {
            script = await Task.detached { try? String(contentsOf: hit.path, encoding: .utf8) }.value
        } else if hit.kind == "session" {
            inside = await Task.detached { SearchMedia.files(in: hit.path) }.value
        } else if hit.kind == "project" {
            inside = await Task.detached { SearchMedia.sessions(in: hit.path) }.value
        }
    }

    // MARK: Picture

    /// A clip or a still in its own shape: a vertical edit stands tall in the middle, a wide one
    /// fills the width. Until the shape is known the box is 16:9.
    @ViewBuilder private func picture(tallest: CGFloat) -> some View {
        if isVideo || isImage {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.hover)
                if isVideo {
                    MomentPlayer(url: hit.path, start: hit.start).id(hit.id)
                        .transition(.opacity)
                } else if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                }
                if isVideo, hit.start > 0 {
                    Text(SearchRow.time(hit.start)).font(Theme.sans(12, .semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7)))
                        .padding(10)
                }
            }
            .aspectRatio(shape?.ratio ?? 16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture { open(hit) }
            .frame(maxWidth: .infinity, maxHeight: tallest)
            .animation(.easeOut(duration: 0.2), value: image != nil)
        } else if isScript {
            page(tallest: tallest)
        } else if hit.title == nil {
            RoundedRectangle(cornerRadius: 12).fill(Theme.hover)
                .overlay(Image(systemName: "film").font(.system(size: 28)).foregroundStyle(Theme.faint))
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: tallest)
        } else if hit.kind == "board" {
            RoundedRectangle(cornerRadius: 12).fill(Theme.hover)
                .overlay(Image(systemName: "square.grid.2x2").font(.system(size: 28)).foregroundStyle(Theme.faint))
                .frame(height: 160)
        }
    }

    /// A script as a sheet of paper. The words that matched are marked.
    private func page(tallest: CGFloat) -> some View {
        ScrollView {
            Text(marked(script ?? hit.text ?? ""))
                .font(Theme.sans(14)).foregroundStyle(Theme.ink).lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
        }
        .frame(height: tallest)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func marked(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        for m in moments + [hit] {
            guard let t = m.text, !t.isEmpty, let r = a.range(of: t, options: .caseInsensitive) else { continue }
            a[r].backgroundColor = Theme.accent.opacity(0.18)
        }
        return a
    }

    // MARK: Session and project

    /// A session's takes, edits and stills, or a project's sessions.
    @ViewBuilder private var contents: some View {
        if hit.kind == "session", !inside.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(inside) { f in
                    Button { open(f) } label: { SearchTile(hit: f) }.buttonStyle(.plain)
                }
            }
            .transition(.opacity)
        } else if hit.kind == "project", !inside.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(inside) { s in
                    Button { open(s) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 18)
                            Text(s.title ?? s.path.lastPathComponent).font(Theme.sans(13)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            if let d = MediaSearch.day(of: s.path) {
                                Text(d.formatted(.dateTime.month(.abbreviated).day())).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                            }
                        }
                        .padding(.horizontal, 8).frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .transition(.opacity)
        }
    }

    /// One found moment: when, and why it matched.
    private func moment(_ m: MediaSearch.Hit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(m.kind == "script" || m.kind == "image" ? "" : SearchRow.time(m.start))
                .font(Theme.sans(12.5, .medium).monospacedDigit()).foregroundStyle(Theme.accentInk)
                .frame(width: 44, alignment: .leading)
            Text(why(m)).font(Theme.sans(13)).foregroundStyle(m.id == hit.id ? Theme.ink : Theme.muted)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(m.id == hit.id ? Theme.hover : .clear))
        .contentShape(Rectangle())
    }

    private func why(_ m: MediaSearch.Hit) -> String {
        if let t = m.text { return "“\(t)”" }
        switch m.kind {
        case "image": return "The still matches"
        case "script": return "In the script"
        default: return "On screen"
        }
    }

    /// "Vertical 9:16 · 1080×1920 · 0:48", "1,240 words", "4 takes · 2 edits", "12 sessions".
    private var facts: String? {
        if let shape {
            return [MediaSearch.shapeLine(width: Int(shape.size.width), height: Int(shape.size.height)),
                    shape.seconds.map(SearchRow.time)].compactMap { $0 }.joined(separator: " · ")
        }
        if let script { return "\(script.split(whereSeparator: \.isWhitespace).count.formatted()) words" }
        if hit.kind == "session", !inside.isEmpty { return SearchMedia.countLine(inside) }
        if hit.kind == "project", !inside.isEmpty { return "\(inside.count) \(inside.count == 1 ? "session" : "sessions")" }
        return nil
    }

    private var kindLine: String {
        switch hit.kind {
        case "session": return hit.text.map { "Session in \($0)" } ?? "Session"
        case "project": return "Project"
        default: return "Board"
        }
    }

    private var openTitle: String {
        if isVideo, hit.start > 0 { return "Open at \(SearchRow.time(hit.start))" }
        switch hit.kind {
        case "session": return "Open session"
        case "project": return "Open project"
        case "board": return "Open board"
        default: return "Open"
        }
    }
}

/// A file in a session's preview: its frame in the file's own shape on a 16:9 tile, and its name.
private struct SearchTile: View {
    let hit: MediaSearch.Hit
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.hover)
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).transition(.opacity)
                } else {
                    Image(systemName: hit.kind == "image" ? "photo" : "film").foregroundStyle(Theme.faint)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(hit.path.lastPathComponent).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: hit.id) {
            let image = await SearchRow.thumbnail(hit)
            withAnimation(.easeOut(duration: 0.2)) { thumb = image }
        }
    }
}

/// What the preview reads from disk: a file's shape, a session's files, a project's sessions.
enum SearchMedia {
    struct Shape: Equatable {
        var size: CGSize
        var seconds: Double?
        var ratio: CGFloat { size.height > 0 ? size.width / size.height : 16 / 9 }
    }

    nonisolated static func isVideo(_ url: URL) -> Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    nonisolated static func isImage(_ url: URL) -> Bool { ["png", "jpg", "jpeg", "heic", "webp"].contains(url.pathExtension.lowercased()) }

    /// The size as it plays (a phone clip shot upright is stored wide and turned), and a clip's length.
    nonisolated static func shape(_ url: URL) async -> Shape? {
        if isImage(url) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let turned = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            return Shape(size: turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h))
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        let seconds = try? await asset.load(.duration).seconds
        return Shape(size: CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded()), seconds: seconds.flatMap { $0.isFinite ? $0 : nil })
    }

    /// A session's takes, then its edits, then its stills: at most 12 of each, newest edit first.
    nonisolated static func files(in session: URL) -> [MediaSearch.Hit] {
        let fm = FileManager.default
        func list(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { isVideo($0) || isImage($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let takes = list(session).filter { $0.lastPathComponent.hasPrefix("take-") && !$0.lastPathComponent.contains("-screen") }
        let edits = list(session.appending(path: "edits")).reversed()
        let stills = list(session.appending(path: "stills"))
        return (takes.prefix(12) + edits.prefix(12) + stills.prefix(12)).map {
            MediaSearch.Hit(path: $0, kind: isImage($0) ? "image" : "video", start: 0)
        }
    }

    /// A project's sessions, newest first.
    nonisolated static func sessions(in project: URL) -> [MediaSearch.Hit] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.compactMap { d -> MediaSearch.Hit? in
            guard let meta = Store.readMeta(d) else { return nil }
            return MediaSearch.Hit(path: d, kind: "session", start: 0, text: project.lastPathComponent, title: meta.title)
        }
        .sorted { $0.path.lastPathComponent > $1.path.lastPathComponent }
    }

    /// "4 takes · 2 edits · 3 stills".
    nonisolated static func countLine(_ files: [MediaSearch.Hit]) -> String {
        let takes = files.filter { $0.path.lastPathComponent.hasPrefix("take-") }.count
        let edits = files.filter { $0.path.deletingLastPathComponent().lastPathComponent == "edits" }.count
        let stills = files.filter { $0.path.deletingLastPathComponent().lastPathComponent == "stills" }.count
        func n(_ c: Int, _ w: String) -> String? { c == 0 ? nil : "\(c) \(w)\(c == 1 ? "" : "s")" }
        return [n(takes, "take"), n(edits, "edit"), n(stills, "still")].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A clip that plays from `start` for a few seconds, then again, without sound. The preview shows
/// the moment the search found, not the clip's first frame.
struct MomentPlayer: NSViewRepresentable {
    let url: URL
    let start: Double
    var length: Double = 8

    final class Box: NSView {
        var player: AVPlayer?
        var token: Any?
    }

    func makeNSView(context: Context) -> Box {
        let v = Box()
        v.wantsLayer = true
        let layer = AVPlayerLayer()
        // The box has the clip's own shape, so nothing is cut off (2026-10-28).
        layer.videoGravity = .resizeAspect
        layer.masksToBounds = true
        v.layer = layer
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.actionAtItemEnd = .pause
        let from = CMTime(seconds: start, preferredTimescale: 600)
        let end = CMTime(seconds: start + length, preferredTimescale: 600)
        v.token = p.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak p] in
            p?.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: from); p?.play()
        }
        p.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.play() }
        layer.player = p
        v.player = p
        return v
    }

    func updateNSView(_ v: Box, context: Context) {}

    static func dismantleNSView(_ v: Box, coordinator: ()) {
        if let t = v.token { v.player?.removeTimeObserver(t) }
        v.player?.pause()
        v.player = nil
    }
}
