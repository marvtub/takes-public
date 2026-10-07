import SwiftUI

// How the published posts do (2026-09-29). Each post in session.json "published" keeps its
// numbers over time in "stats"; Claude adds a reading with set_post_stats. This board shows the
// latest reading of every post, across all projects.

struct PerfItem: Identifiable, Hashable {
    let session: URL
    let project: String
    let title: String
    let post: Post
    var id: String { session.path + "#" + (post.platform ?? "") }
}

final class PerfBoard: ObservableObject {
    @Published private(set) var items: [PerfItem] = []
    /// The Signal dashboard numbers (Social.swift). Read again only when the file changes.
    @Published private(set) var social: SocialData?
    /// When new numbers came in while the app ran (Claude refreshed the board). The board shows it.
    @Published private(set) var freshAt: Date?
    private var socialStamp: Date?
    private var scanned = false

    /// FSEvents names the changed folders, not files: social.json shows up as <root>/_library and a
    /// session.json as its session folder (two levels under the root).
    static func matters(_ paths: [String], root: URL) -> Bool {
        let r = root.standardizedFileURL.pathComponents
        return paths.count > 20 || paths.contains { p in
            let c = URL(fileURLWithPath: p).standardizedFileURL.pathComponents
            guard c.count >= r.count, Array(c.prefix(r.count)) == r else { return false }
            let rest = c.dropFirst(r.count)
            return rest.isEmpty || rest.first == "_library" || (rest.count == 2 && !rest.first!.hasPrefix("_"))
        }
    }

    private var generation = 0

    /// Every published post in the library. One read of session.json per session, off the main
    /// thread: agents write session files often, and reading them all on the main thread made
    /// the board stutter while scrolling (2026-10-03).
    func scan(_ root: URL) {
        generation += 1
        let mine = generation, lastStamp = socialStamp
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.find(root)
            let stamp = Store.modified(SocialData.file(root))
            let social = stamp != lastStamp ? SocialData.read(root) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.generation else { return }
                var changed = false
                if found != self.items { self.items = found; changed = true }
                if stamp != self.socialStamp {
                    self.socialStamp = stamp
                    self.social = social
                    changed = true
                }
                if changed && self.scanned { self.freshAt = Date() }
                self.scanned = true
            }
        }
    }

    private static func find(_ root: URL) -> [PerfItem] {
        let fm = FileManager.default
        var found: [PerfItem] = []
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        where !project.lastPathComponent.hasPrefix("_") {
            for s in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                guard let meta = Store.readMeta(s) else { continue }
                for p in meta.published ?? [] {
                    found.append(PerfItem(session: s, project: project.lastPathComponent, title: meta.title, post: p))
                }
            }
        }
        return found.sorted { $0.post.at > $1.post.at }
    }

    /// The newest reading on the board.
    var updated: Date? { items.compactMap(\.post.latest?.at).max() }

    /// Reach gained since `date`, from each post's readings.
    static func gain(_ items: [PerfItem], since date: Date) -> Int {
        items.reduce(0) { sum, i in
            guard let stats = i.post.stats, let now = stats.last?.reach else { return sum }
            let before = stats.last { $0.at <= date }?.reach ?? (i.post.at > date ? 0 : now)
            return sum + max(0, now - before)
        }
    }
}

enum Num {
    /// 950, 12.4k, 1.2M.
    static func short(_ n: Int?) -> String {
        guard let n else { return "–" }
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1000)
        case ..<1_000_000: return "\(n / 1000)k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func rate(_ s: PostStat?) -> String {
        guard let s, let reach = s.reach, reach > 0 else { return "–" }
        return String(format: "%.1f%%", Double(s.engagement) / Double(reach) * 100)
    }
}

/// The sidebar way into the board, with the total reach.
struct PerformanceRow: View {
    @Environment(AppModel.self) var app
    @ObservedObject var board: PerfBoard
    let selected: Bool
    let open: () -> Void

    var body: some View {
        // The same label as Comments and Styles under it (2026-10-03).
        SideRow(selected: selected) {
            NavLabel(icon: "chart.bar.xaxis", title: "Performance", key: "⇧⌘J", active: selected) {
                let reach = board.items.compactMap(\.post.latest?.reach).reduce(0, +)
                if reach > 0 {
                    Text(Num.short(reach)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        .help("Impressions and views of all your posts")
                }
            }
        }
        .onTapGesture(perform: open)
        .help("How your published posts do (⇧⌘J)")
        .onAppear { board.scan(app.library.root) }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
            if let paths = n.object as? [String], PerfBoard.matters(paths, root: app.library.root) {
                board.scan(app.library.root)
            }
        }
    }
}

struct PerformanceView: View {
    @ObservedObject var board: PerfBoard
    let root: URL
    /// Opens a takes:// link: it leaves the board for that session.
    let handle: (URL) -> Void
    @AppStorage("perfPlatform") private var platform = ""
    @AppStorage("perfSort") private var sort = "newest"
    @State private var fresh = false
    @State private var hideFresh: Task<Void, Never>?

    private var shown: [PerfItem] {
        let list = platform.isEmpty ? board.items : board.items.filter { $0.post.label == platform }
        switch sort {
        case "reach": return list.sorted { ($0.post.latest?.reach ?? -1) > ($1.post.latest?.reach ?? -1) }
        case "rate": return list.sorted { rate($0) > rate($1) }
        default: return list
        }
    }

    private func rate(_ i: PerfItem) -> Double {
        guard let s = i.post.latest, let r = s.reach, r > 0 else { return -1 }
        return Double(s.engagement) / Double(r)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rule()
            ScrollView {
                Group {
                    if let social = board.social {
                        SignalPage(data: social, platform: platform) { takes }
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("No social dashboard yet. Ask Takes to run generate_dashboard.py; it writes _library/social.json for this board.")
                                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            takes
                        }
                    }
                }
                .padding(18)
                .id(platform)
                .transition(.opacity)
            }
            .animation(Theme.motion, value: platform)
        }
        .background(Theme.paper)
        .onAppear { Perf.mark("performance"); board.scan(root) }
    }

    /// The posts from Takes sessions, with the numbers Claude saved.
    @ViewBuilder private var takes: some View {
        SignalSection(label: "posts from takes", title: "Your sessions' posts, with the numbers Takes saves") {
            if board.items.isEmpty {
                Text("Nothing published yet. Mark a session published, or let Takes do it when a post goes live.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            } else if shown.isEmpty {
                Text("No \(platform) posts from your sessions yet.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    tiles
                    table
                }
            }
        }
    }

    // MARK: Top bar

    /// LinkedIn and X always (the dashboard has both), then any other platform a session posted to.
    private var platforms: [String] {
        var seen = board.social == nil ? [] : ["LinkedIn", "X"]
        for i in board.items where !seen.contains(i.post.label) { seen.append(i.post.label) }
        return seen
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Performance").font(Theme.sans(16, .bold))
            Button("All") { platform = "" }.buttonStyle(BracketButtonStyle(active: platform.isEmpty))
            ForEach(platforms, id: \.self) { p in
                Button { platform = platform == p ? "" : p } label: {
                    HStack(spacing: 5) { PlatformLogo(platform: p, size: 13); Text(p) }
                }
                .buttonStyle(BracketButtonStyle(active: platform == p))
            }
            Spacer(minLength: 12)
            if fresh {
                Label("Numbers updated", systemImage: "arrow.clockwise")
                    .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.accentSoft, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if let s = board.social, let at = Signal.updated(s) {
                // Re-reads the clock each minute, so "2 minutes ago" moves on by itself.
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Label("Updated \(at.formatted(.relative(presentation: .named)))", systemImage: "clock")
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.ink)
                }
                .help("Numbers refreshed \(at.formatted(date: .abbreviated, time: .shortened))")
            }
            Group {
                if board.social != nil {
                    EmptyView()
                } else if let u = board.updated {
                    Text("Numbers from \(u.formatted(.relative(presentation: .named)))")
                } else {
                    Text("No numbers yet")
                }
            }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            .help("Ask Takes \"update my post stats\". It reads each post's numbers and saves them here.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .animation(Theme.motion, value: fresh)
        .onChange(of: board.freshAt) { _, at in
            guard at != nil else { return }
            fresh = true
            hideFresh?.cancel()
            hideFresh = Task { try? await Task.sleep(for: .seconds(6)); if !Task.isCancelled { fresh = false } }
        }
    }

    // MARK: Totals

    private var tiles: some View {
        let list = shown
        let latest = list.compactMap(\.post.latest)
        let reach = latest.compactMap(\.reach).reduce(0, +)
        let engaged = latest.map(\.engagement).reduce(0, +)
        let week = PerfBoard.gain(list, since: Date().addingTimeInterval(-7 * 86400))
        return HStack(spacing: 12) {
            tile("posts", "\(list.count)", "\(latest.count) with numbers")
            tile("reach", Num.short(reach), week > 0 ? "+\(Num.short(week)) in 7 days" : "impressions and views")
            tile("engagement", Num.short(engaged), "likes, comments, reposts")
            tile("rate", reach > 0 ? String(format: "%.1f%%", Double(engaged) / Double(reach) * 100) : "–", "engagement ÷ reach")
        }
    }

    private func tile(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.ink)
            Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    // MARK: Table

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionLabel(text: "posts")
                Spacer()
                Picker("", selection: $sort) {
                    Text("Newest").tag("newest")
                    Text("Most reach").tag("reach")
                    Text("Best rate").tag("rate")
                }
                .labelsHidden().fixedSize()
            }
            .padding(.bottom, 8)
            header
            Rule()
            ForEach(shown) { i in
                PerfRowView(item: i) { open(i) }
                Rule()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("post").frame(maxWidth: .infinity, alignment: .leading)
            col("reach"); col("likes"); col("comments"); col("reposts"); col("rate")
            Text("trend").frame(width: 70, alignment: .leading)
            Color.clear.frame(width: 18, height: 1)
        }
        .font(Theme.mono(10, .medium)).foregroundStyle(Theme.muted).textCase(.uppercase)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func col(_ t: String) -> some View { Text(t).frame(width: 64, alignment: .trailing) }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.sans(13)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
    }

    private func open(_ i: PerfItem) {
        var c = URLComponents()
        c.scheme = "takes"; c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: i.session.path)]
        if let u = c.url { handle(u) }
    }
}

private struct PerfRowView: View {
    let item: PerfItem
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let s = item.post.latest
        HStack(spacing: 10) {
            PlatformLogo(platform: item.post.platform, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.sans(13, .semibold)).lineLimit(1)
                Text("\(item.project) · \(item.post.at.formatted(.dateTime.month(.abbreviated).day()))"
                     + (s.map { " · numbers \($0.at.formatted(.relative(presentation: .named)))" } ?? " · no numbers yet"))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            num(s?.reach, strong: true); num(s?.likes); num(s?.comments); num(s?.reposts)
            Text(Num.rate(s)).frame(width: 64, alignment: .trailing).font(Theme.mono(12)).foregroundStyle(Theme.muted)
            Sparkline(values: (item.post.stats ?? []).compactMap(\.reach)).frame(width: 70, height: 22)
            if let u = item.post.url.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.openSoon(u) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                    .frame(width: 18)
                    .help("Open the post on \(item.post.label)")
            } else {
                Color.clear.frame(width: 18, height: 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(hover ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Open the session")
    }

    private func num(_ n: Int?, strong: Bool = false) -> some View {
        Text(Num.short(n)).frame(width: 64, alignment: .trailing)
            .font(Theme.mono(12, strong ? .semibold : .regular))
            .foregroundStyle(n == nil ? Theme.muted : Theme.ink)
    }
}

/// Reach over the readings, as a thin line. One reading draws a dot.
struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { g in
            let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 0)
            let span = max(hi - lo, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count < 2 ? g.size.width : g.size.width * Double(i) / Double(values.count - 1),
                        y: hi == lo ? g.size.height / 2 : g.size.height - 2 - (g.size.height - 4) * (Double(v) - lo) / span)
            }
            if pts.count > 1 {
                Path { p in p.addLines(pts) }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            if let last = pts.last {
                Circle().fill(Theme.accent).frame(width: 4, height: 4).position(last)
            }
        }
    }
}
