import SwiftUI

/// Feedback (2026-10-08): what the agent learned from your review comments, and whether it gets
/// better. When the agent resolves a session comment it gives it a lesson (MCP reply_comment): a
/// rule in <root>/_library/rules/<area>.json, one file per step of the content journey (2026-10-09:
/// one lessons.json held them all, and one Post area held every platform), or "one-off". A comment on a rule that was already there is
/// a repeat: the same mistake again. A rule with a check is measured by check_edit (loudness, true
/// peak, pauses, length) and the results land in <session>/checks.json.
///
/// The board shows the counts, the comments per video week by week (the number should go down),
/// and the rules: you change, turn off or delete any of them, or tell Takes in the chat. A rule you
/// wrote, changed or turned off is yours: the agent does not change it (set_rule refuses).
/// The rule set stays small (10 per area, one sentence each), because every chat reads it.
enum Feedback {
    static let plugin = TakesPlugin(
        id: "feedback", title: "Feedback", icon: "graduationcap", key: "e",
        help: "What Takes learned from your comments: the rules it follows, and fewer comments per video over time (⇧⌘E)",
        badge: { _ in AnyView(EmptyView()) },
        board: { app in
            ClaudeChat.boardContexts["feedback"] = { context }
            return AnyView(FeedbackBoard(hub: app.chats, root: app.library.root))
        })

    static let context = """
    The user is talking to you from the Feedback board inside his Takes app. It shows the rules you \
    learned from his review comments (get_rules area=all; one file per step in _library/rules/ in his Takes \
    folder, with comments.md for the comment copilot's lessons), how many comments he leaves per video and how often the same mistake comes back. \
    Change rules as he asks with set_rule. A rule he wrote, changed or turned off is his. Keep the \
    set small: one short sentence per rule, at most 10 per area; merge or sharpen before you add. \
    He reads your replies in a narrow panel: keep them short, no tables, no headings.
    """

    /// In the order of the content journey: plan, make, package, publish. The MCP has the same list.
    static let areas: [(id: String, title: String, icon: String)] = [
        ("storyboard", "Storyboard", "rectangle.split.3x1"), ("script", "Script", "text.alignleft"),
        ("sound", "Sound", "waveform"), ("cut", "Cut", "scissors"), ("picture", "Picture", "camera.filters"),
        ("captions", "Captions", "captions.bubble"), ("graphics", "Graphics", "square.on.circle"),
        ("thumbnail", "Thumbnail", "photo"),
        ("post-all", "Every post", "text.bubble"), ("post-linkedin", "LinkedIn post", "text.bubble"),
        ("post-x", "X post", "text.bubble"), ("post-youtube", "YouTube post", "text.bubble"),
        ("post-vertical", "Shorts and Reels post", "text.bubble"),
        ("other", "Other", "ellipsis.circle"),
    ]
    /// The old Post area at the split: these two are about LinkedIn ("see more", the first comment).
    static let splitPost = ["post-1": "post-linkedin", "post-2": "post-linkedin"]
    static let areaMax = 10
    static let ruleMax = 220
}

struct RuleCheck: Codable, Hashable {
    var kind: String
    var target: Double?
    var tolerance: Double?
    var max: Double?
    var floor: Double?

    /// "Pauses ≤ 0.25 s", in a few words.
    var label: String {
        func n(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
        switch kind {
        case "loudness": return "Loudness \(n(target ?? -14)) ± \(n(tolerance ?? 1)) LUFS"
        case "peak": return "Peak ≤ \(n(max ?? -1)) dBTP"
        case "pauses": return "Pauses ≤ \(n(max ?? 0.4)) s"
        case "length": return "Length ≤ \(n(max ?? 0)) s"
        default: return kind
        }
    }
}

struct LearnedRule: Codable, Identifiable, Hashable {
    var id: String
    var area: String
    var text: String
    var on: Bool?
    /// "takes" (the agent) or "you".
    var by: String?
    var made: String?
    var changed: String?
    /// The comments it came from and the ones that repeated it: "<project>/<session>#<id>".
    var from: [String]?
    var repeats: [String]?
    var check: RuleCheck?

    var isOn: Bool { on ?? true }
    var yours: Bool { by == "you" }
}

struct LessonsFile: Codable {
    var rules: [LearnedRule] = []
}

enum Lessons {
    nonisolated static func folder(_ root: URL) -> URL { root.appending(path: "_library/rules") }
    nonisolated static func file(_ root: URL, area: String) -> URL { folder(root).appending(path: area + ".json") }
    /// The one file before the split.
    nonisolated static func oldFile(_ root: URL) -> URL { root.appending(path: "_library/lessons.json") }

    nonisolated static func read(_ root: URL) -> LessonsFile {
        split(root)
        var all = LessonsFile()
        for a in Feedback.areas {
            guard let data = try? Data(contentsOf: file(root, area: a.id)),
                  let f = try? JSONDecoder().decode(LessonsFile.self, from: data) else { continue }
            all.rules += f.rules.map { var r = $0; r.area = a.id; return r }
        }
        return all
    }

    /// Reads, changes and writes, so a rule the agent added in between is kept.
    nonisolated static func change(_ root: URL, _ change: (inout LessonsFile) -> Void) {
        var f = read(root)
        change(&f)
        write(root, f)
    }

    private nonisolated static func write(_ root: URL, _ f: LessonsFile) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try? FileManager.default.createDirectory(at: folder(root), withIntermediateDirectories: true)
        for a in Feedback.areas {
            let mine = f.rules.filter { $0.area == a.id }
            let url = file(root, area: a.id)
            // A file that does not read (a typo by hand) was not in f: leave it, never empty it.
            if let data = try? Data(contentsOf: url), (try? JSONDecoder().decode(LessonsFile.self, from: data)) == nil { continue }
            if mine.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? enc.encode(LessonsFile(rules: mine)) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Moves the one lessons.json into a file per area, once; it stays as lessons-before-split.json.
    /// The MCP does the same, so whichever runs first moves it.
    private nonisolated static func split(_ root: URL) {
        let fm = FileManager.default
        let old = oldFile(root)
        guard fm.fileExists(atPath: old.path),
              !((try? fm.contentsOfDirectory(atPath: folder(root).path)) ?? []).contains(where: { $0.hasSuffix(".json") }),
              let data = try? Data(contentsOf: old),
              var f = try? JSONDecoder().decode(LessonsFile.self, from: data) else { return }
        let known = Set(Feedback.areas.map(\.id))
        for i in f.rules.indices where !known.contains(f.rules[i].area) {
            f.rules[i].area = f.rules[i].area == "post" ? Feedback.splitPost[f.rules[i].id] ?? "post-all" : "other"
        }
        write(root, f)
        try? fm.moveItem(at: old, to: old.deletingLastPathComponent().appending(path: "lessons-before-split.json"))
    }

    nonisolated static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// A rule you wrote. Nil when the area is full or the text is empty.
    @discardableResult
    nonisolated static func add(_ root: URL, area: String, text: String) -> LearnedRule? {
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        var made: LearnedRule?
        change(root) { f in
            guard f.rules.filter({ $0.area == area && $0.isOn }).count < Feedback.areaMax else { return }
            let n = (f.rules.compactMap { r -> Int? in
                guard r.id.hasPrefix(area + "-") else { return nil }
                return Int(r.id.dropFirst(area.count + 1))
            }.max() ?? 0) + 1
            let r = LearnedRule(id: "\(area)-\(n)", area: area, text: String(text.prefix(Feedback.ruleMax)), on: true,
                                by: "you", made: now(), from: [], repeats: [])
            f.rules.append(r)
            made = r
        }
        return made
    }

    nonisolated static func edit(_ root: URL, _ id: String, _ change: @escaping (inout LearnedRule) -> Void) {
        self.change(root) { f in
            guard let i = f.rules.firstIndex(where: { $0.id == id }) else { return }
            change(&f.rules[i])
            f.rules[i].by = "you"
            f.rules[i].changed = now()
        }
    }

    nonisolated static func delete(_ root: URL, _ id: String) {
        change(root) { f in f.rules.removeAll { $0.id == id } }
    }
}

/// The counts on the board, from every session's comments.json and checks.json.
struct FeedbackStats: Equatable {
    struct Week: Equatable, Identifiable {
        let start: Date
        var videos = 0
        var comments = 0
        var repeats = 0
        /// The videos, by title, for the chart's hover card.
        var titles: [String] = []
        var id: Date { start }
        var perVideo: Double { videos > 0 ? Double(comments) / Double(videos) : 0 }
        var repeatsPerVideo: Double { videos > 0 ? Double(repeats) / Double(videos) : 0 }
    }

    var comments = 0
    var learned = 0
    var oneOff = 0
    var repeats = 0
    var videos = 0
    var checksRun = 0
    var checksCaught = 0
    /// Resolved since the first rule, with no lesson.
    var unlabeled = 0
    var weeks: [Week] = []
    /// Comments per video in the last 28 days and the 28 before (nil: no video then).
    var recent: Double?
    var before: Double?

    nonisolated static func dateOf(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Every session folder: <root>/<project>/<session>, not _library or hidden folders.
    nonisolated static func sessions(_ root: URL) -> [URL] {
        let fm = FileManager.default
        func dirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
                !$0.lastPathComponent.hasPrefix("_") && !$0.lastPathComponent.hasPrefix(".")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        return dirs(root).flatMap(dirs)
    }

    nonisolated static func scan(_ root: URL, rules: [LearnedRule], now: Date = Date()) -> FeedbackStats {
        var s = FeedbackStats()
        let cal = Calendar.current
        let started = rules.compactMap { $0.made.flatMap(dateOf) }.min()
        var weeks: [Date: Week] = [:]
        var recent: (videos: Int, comments: Int) = (0, 0), before: (videos: Int, comments: Int) = (0, 0)
        for session in sessions(root) {
            let mine = CommentStore.read(session).comments.filter { $0.by == "user" }
            if let data = try? Data(contentsOf: session.appending(path: "checks.json")),
               let checks = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
                for run in checks.values {
                    s.checksRun += 1
                    s.checksCaught += (run["results"] as? [[String: Any]] ?? []).filter { ($0["pass"] as? Bool) == false }.count
                }
            }
            guard !mine.isEmpty else { continue }
            let dates = mine.compactMap { dateOf($0.at) }
            let repeats = mine.filter { $0.repeat == true }.count
            s.videos += 1
            s.comments += mine.count
            s.repeats += repeats
            s.oneOff += mine.filter { $0.lesson == "one-off" }.count
            s.learned += mine.filter { $0.lesson != nil && $0.lesson != "one-off" }.count
            if let started {
                s.unlabeled += mine.filter { !$0.open && $0.lesson == nil && (dateOf($0.at) ?? .distantPast) > started }.count
            }
            // A video counts in the week of its first comment.
            guard let first = dates.min(), let week = cal.dateInterval(of: .weekOfYear, for: first)?.start else { continue }
            var w = weeks[week] ?? Week(start: week)
            w.videos += 1
            w.comments += mine.count
            w.repeats += repeats
            w.titles.append(PostQueue.title(session))
            weeks[week] = w
            let age = now.timeIntervalSince(first) / 86_400
            if age <= 28 { recent.videos += 1; recent.comments += mine.count }
            else if age <= 56 { before.videos += 1; before.comments += mine.count }
        }
        // The last 12 weeks, empty ones too, so the chart keeps its scale.
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        s.weeks = (0..<12).reversed().compactMap { i in
            cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek).map { weeks[$0] ?? Week(start: $0) }
        }
        s.recent = recent.videos > 0 ? Double(recent.comments) / Double(recent.videos) : nil
        s.before = before.videos > 0 ? Double(before.comments) / Double(before.videos) : nil
        return s
    }
}

@MainActor @Observable
final class FeedbackStore {
    var rules: [LearnedRule] = []
    var stats = FeedbackStats()
    var loaded = false
    private var busy = false
    private var again = false

    func refresh(_ root: URL) {
        guard !busy else { again = true; return }
        busy = true
        Task.detached(priority: .utility) {
            let rules = Lessons.read(root).rules
            let stats = FeedbackStats.scan(root, rules: rules)
            await MainActor.run {
                if self.rules != rules { self.rules = rules }
                if self.stats != stats { self.stats = stats }
                self.loaded = true
                self.busy = false
                if self.again { self.again = false; self.refresh(root) }
            }
        }
    }

    /// A change from the board: written, then read back at once.
    func change(_ root: URL, _ write: @escaping @Sendable () -> Void) {
        Task.detached(priority: .userInitiated) {
            write()
            await MainActor.run { self.refresh(root) }
        }
    }
}

struct FeedbackBoard: View {
    var hub: ChatHub
    let root: URL
    @State private var store = FeedbackStore()

    var body: some View {
        let target = ChatTarget(chat: hub.boardChat("feedback"), title: "Feedback", session: nil)
        ChatSlot(hub: hub, target: target) {
            FeedbackPage(store: store, root: root)
        }
        .overlay(alignment: .bottomTrailing) {
            BoardChatCorner(hub: hub, target: target).padding(18)
        }
        .onAppear { store.refresh(root) }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { _ in store.refresh(root) }
    }
}


/// The page, drawn in Takes's own style: no stock pickers, switches or charts (2026-10-09). Its
/// parts arrive one after the other when the counts are read; there is no spinner before them.
struct FeedbackPage: View {
    let store: FeedbackStore
    let root: URL

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.loaded {
                        tiles
                        WeeklyBars(weeks: store.stats.weeks).card(padding: 16).arrive(5)
                        RulesCard(store: store, root: root).arrive(6)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Feedback").font(Theme.sans(16, .bold)).foregroundStyle(Theme.ink)
                Text("What Takes learned from your comments, and whether it needs fewer of them")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28).frame(height: 58)
    }

    // MARK: Counts

    private var tiles: some View {
        let s = store.stats
        return HStack(alignment: .top, spacing: 14) {
            tile("Comments per video", s.recent.map(Self.one) ?? "–", note: trend, good: trendGood)
                .help("Your comments on each video whose first comment came in the last 4 weeks, against the 4 weeks before.")
                .arrive(0)
            tile("Comments you left", "\(s.comments)", note: "on \(s.videos) video\(s.videos == 1 ? "" : "s")")
                .arrive(1)
            tile("Learned", "\(s.learned)", note: "\(store.rules.filter(\.isOn).count) rules · \(s.oneOff) one-off")
                .help("Comments that became a rule or matched one. One-off: a fix for that video only.")
                .arrive(2)
            tile("Same mistake again", "\(s.repeats)", note: s.learned > 0 ? "of \(s.learned) learned" : "none yet",
                 good: s.repeats == 0 ? nil : false)
                .help("Comments on something a rule already covered. A rule that repeats should get a check.")
                .arrive(3)
            tile("Caught by checks", "\(s.checksCaught)", note: "in \(s.checksRun) check\(s.checksRun == 1 ? "" : "s") run")
                .help("Problems check_edit found before you saw the edit.")
                .arrive(4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }

    private var trend: String {
        guard let r = store.stats.recent else { return "no video in the last 4 weeks" }
        guard let b = store.stats.before else { return "last 4 weeks" }
        let d = r - b
        return abs(d) < 0.05 ? "same as the 4 weeks before" : "\(d < 0 ? "−" : "+")\(Self.one(abs(d))) on the 4 weeks before"
    }

    /// Fewer comments is good.
    private var trendGood: Bool? {
        guard let r = store.stats.recent, let b = store.stats.before, abs(r - b) >= 0.05 else { return nil }
        return r < b
    }

    private func tile(_ label: String, _ value: String, note: String, good: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.ink).monospacedDigit()
                .contentTransition(.numericText())
            Text(note).font(Theme.sans(11.5))
                .foregroundStyle(good == true ? Theme.live : good == false ? Theme.warn : Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 14)
    }
}

// MARK: - Chart

/// Comments per video, week by week. The bars grow in when the page opens; hover a week to see
/// its videos and counts.
struct WeeklyBars: View {
    let weeks: [FeedbackStats.Week]
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var grown = false
    @State private var hovered: Int?
    @State private var cardSize = CGSize(width: 240, height: 150)

    private let plotHeight: CGFloat = 180

    /// `hovered` only for a snapshot.
    init(weeks: [FeedbackStats.Week], hovered: Int? = nil) {
        self.weeks = weeks
        _hovered = State(initialValue: hovered)
        _grown = State(initialValue: revealAtOnce)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comments per video, by week").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                legend("New", Theme.accent)
                legend("Same mistake again", Theme.warn)
            }
            if weeks.allSatisfy({ $0.videos == 0 }) {
                Text("No comments in the last 12 weeks.").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                plot
                Text("A video counts in the week of your first comment on it. The bars should get shorter.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
        }
        .onAppear { if still || revealAtOnce { grown = true } else { DispatchQueue.main.async { grown = true } } }
    }

    /// A round top for the scale: 10, 20, 30, 40, 50, 100…
    private var top: Double {
        let m = weeks.map(\.perVideo).max() ?? 0
        let step: Double = m <= 10 ? 5 : m <= 50 ? 10 : 50
        return max(step, (m / step).rounded(.up) * step)
    }

    private var plot: some View {
        let n = weeks.count
        return VStack(spacing: 6) {
            GeometryReader { g in
                let axis: CGFloat = 26
                let w = g.size.width - axis
                let col = w / CGFloat(max(n, 1))
                let bar = min(col * 0.56, 36)
                ZStack(alignment: .topLeading) {
                    // The scale: three quiet lines with their numbers on the right.
                    ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                        let y = plotHeight * (1 - f)
                        Rectangle().fill(Theme.border.opacity(f == 0 ? 1 : 0.6)).frame(width: w, height: 1).offset(y: y)
                        Text(FeedbackPage.one(top * f)).font(Theme.sans(10.5)).foregroundStyle(Theme.faint).monospacedDigit()
                            .frame(width: axis - 4, alignment: .trailing)
                            .offset(x: w + 4, y: y - 7)
                    }
                    if let h = hovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover)
                            .frame(width: col - 4, height: plotHeight + 6)
                            .offset(x: CGFloat(h) * col + 2, y: -3)
                            .transition(.opacity)
                    }
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
                        column(wk, i: i, bar: bar)
                            .frame(width: col, height: plotHeight, alignment: .bottom)
                            .offset(x: CGFloat(i) * col)
                    }
                }
                .frame(width: g.size.width, height: plotHeight, alignment: .topLeading)
                // An overlay, so the card never moves the bars.
                .overlay(alignment: .topLeading) {
                    if let h = hovered, weeks.indices.contains(h) {
                        let mid = CGFloat(h) * col + col / 2
                        let y = plotHeight * (1 - CGFloat(min(weeks[h].perVideo / top, 1)))
                        FeedbackWeekCard(week: weeks[h])
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                            .offset(cardSpot(mid: mid, top: y, col: col, width: w))
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let i = Int(p.x / col)
                        let next = p.x < w && weeks.indices.contains(i) && weeks[i].videos > 0 ? i : nil
                        if next != hovered { withAnimation(Theme.motion) { hovered = next } }
                    case .ended: withAnimation(Theme.motion) { hovered = nil }
                    }
                }
            }
            .frame(height: plotHeight)
            // Dates under every other week; the hovered week's date in ink.
            GeometryReader { g in
                let col = (g.size.width - 26) / CGFloat(max(n, 1))
                ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
                    if i % 2 == 0 || hovered == i {
                        Text(wk.start.formatted(.dateTime.day().month(.abbreviated)))
                            .font(Theme.sans(10.5, hovered == i ? .medium : .regular))
                            .foregroundStyle(hovered == i ? Theme.ink : Theme.faint)
                            .fixedSize()
                            .frame(width: col)
                            .offset(x: CGFloat(i) * col)
                    }
                }
            }
            .frame(height: 14)
        }
    }

    /// Above its bar; beside it when the bar is too tall for that. Always inside the plot.
    private func cardSpot(mid: CGFloat, top y: CGFloat, col: CGFloat, width w: CGFloat) -> CGSize {
        let c = cardSize
        if y - c.height - 10 >= -24 {
            return CGSize(width: min(max(mid - c.width / 2, 0), max(w - c.width, 0)), height: y - c.height - 10)
        }
        let right = mid + col / 2
        let x = right + c.width <= w ? right : max(mid - col / 2 - c.width, 0)
        return CGSize(width: x, height: min(max(y - 10, -24), plotHeight - c.height))
    }

    private func column(_ wk: FeedbackStats.Week, i: Int, bar: CGFloat) -> some View {
        let scale = plotHeight / CGFloat(top)
        let fresh = CGFloat(wk.perVideo - wk.repeatsPerVideo) * scale
        let again = CGFloat(wk.repeatsPerVideo) * scale
        let dim = hovered != nil && hovered != i
        return VStack(spacing: 0) {
            if wk.videos == 0 {
                Capsule().fill(Theme.border).frame(width: bar, height: 3)
            } else {
                if again > 0 {
                    UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                        .fill(Theme.warn).frame(width: bar, height: again)
                }
                UnevenRoundedRectangle(topLeadingRadius: again > 0 ? 0 : 5, topTrailingRadius: again > 0 ? 0 : 5, style: .continuous)
                    .fill(Theme.accent).frame(width: bar, height: max(fresh, again > 0 ? 0 : 2))
            }
        }
        .scaleEffect(x: 1, y: grown ? 1 : 0.02, anchor: .bottom)
        .opacity(dim ? 0.35 : grown ? 1 : 0)
        .animation(.smooth(duration: 0.7).delay(0.2 + Double(i) * 0.035), value: grown)
        .animation(Theme.motion, value: dim)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
        }
    }
}

/// The hover card over a week: its counts and the videos in it.
private struct FeedbackWeekCard: View {
    let week: FeedbackStats.Week

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Week of \(week.start.formatted(.dateTime.day().month(.wide)))")
                .font(Theme.sans(11, .medium)).foregroundStyle(Theme.faint)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(FeedbackPage.one(week.perVideo)).font(Theme.display(22)).foregroundStyle(Theme.ink).monospacedDigit()
                Text("comments per video").font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(week.comments) comment\(week.comments == 1 ? "" : "s") on \(week.videos) video\(week.videos == 1 ? "" : "s")")
                if week.repeats > 0 {
                    Text("\(week.repeats) same mistake again").foregroundStyle(Theme.warn)
                }
            }
            .font(Theme.sans(12)).foregroundStyle(Theme.ink)
            if !week.titles.isEmpty {
                Rule()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(week.titles.prefix(4).enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.faint).frame(width: 3, height: 3)
                            Text(t).lineLimit(1)
                        }
                    }
                    if week.titles.count > 4 { Text("and \(week.titles.count - 4) more").foregroundStyle(Theme.faint) }
                }
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow, radius: 12, y: 5)
    }
}

// MARK: - Rules

/// The rules Takes follows, by area. Chips at the top pick an area; each rule has its own switch.
struct RulesCard: View {
    let store: FeedbackStore
    let root: URL
    /// nil: every area.
    @State private var area: String?
    @State private var adding: Bool

    /// `adding` only for a snapshot.
    init(store: FeedbackStore, root: URL, adding: Bool = false) {
        self.store = store
        self.root = root
        _adding = State(initialValue: adding)
    }

    var body: some View {
        let rules = store.rules
        let shown = area.map { a in rules.filter { $0.area == a } } ?? rules
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("Takes reads these before every edit.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if store.stats.unlabeled > 0 {
                    MetaTag(text: "\(store.stats.unlabeled) resolved without a lesson", icon: "exclamationmark.circle", tint: Theme.warn)
                        .help("Comments resolved after the first rule, with nothing learned. Resolving one in the app gives none.")
                }
                if !adding && !rules.isEmpty {
                    Button { withAnimation(.page) { adding = true } } label: {
                        Label("Add a rule", systemImage: "plus").font(Theme.sans(12, .medium))
                    }
                    .buttonStyle(BracketButtonStyle())
                }
            }
            if !rules.isEmpty {
                areaChips(rules)
            }
            if adding {
                RuleComposer(store: store, root: root, area: area ?? "cut") { withAnimation(.page) { adding = false } }
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if rules.isEmpty && !adding {
                empty
            } else if area == nil {
                ForEach(Feedback.areas, id: \.id) { a in
                    let mine = rules.filter { $0.area == a.id }
                    if !mine.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(a.title).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.muted)
                                Text("\(mine.filter(\.isOn).count) of \(Feedback.areaMax)").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                            }
                            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                            ForEach(mine) { RuleRow(rule: $0, store: store, root: root) }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { RuleRow(rule: $0, store: store, root: root) }
                }
            }
        }
        .card(padding: 16)
        .animation(.page, value: area)
        .animation(.page, value: rules.map(\.id))
    }

    private func areaChips(_ rules: [LearnedRule]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                AreaChip(title: "All", count: rules.count, on: area == nil) { area = nil }
                ForEach(Feedback.areas, id: \.id) { a in
                    let n = rules.filter { $0.area == a.id }.count
                    if n > 0 || area == a.id {
                        AreaChip(title: a.title, icon: a.icon, count: n, on: area == a.id) { area = a.id }
                    }
                }
                .padding(1)
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 14) {
            Image(systemName: "graduationcap").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accentInk)
                .frame(width: 38, height: 38).background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text("No rules yet").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Comment on an edit. When a fix holds for your next videos too, Takes writes it down here.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { withAnimation(.page) { adding = true } } label: { Text("Add a rule") }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas))
    }
}

/// An area to filter by: a soft capsule with its count.
private struct AreaChip: View {
    let title: String
    var icon: String?
    let count: Int
    let on: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(Theme.sans(12, .medium))
                if count > 0 { Text("\(count)").font(Theme.sans(11)).opacity(0.65).monospacedDigit() }
            }
            .foregroundStyle(on ? Theme.accentInk : hover ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(on ? Theme.accentSoft : hover ? Theme.hover : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .animation(Theme.motion, value: on)
    }
}

/// Writing a new rule: the area, one sentence, Add.
private struct RuleComposer: View {
    let store: FeedbackStore
    let root: URL
    @State var area: String
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(store: FeedbackStore, root: URL, area: String, done: @escaping () -> Void) {
        self.store = store
        self.root = root
        _area = State(initialValue: area)
        self.done = done
    }

    private var full: Bool { store.rules.filter { $0.area == area && $0.isOn }.count >= Feedback.areaMax }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Feedback.areas, id: \.id) { a in
                        AreaChip(title: a.title, icon: a.icon, count: 0, on: area == a.id) { area = a.id }
                    }
                }
                .padding(1)
            }
            TextField("", text: $text, prompt: Text(full ? "\(Feedback.areas.first { $0.id == area }?.title ?? "This area") has 10 rules. Change or delete one first."
                                                        : "One short sentence, for example: Keep pauses under 0.3 s.")
                .foregroundStyle(Theme.faint), axis: .vertical)
                .textFieldStyle(.plain).font(Theme.sans(13)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused($focused)
                .disabled(full)
                .onSubmit(add)
                .onExitCommand(perform: done)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: focused ? 1.5 : 1))
                .animation(Theme.motion, value: focused)
            HStack(spacing: 8) {
                Text("\(text.count)/\(Feedback.ruleMax)").font(Theme.sans(11)).foregroundStyle(text.count > Feedback.ruleMax ? Theme.warn : Theme.faint)
                    .monospacedDigit().opacity(text.isEmpty ? 0 : 1)
                Spacer()
                Button("Cancel", action: done).buttonStyle(BracketButtonStyle())
                Button("Add rule", action: add).buttonStyle(AccentButtonStyle(kind: .accent))
                    .disabled(full || empty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func add() {
        let area = area, text = text, root = root
        guard !full, !empty else { return }
        self.text = ""
        store.change(root) { Lessons.add(root, area: area, text: text) }
        done()
    }
}

/// A small on/off switch in Takes's colours.
struct RuleSwitch: View {
    let on: Bool
    let flip: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: flip) {
            Capsule().fill(on ? Theme.accent : hover ? Theme.faint.opacity(0.6) : Theme.border)
                .frame(width: 30, height: 18)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.spring, value: on)
        .animation(Theme.motion, value: hover)
    }
}

/// A few words of meta under a rule.
struct MetaTag: View {
    let text: String
    var icon: String?
    var tint: Color = Theme.muted

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(Theme.sans(11, .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.1)))
    }
}

private struct RuleRow: View {
    let rule: LearnedRule
    let store: FeedbackStore
    let root: URL
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    private var icon: String { Feedback.areas.first { $0.id == rule.area }?.icon ?? "circle" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
                .foregroundStyle(rule.isOn ? Theme.accentInk : Theme.faint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(rule.isOn ? Theme.accentSoft : Theme.hover))
            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(Theme.sans(13)).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit(save)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f && editing { save() } }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
                        .padding(.horizontal, -8).padding(.vertical, -5)
                } else {
                    Text(rule.text).font(Theme.sans(13)).foregroundStyle(rule.isOn ? Theme.ink : Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { draft = rule.text; editing = true; focused = true }
                        .help("Click to change it")
                }
                HStack(spacing: 6) {
                    if rule.yours {
                        MetaTag(text: "Yours", icon: "person.fill", tint: Theme.accentInk)
                            .help("You wrote or changed this rule. Takes will not change it back.")
                    }
                    if let c = rule.check {
                        MetaTag(text: c.label, icon: "checkmark.seal.fill", tint: Theme.live)
                            .help("Takes measures this on every new edit, before you see it.")
                    }
                    if let n = rule.repeats?.count, n > 0 {
                        MetaTag(text: "Came back \(n)×", icon: "arrow.uturn.backward", tint: Theme.warn)
                            .help(rule.check == nil ? "The same mistake came back. A check would catch it." : "The same mistake came back.")
                    }
                    Text(meta).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Button {
                let id = rule.id, root = root
                store.change(root) { Lessons.delete(root, id) }
            } label: {
                Image(systemName: "trash").font(.system(size: 11.5)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle())
            .opacity(hover && !editing ? 1 : 0)
            .help("Delete this rule")
            RuleSwitch(on: rule.isOn) {
                let id = rule.id, root = root, v = !rule.isOn
                store.change(root) { Lessons.edit(root, id) { $0.on = v } }
            }
            .padding(.top, 4)
            .help(rule.isOn ? "On: Takes follows it" : "Off: kept, not followed")
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover && !editing ? Theme.hover.opacity(0.6) : .clear))
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
    }

    private var meta: String {
        var parts: [String] = []
        let n = rule.from?.count ?? 0
        if n > 0 { parts.append("from \(n) comment\(n == 1 ? "" : "s")") }
        if let d = rule.made.flatMap(FeedbackStats.dateOf) { parts.append(d.formatted(.dateTime.day().month(.abbreviated))) }
        return parts.joined(separator: " · ")
    }

    private func save() {
        editing = false
        let text = draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text != rule.text else { return }
        let id = rule.id, root = root
        store.change(root) { Lessons.edit(root, id) { $0.text = String(text.prefix(Feedback.ruleMax)) } }
    }
}
