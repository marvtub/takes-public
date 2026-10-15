import SwiftUI

/// Feedback (2026-10-08): what the agent learned from your review comments, and whether it gets
/// better. When the agent resolves a session comment it gives it a lesson (MCP reply_comment): a
/// rule in <root>/_library/rules/<area>.json, one file per step of the content journey (2026-10-09:
/// one lessons.json held them all, and one Post area held every platform), or "one-off". A comment on a rule that was already there, when the edit broke it (missed), is
/// a repeat: the same mistake again. A rule with a check is measured by check_edit (loudness, true
/// peak, pauses, length) and the results land in <session>/checks.json. Since 2026-10-11 check_edit
/// also runs built-in checks that compare each edit with its take (Sources/Takes/EditChecks.swift):
/// the board counts their finds apart from the rules'.
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
    The user is talking to you from the Feedback board inside the Takes app. It shows the rules you \
    learned from the user's review comments (get_rules area=all; one file per step in _library/rules/ in the Takes \
    folder, with comments.md for the comment copilot's lessons), how many comments the user leaves per video and how often the same mistake comes back. \
    Change rules as the user asks with set_rule. A rule the user wrote, changed or turned off belongs to the user. Keep the \
    set small: one short sentence per rule, at most 10 per area; merge or sharpen before you add. \
    The user reads your replies in a narrow panel: keep them short, no tables, no headings.
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
    /// The longer words under a rule (the MCP's DETAILS_MAX).
    static let detailsMax = 600
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
    /// Longer words for the rule, past the one sentence (2026-10-10). Takes reads them with it.
    var details: String?
    /// Takes suggests to merge this rule into another one: the area was full. You approve it here.
    var merge: RuleMerge?
    /// Merged into this rule. Kept off, so the comments that point at it still find it.
    var mergedInto: String?

    enum CodingKeys: String, CodingKey {
        case id, area, text, on, by, made, changed, from, repeats, check, details, merge
        case mergedInto = "merged_into"
    }

    var isOn: Bool { on ?? true }
    var yours: Bool { by == "you" }
    /// Counts toward the 10 of its area: on, not waiting for a merge, not merged away. The MCP's
    /// counts() is the same rule, so the board and Takes agree when an area is full.
    var counts: Bool { isOn && merge == nil && mergedInto == nil }
}

/// A merge Takes suggests: the other rule's id, the sentence that holds both, and the other rule's
/// text when Takes wrote it (a changed rule makes the sentence stale).
struct RuleMerge: Codable, Hashable {
    var into: String
    var text: String
    var was: String?
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
            guard f.rules.filter({ $0.area == area && $0.counts }).count < Feedback.areaMax else { return }
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

    /// The rule a waiting merge goes into, when the merge still fits it: there, on, and with the
    /// text Takes saw when it wrote the merged sentence.
    nonisolated static func mergeTarget(_ rule: LearnedRule, in rules: [LearnedRule]) -> LearnedRule? {
        guard let m = rule.merge, let t = rules.first(where: { $0.id == m.into }), t.isOn, t.mergedInto == nil,
              m.was == nil || m.was == t.text else { return nil }
        return t
    }

    /// You approve Takes' merge: the other rule gets the merged text and this rule's comments, and
    /// this rule turns off. The other rule stays yours or Takes'. Nothing happens when the merge no
    /// longer fits (mergeTarget). With `text`, you saw both rules as they are now and approved these
    /// words: the merge goes in even if the other rule changed since, and changed words make it yours.
    nonisolated static func merge(_ root: URL, _ id: String, text: String? = nil) {
        change(root) { f in
            guard let i = f.rules.firstIndex(where: { $0.id == id }), let m = f.rules[i].merge,
                  let j = f.rules.firstIndex(where: { $0.id == m.into }) else { return }
            if let text {
                guard f.rules[j].isOn, f.rules[j].mergedInto == nil, !text.isEmpty else { return }
                if text != m.text { f.rules[j].by = "you" }
            } else if mergeTarget(f.rules[i], in: f.rules) == nil {
                return
            }
            let source = f.rules[i]
            f.rules[j].text = text ?? m.text
            var from = f.rules[j].from ?? []
            for r in source.from ?? [] where !from.contains(r) { from.append(r) }
            f.rules[j].from = from
            var repeats = f.rules[j].repeats ?? []
            for r in source.repeats ?? [] where !repeats.contains(r) { repeats.append(r) }
            f.rules[j].repeats = repeats
            f.rules[j].changed = now()
            f.rules[i].on = false
            f.rules[i].mergedInto = m.into
            f.rules[i].merge = nil
            f.rules[i].changed = now()
        }
    }

    /// Puts back a rule you just deleted (Undo), before the rule that followed it.
    nonisolated static func restore(_ root: URL, _ rule: LearnedRule, before: String?) {
        change(root) { f in
            guard !f.rules.contains(where: { $0.id == rule.id }) else { return }
            if let before, let i = f.rules.firstIndex(where: { $0.id == before }) {
                f.rules.insert(rule, at: i)
            } else {
                f.rules.append(rule)
            }
        }
    }

    /// Moves a rule to another area, with a new id there. Nothing happens when that area is full.
    nonisolated static func move(_ root: URL, _ id: String, to area: String) {
        change(root) { f in
            guard let i = f.rules.firstIndex(where: { $0.id == id }), f.rules[i].area != area,
                  f.rules.filter({ $0.area == area && $0.counts }).count < Feedback.areaMax else { return }
            let n = (f.rules.compactMap { r -> Int? in
                guard r.id.hasPrefix(area + "-") else { return nil }
                return Int(r.id.dropFirst(area.count + 1))
            }.max() ?? 0) + 1
            let new = "\(area)-\(n)"
            for j in f.rules.indices {
                if f.rules[j].merge?.into == id { f.rules[j].merge?.into = new }
                if f.rules[j].mergedInto == id { f.rules[j].mergedInto = new }
            }
            f.rules[i].id = new
            f.rules[i].area = area
            f.rules[i].by = "you"
            f.rules[i].changed = now()
        }
    }

    enum DiffKind { case same, added, removed }

    /// Word by word, what changes from `old` to `new`: runs of kept, added and removed words.
    nonisolated static func wordDiff(_ old: String, _ new: String) -> [(kind: DiffKind, words: String)] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        let key = { (w: String) in w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var l = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                l[i][j] = key(a[i]) == key(b[j]) ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var out: [(kind: DiffKind, words: String)] = []
        func put(_ k: DiffKind, _ w: String) {
            if let last = out.last, last.kind == k { out[out.count - 1].words += " " + w } else { out.append((k, w)) }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, key(a[i]) == key(b[j]) { put(.same, b[j]); i += 1; j += 1 }
            // What goes reads before what comes in its place.
            else if i < a.count, j == b.count || l[i + 1][j] >= l[i][j + 1] { put(.removed, a[i]); i += 1 }
            else { put(.added, b[j]); j += 1 }
        }
        return out
    }

    /// You keep both rules: the suggestion goes, the rule stays as it is.
    nonisolated static func keepBoth(_ root: URL, _ id: String) {
        change(root) { f in
            guard let i = f.rules.firstIndex(where: { $0.id == id }) else { return }
            f.rules[i].merge = nil
        }
    }

    /// The rules the board shows: a rule merged into another one is history.
    nonisolated static func shown(_ rules: [LearnedRule]) -> [LearnedRule] { rules.filter { $0.mergedInto == nil } }
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
    /// Failures of learned rules ("rule" results).
    var checksCaught = 0
    /// Failures of the built-in checks ("check" results, 2026-10-11).
    var builtinCaught = 0
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
                    let failed = (run["results"] as? [[String: Any]] ?? []).filter { ($0["pass"] as? Bool) == false }
                    s.builtinCaught += failed.filter { $0["check"] != nil }.count
                    s.checksCaught += failed.filter { $0["check"] == nil }.count
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
    /// The files FeedbackStats and Lessons read.
    nonisolated static func matters(_ paths: [String], root: URL) -> Bool {
        FileWatch.matters(paths, root: root, library: ["rules", "lessons.json"],
                          files: ["session.json", "comments.json", "checks.json"], folders: [])
    }

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
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
            guard FeedbackStore.matters(n.object as? [String] ?? [], root: root) else { return }
            store.refresh(root)
        }
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
            tile("Caught by checks", "\(s.checksCaught)", note: "in \(s.checksRun) check\(s.checksRun == 1 ? "" : "s") run"
                 + (s.builtinCaught > 0 ? ". Built-in checks: \(s.builtinCaught)." : ""))
                .help("Problems the rule checks found before you saw the edit. Since 2026-10-11, check_edit also "
                      + "compares sound and picture with the take: the built-in checks.")
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

/// The rules Takes follows, in two views (2026-10-14, picked on the design canvas): Rules, one area
/// at a time as a plain numbered list you can search, and Merges, the merges Takes suggests, one at
/// a time. Every area at once was 80 rows; a merge under a rule far down the list was never seen.
struct RulesCard: View {
    enum Mode: Hashable { case rules, merges }
    let store: FeedbackStore
    let root: URL
    /// The area he looked at last.
    @AppStorage("rules.area") private var picked = ""
    @State private var adding: Bool
    @State private var mode: Mode
    @State private var search: String
    /// The rule you just deleted, while Undo shows.
    @State private var removed: (rule: LearnedRule, before: String?)?
    @FocusState private var searching: Bool

    /// `adding`, `area`, `merges` and `search` only for a snapshot.
    init(store: FeedbackStore, root: URL, adding: Bool = false, area: String? = nil, merges: Bool = false, search: String = "") {
        self.store = store
        self.root = root
        _adding = State(initialValue: adding)
        _mode = State(initialValue: merges ? .merges : .rules)
        _search = State(initialValue: search)
        if let area { UserDefaults.standard.set(area, forKey: "rules.area") }
    }

    var body: some View {
        let rules = Lessons.shown(store.rules)
        let waiting = rules.filter { $0.merge != nil }
        let areas = Feedback.areas.filter { a in rules.contains { $0.area == a.id } }
        let area = areas.contains { $0.id == picked } ? picked : areas.first?.id ?? "cut"
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 16) {
            header(waiting: waiting.count, empty: rules.isEmpty)
            if mode == .merges {
                MergeQueue(waiting: waiting, store: store, root: root)
                    .transition(.opacity)
            } else {
                if adding {
                    RuleComposer(store: store, root: root, area: area) { withAnimation(.page) { adding = false } }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
                if rules.isEmpty && !adding {
                    empty
                } else if !query.isEmpty {
                    SearchResults(query: query, rules: rules, store: store, root: root,
                                  delete: delete, openMerges: openMerges)
                } else if !rules.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(areas, id: \.id) { a in
                                AreaChip(title: a.title, count: rules.filter { $0.area == a.id && $0.counts }.count,
                                         on: a.id == area) { picked = a.id }
                            }
                        }
                        .padding(1)
                    }
                    AreaRules(rules: rules.filter { $0.area == area }, store: store, root: root,
                              delete: delete, openMerges: openMerges)
                        .id(area)
                        .transition(.opacity)
                }
            }
            if let removed { undo(removed.rule) }
        }
        .card(padding: 16)
        .animation(.page, value: mode)
        .animation(.page, value: area)
        .animation(.page, value: rules.map(\.id))
        .animation(.page, value: query.isEmpty)
        .animation(.page, value: removed?.rule.id)
        .task(id: removed?.rule.id) {
            guard removed != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { removed = nil }
        }
    }

    private func header(waiting: Int, empty: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if empty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("Takes reads these before every edit.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            } else {
                ModeSwitch(mode: $mode, waiting: waiting)
            }
            Spacer(minLength: 8)
            if mode == .rules {
                if store.stats.unlabeled > 0 {
                    MetaTag(text: "\(store.stats.unlabeled) resolved without a lesson", icon: "exclamationmark.circle", tint: Theme.warn)
                        .help("Comments resolved after the first rule, with nothing learned. Resolving one in the app gives none.")
                }
                if !empty { searchField }
                if !adding && !empty {
                    Button { withAnimation(.page) { adding = true } } label: {
                        Label("Add a rule", systemImage: "plus").font(Theme.sans(12, .medium))
                    }
                    .buttonStyle(BracketButtonStyle())
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
            TextField("", text: $search, prompt: Text("Search \(Lessons.shown(store.rules).filter(\.counts).count) rules").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                .focused($searching)
                .onExitCommand { search = ""; searching = false }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10).frame(width: 220, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searching ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: searching ? 1.5 : 1))
        .animation(Theme.motion, value: searching)
    }

    private func openMerges() { withAnimation(.page) { mode = .merges } }

    /// Deletes at once and shows Undo, the way a take goes to the Trash.
    private func delete(_ rule: LearnedRule) {
        let list = store.rules
        let before = list.firstIndex { $0.id == rule.id }.flatMap { i in list.dropFirst(i + 1).first { $0.area == rule.area }?.id }
        removed = (rule, before)
        let id = rule.id, root = root
        store.change(root) { Lessons.delete(root, id) }
    }

    private func undo(_ rule: LearnedRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("Deleted: \(rule.text)").font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                guard let r = removed else { return }
                removed = nil
                let root = root
                store.change(root) { Lessons.restore(root, r.rule, before: r.before) }
            }
            .buttonStyle(BracketButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
        .transition(.opacity.combined(with: .offset(y: 6)))
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

/// Rules | Merges, with how many merges wait. The TakesSwitch look, plus the count.
private struct ModeSwitch: View {
    @Binding var mode: RulesCard.Mode
    let waiting: Int
    @Namespace private var ns
    @State private var hover: RulesCard.Mode?

    var body: some View {
        HStack(spacing: 2) {
            option(.rules, "Rules")
            option(.merges, "Merges")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .fixedSize()
    }

    private func option(_ value: RulesCard.Mode, _ title: String) -> some View {
        let on = value == mode
        return Button { withAnimation(Theme.motion) { mode = value } } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.sans(12.5, on ? .semibold : .medium))
                if value == .merges && waiting > 0 {
                    Text("\(waiting)").font(Theme.sans(10.5, .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Theme.accent))
                }
            }
            .foregroundStyle(on || hover == value ? Theme.ink : Theme.muted)
            .padding(.horizontal, 12).frame(minHeight: 28)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .matchedGeometryEffect(id: "on", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 ? value : (hover == value ? nil : hover) }
        .help(value == .merges ? (waiting == 0 ? "No merges to check" : "Merges Takes suggests: \(waiting)") : "Every rule, one area at a time")
    }
}

/// One area's rules, numbered: those Takes follows, then the ones you turned off, under a fold.
private struct AreaRules: View {
    let rules: [LearnedRule]
    let store: FeedbackStore
    let root: URL
    let delete: (LearnedRule) -> Void
    let openMerges: () -> Void
    @State private var showOff = false

    var body: some View {
        let on = rules.filter { $0.isOn }
        let off = rules.filter { !$0.isOn }
        let n = rules.filter(\.counts).count
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            ForEach(Array(on.enumerated()), id: \.element.id) { i, r in
                RuleRow(rule: r, number: i + 1, store: store, root: root, delete: delete, openMerges: openMerges)
                Rule()
            }
            HStack(spacing: 12) {
                if !off.isEmpty {
                    Button { withAnimation(.page) { showOff.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(showOff ? 90 : 0))
                            Text("\(off.count) turned off")
                        }
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.faint)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
                Spacer()
                if n > Feedback.areaMax {
                    Text("\(n) of \(Feedback.areaMax): turn off or delete one you need less")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
            if showOff {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(off) { RuleRow(rule: $0, number: nil, store: store, root: root, delete: delete, openMerges: openMerges) }
                }
                .padding(.top, 4)
            }
        }
    }
}

/// What a search finds, in every area, under each area's name.
private struct SearchResults: View {
    let query: String
    let rules: [LearnedRule]
    let store: FeedbackStore
    let root: URL
    let delete: (LearnedRule) -> Void
    let openMerges: () -> Void

    var body: some View {
        let hits = rules.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.details ?? "").localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 14) {
            if hits.isEmpty {
                Text("No rule says “\(query)”.").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
            }
            ForEach(Feedback.areas.filter { a in hits.contains { $0.area == a.id } }, id: \.id) { a in
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: a.title).padding(.horizontal, 10).padding(.bottom, 6)
                    Rule()
                    ForEach(hits.filter { $0.area == a.id }) { r in
                        RuleRow(rule: r, number: nil, store: store, root: root, delete: delete, openMerges: openMerges)
                        Rule()
                    }
                }
            }
        }
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

    private var count: Int { store.rules.filter { $0.area == area && $0.counts }.count }
    private var full: Bool { count >= Feedback.areaMax }
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
            TextField("", text: $text, prompt: Text(full ? "\(Feedback.areas.first { $0.id == area }?.title ?? "This area") has \(count) rules. Change or delete one first."
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

/// One rule as a plain line: its number, its words, and on hover a pencil and a … menu. Click the
/// words to change them in place.
private struct RuleRow: View {
    let rule: LearnedRule
    let number: Int?
    let store: FeedbackStore
    let root: URL
    let delete: (LearnedRule) -> Void
    let openMerges: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var editingDetails = false
    @State private var detailsDraft = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    @FocusState private var detailsFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number.map(String.init) ?? "")
                .font(Theme.sans(12)).monospacedDigit().foregroundStyle(editing ? Theme.accentInk : Theme.faint)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                if editing {
                    editor
                } else {
                    Text(rule.text).font(Theme.sans(13.5)).foregroundStyle(rule.isOn ? Theme.ink : Theme.faint)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: startEditing)
                        .help("Click to change it")
                }
                if editingDetails {
                    TextField("", text: $detailsDraft, axis: .vertical)
                        .textFieldStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .focused($detailsFocused)
                        .onSubmit(saveDetails)
                        .onExitCommand { editingDetails = false }
                        .onChange(of: detailsFocused) { _, f in if !f && editingDetails { saveDetails() } }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
                        .padding(.horizontal, -8).padding(.vertical, -5)
                } else if let details = rule.details, !details.isEmpty, !editing {
                    Text(details).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { detailsDraft = details; editingDetails = true; detailsFocused = true }
                        .help("More about this rule. Click to change it.")
                }
            }
            if rule.merge != nil && !editing {
                Button(action: openMerges) {
                    Text("Merge waiting").font(Theme.sans(11, .semibold)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                .buttonStyle(PressStyle())
                .help("Takes wants to merge this rule with another one. Open Merges.")
            }
            if !editing { tools.opacity(hover ? 1 : 0) }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && !editing ? Theme.hover.opacity(0.6) : .clear))
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .animation(Theme.motion, value: editing)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand { editing = false }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
                .padding(.horizontal, -10)
            HStack(spacing: 8) {
                Button("Save", action: save).buttonStyle(AccentButtonStyle(kind: .accent))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editing = false }.buttonStyle(BracketButtonStyle())
                Spacer()
                Text("Return saves · Esc cancels").font(Theme.sans(11)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            Button(action: startEditing) {
                Image(systemName: "pencil").font(.system(size: 11.5)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle())
            .help("Change the words")
            TakesMenuButton(width: 210, help: "More") {
                Image(systemName: "ellipsis").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            } content: {
                MenuButton("Edit", icon: "pencil", action: startEditing)
                MenuButton("Add more words", icon: "text.append") {
                    detailsDraft = rule.details ?? ""; editingDetails = true; detailsFocused = true
                }
                MenuGroup("Move to area", icon: "arrow.right") {
                    for a in Feedback.areas where a.id != rule.area {
                        let full = store.rules.filter { $0.area == a.id && $0.counts }.count >= Feedback.areaMax
                        MenuButton(a.title, detail: full ? "full" : nil, enabled: !full) {
                            let id = rule.id, root = root, to = a.id
                            store.change(root) { Lessons.move(root, id, to: to) }
                        }
                    }
                }
                MenuButton(rule.isOn ? "Turn off" : "Turn on", icon: rule.isOn ? "pause.circle" : "play.circle") {
                    let id = rule.id, root = root, v = !rule.isOn
                    store.change(root) { Lessons.edit(root, id) { $0.on = v } }
                }
                MenuDivider()
                MenuButton("Delete", icon: "trash", danger: true) { delete(rule) }
            }
        }
        .padding(.top, -4)
    }

    private func startEditing() { draft = rule.text; editing = true; focused = true }

    private func save() {
        editing = false
        let text = draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text != rule.text else { return }
        let id = rule.id, root = root
        store.change(root) { Lessons.edit(root, id) { $0.text = String(text.prefix(Feedback.ruleMax)) } }
    }

    private func saveDetails() {
        editingDetails = false
        let text = detailsDraft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text != (rule.details ?? "") else { return }
        let id = rule.id, root = root
        store.change(root) { Lessons.edit(root, id) { $0.details = text.isEmpty ? nil : String(text.prefix(Feedback.detailsMax)) } }
    }
}

/// The Merges view: the merges Takes suggests, one at a time. The other rule as it would read
/// after the merge, with what the new rule adds marked and what goes struck through. When the
/// other rule changed after Takes wrote the sentence, you still decide (2026-10-14: the old box
/// offered only Keep both, so the merge could never happen).
private struct MergeQueue: View {
    let waiting: [LearnedRule]
    let store: FeedbackStore
    let root: URL
    @State private var index = 0

    var body: some View {
        if waiting.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.live)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.liveSoft))
                Text("Nothing to check").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text("When an area is full, Takes suggests a merge here.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 36)
        } else {
            let i = min(index, waiting.count - 1)
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    if waiting.count > 1 {
                        Button { index = max(0, i - 1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                            .buttonStyle(IconButtonStyle()).disabled(i == 0).help("Previous merge")
                    }
                    Text("\(i + 1) of \(waiting.count) · \(Feedback.areas.first { $0.id == waiting[i].area }?.title ?? "")")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted).monospacedDigit()
                    if waiting.count > 1 {
                        Button { index = min(waiting.count - 1, i + 1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                            .buttonStyle(IconButtonStyle()).disabled(i == waiting.count - 1).help("Next merge")
                    }
                }
                MergeCard(rule: waiting[i], store: store, root: root)
                    .id(waiting[i].id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .animation(.page, value: waiting[i].id)
        }
    }
}

private struct MergeCard: View {
    let rule: LearnedRule
    let store: FeedbackStore
    let root: URL
    @State private var text: String
    @State private var editing = false
    @FocusState private var focused: Bool

    init(rule: LearnedRule, store: FeedbackStore, root: URL) {
        self.rule = rule
        self.store = store
        self.root = root
        _text = State(initialValue: rule.merge?.text ?? "")
    }

    var body: some View {
        let other = store.rules.first { $0.id == rule.merge?.into }
        let alive = other.map { $0.isOn && $0.mergedInto == nil } ?? false
        let stale = alive && Lessons.mergeTarget(rule, in: store.rules) == nil
        let area = Feedback.areas.first { $0.id == rule.area }?.title ?? "this area"
        let after = store.rules.filter { $0.area == rule.area && $0.counts }.count + 1
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        VStack(spacing: 16) {
            Text(alive ? "Merge two \(area) rules?" : "The other rule is gone")
                .font(Theme.display(22)).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 12) {
                if let other, alive {
                    if editing {
                        TextField("", text: $text, axis: .vertical)
                            .textFieldStyle(.plain).font(Theme.sans(15)).foregroundStyle(Theme.ink)
                            .lineLimit(2...6)
                            .focused($focused)
                            .onExitCommand { editing = false }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
                    } else {
                        Text(Self.marked(from: other.text, to: clean)).font(Theme.sans(15)).foregroundStyle(Theme.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.25)).frame(width: 14, height: 10)
                            Text("From the new rule")
                        }
                        HStack(spacing: 6) {
                            Text("abc").strikethrough().foregroundStyle(Theme.faint)
                            Text("Taken out of the other rule")
                        }
                    }
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    .opacity(editing ? 0 : 1)
                    Text("New rule: \(rule.text)").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    if stale {
                        Text("Takes wrote this before the other rule changed. Check that it still says both.")
                            .font(Theme.sans(11.5)).foregroundStyle(Theme.warn)
                    }
                } else {
                    Text(rule.text).font(Theme.sans(15)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The rule it would merge into is gone or off. Keep this one as its own rule.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            HStack(spacing: 8) {
                if alive {
                    Button("Merge") {
                        let id = rule.id, root = root, t = String(clean.prefix(Feedback.ruleMax))
                        store.change(root) { Lessons.merge(root, id, text: t) }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .accent))
                    .disabled(clean.isEmpty)
                    .help("The other rule gets these words. The new rule turns off.")
                    Button(editing ? "Done" : "Edit words") {
                        editing.toggle()
                        if editing { DispatchQueue.main.async { focused = true } }
                    }
                    .buttonStyle(BracketButtonStyle())
                }
                Button(alive ? "Keep both" : "Keep as its own rule") {
                    let id = rule.id, root = root
                    store.change(root) { Lessons.keepBoth(root, id) }
                }
                .buttonStyle(BracketButtonStyle())
                .help("Keep both rules as they are. \(area) then has \(after) rules.")
            }
        }
        .animation(Theme.motion, value: editing)
    }

    /// The merged words, with words new to the other rule marked and the words it loses struck.
    static func marked(from old: String, to new: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in Lessons.wordDiff(old, new).enumerated() {
            var s = AttributedString((i > 0 ? " " : "") + part.words)
            switch part.kind {
            case .same: break
            case .added: s.backgroundColor = Theme.accent.opacity(0.25)
            case .removed:
                s.strikethroughStyle = .single
                s.foregroundColor = Theme.faint
            }
            out += s
        }
        return out
    }
}
