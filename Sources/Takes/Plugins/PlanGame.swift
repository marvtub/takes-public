import SwiftUI

/// The Plan board's game layer (2026-10-10): it makes showing up feel good, never guilty.
///
/// - **Week rings:** Ideas (videos started), Recorded (videos with a take) and Posts (videos posted
///   or scheduled), this calendar week. The goals come from the plan: posts = posting days a week,
///   recorded = the same, ideas = one more. They fill up and reset each week. No red, ever.
/// - **Week streak:** weeks in a row that reached the posting goal. This week only adds, it never
///   breaks the streak while it runs. One rest week a month bridges a missed week by itself.
/// - **Video steps:** Idea, Script, Record, Edit, Post. A later step fills the ones before it (a
///   video recorded without a script has no hole). "Almost there" lists only videos one or two steps
///   from out that moved in the last three weeks, at most three. Old ones are never counted or named.
/// - **Wins:** like YouTube Studio. A post that ranks (best ever, best in 90 days, top 3, 2x the
///   typical post) gets a card, and lifetime milestones show the way to the next one. Only good news.
///
/// All of it is read from files the app already has: nothing new to keep in sync. What the user has
/// seen (wins) stays in UserDefaults on this Mac.
struct WeekGame: Equatable {
    struct Ring: Equatable {
        let name: String
        var count = 0
        var goal = 1
        var done: Bool { count >= goal }
        var progress: Double { goal > 0 ? min(Double(count) / Double(goal), 1) : 0 }
    }

    /// A video one or two steps from out.
    struct Almost: Equatable, Identifiable {
        let id: String
        let title: String
        let url: URL
        let step: Int
        /// It has a ready post with no day yet.
        var readyNoDay = false
    }

    struct Win: Equatable, Identifiable {
        let id: String
        let title: String
        let url: URL
        let platform: String
        let reach: Int
        let label: String
        let at: Date
    }

    struct Milestone: Equatable, Identifiable {
        let id: String
        /// "impressions", "videos out".
        let unit: String
        let total: Int
        /// The last milestone passed, and the next one.
        let passed: Int?
        let next: Int
        var progress: Double {
            let from = Double(passed ?? 0)
            return max(0, min(1, (Double(total) - from) / max(Double(next) - from, 1)))
        }
    }

    var ideas = Ring(name: "Ideas")
    var recorded = Ring(name: "Recorded")
    var posts = Ring(name: "Posts")
    var rings: [Ring] { [ideas, recorded, posts] }
    /// Weeks in a row at the posting goal (rest weeks bridge, they do not add).
    var streak = 0
    /// This week reached the goal: it is in the streak already.
    var weekCounted = false
    /// The streak has a rest week in it.
    var rested = false
    /// A rest week is still free this month.
    var restLeft = true
    /// The weeks in the streak, by week start: counted at the goal, or bridged by a rest week.
    var chain: [Date: Link] = [:]
    enum Link: Equatable { case counted, rest }
    /// Each session's step (0 Idea ... 4 Post), by "Project/folder".
    var steps: [String: Int] = [:]
    var almost: [Almost] = []
    var wins: [Win] = []
    var milestones: [Milestone] = []

    static let stepNames = ["Idea", "Script", "Record", "Edit", "Post"]
    static let reachMarks = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000]
    static let videoMarks = [1, 5, 10, 25, 50, 100, 250, 500, 1000]

    /// What one session folder holds, read once.
    struct Video {
        let id: String
        let url: URL
        var title: String
        var createdAt: Date?
        var archived = false
        var takes: [Date] = []
        var script = false
        var edit: Date?
        var touched: Date?
        /// When each post went out (published, or posted/scheduled in the queue), and how far it reached.
        var out: [(platform: String, at: Date, reach: Int?)] = []
        var ready = false
        var readyNoDay = false

        var step: Int {
            if !out.isEmpty { return 4 }
            if edit != nil || ready { return 3 }
            if !takes.isEmpty { return 2 }
            if script { return 1 }
            return 0
        }
        var active: Date? { ([createdAt, edit, touched] + takes.map { Optional($0) }).compactMap { $0 }.max() }
    }

    nonisolated static func scan(_ root: URL, plan: PostingPlan, now: Date = Date(), cal: Calendar = .current) -> WeekGame {
        var videos: [String: Video] = [:]
        let fm = FileManager.default
        for url in FeedbackStats.sessions(root) {
            let id = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            guard let data = try? Data(contentsOf: url.appending(path: "session.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var v = Video(id: id, url: url, title: (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent)
            v.createdAt = (json["createdAt"] as? String).flatMap(FeedbackStats.dateOf)
            v.archived = json["archived"] as? Bool ?? false
            v.takes = ((json["takes"] as? [[String: Any]]) ?? []).compactMap { ($0["startedAt"] as? String).flatMap(FeedbackStats.dateOf) }
            let script = (try? String(contentsOf: url.appending(path: "script.md"), encoding: .utf8)) ?? ""
            v.script = !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || fm.fileExists(atPath: Storyboard.file(url).path)
            v.edit = newestVideo(url.appending(path: "edits"))
            v.touched = Store.modified(url.appending(path: "session.json"))
            for p in (json["published"] as? [[String: Any]]) ?? [] {
                guard let at = (p["at"] as? String).flatMap(FeedbackStats.dateOf) else { continue }
                let stats = (p["stats"] as? [[String: Any]]) ?? []
                let reach = stats.last.flatMap { ($0["impressions"] as? Int) ?? ($0["views"] as? Int) }
                v.out.append(((p["platform"] as? String) ?? "Published", at, reach))
            }
            videos[id] = v
        }
        // The queue: posted and scheduled posts count as out on their day; ready ones as step 3.
        // A post the autopost plugin could not send is not out: it waits for a retry, like a ready one.
        let failed = Plugins.builtAutopost?.failed
        for p in PostQueue.read(root) {
            let id = p.project + "/" + p.session.lastPathComponent
            guard var v = videos[id] else { continue }
            var c = p.content
            if c.status == .scheduled, failed?(c) == true { c.status = .ready }
            switch c.status {
            case .posted, .scheduled:
                if let at = c.at, !v.out.contains(where: { $0.platform.lowercased() == p.platform.name.lowercased() }) {
                    v.out.append((p.platform.name, at, nil))
                } else if c.at == nil, c.status == .posted, v.out.isEmpty {
                    v.ready = true
                }
            case .ready:
                v.ready = true
                if c.at == nil { v.readyNoDay = true }
            default: break
            }
            videos[id] = v
        }
        return game(Array(videos.values), plan: plan, now: now, cal: cal)
    }

    nonisolated static func game(_ videos: [Video], plan: PostingPlan, now: Date, cal: Calendar) -> WeekGame {
        var g = WeekGame()
        let week = { (d: Date) in cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d) }
        let thisWeek = week(now)
        let postGoal = max(plan.days.count, 1)

        // Per week: videos started, recorded and out.
        var started: [Date: Set<String>] = [:], recorded: [Date: Set<String>] = [:], out: [Date: Set<String>] = [:]
        for v in videos {
            if let c = v.createdAt { started[week(c), default: []].insert(v.id) }
            for t in v.takes { recorded[week(t), default: []].insert(v.id) }
            for o in v.out { out[week(o.at), default: []].insert(v.id) }
            g.steps[v.id] = v.step
        }
        func rings(_ w: Date) -> (Ring, Ring, Ring) {
            (Ring(name: "Ideas", count: started[w]?.count ?? 0, goal: postGoal + 1),
             Ring(name: "Recorded", count: recorded[w]?.count ?? 0, goal: postGoal),
             Ring(name: "Posts", count: out[w]?.count ?? 0, goal: postGoal))
        }
        (g.ideas, g.recorded, g.posts) = rings(thisWeek)

        // The streak, walking back from this week (or last week, while this one runs).
        let counted = { (w: Date) in (out[w]?.count ?? 0) >= postGoal }
        let monthOf = { (d: Date) in cal.dateComponents([.year, .month], from: d) }
        var restMonths = Set<DateComponents>()
        g.weekCounted = counted(thisWeek)
        let prev = { (w: Date) in cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w }
        var w = g.weekCounted ? thisWeek : prev(thisWeek)
        for _ in 0..<520 {
            if counted(w) {
                g.streak += 1
                g.chain[w] = .counted
            } else if counted(prev(w)), !restMonths.contains(monthOf(w)) {
                // A rest week: the week before it counted, and it is the month's first.
                restMonths.insert(monthOf(w))
                g.rested = true
                g.chain[w] = .rest
            } else {
                break
            }
            w = prev(w)
        }
        g.restLeft = !restMonths.contains(monthOf(now))

        // Almost there: one or two steps left, touched in the last three weeks.
        let recent = cal.date(byAdding: .day, value: -21, to: now) ?? now
        g.almost = videos
            .filter { !$0.archived && (2...3).contains($0.step) && ($0.active ?? .distantPast) >= recent }
            .sorted { a, b in a.step != b.step ? a.step > b.step : (a.active ?? .distantPast) > (b.active ?? .distantPast) }
            .prefix(3)
            .map { Almost(id: $0.id, title: $0.title, url: $0.url, step: $0.step, readyNoDay: $0.readyNoDay) }

        // Wins: every post with a reach, ranked.
        let posts = videos.flatMap { v in v.out.compactMap { o in o.reach.map { (v: v, platform: o.platform, at: o.at, reach: $0) } } }
            .filter { $0.reach > 0 }
            .sorted { $0.reach > $1.reach }
        let sortedReach = posts.map(\.reach).sorted()
        let median = sortedReach.isEmpty ? 0 : sortedReach[sortedReach.count / 2]
        let d30 = cal.date(byAdding: .day, value: -30, to: now) ?? now
        let d90 = cal.date(byAdding: .day, value: -90, to: now) ?? now
        let best90 = posts.first { $0.at >= d90 }
        let in90 = posts.filter { $0.at >= d90 }.count
        for (rank, p) in posts.enumerated() where p.at >= d30 {
            let label: String
            if rank == 0 && posts.count >= 3 { label = "Your best post ever" }
            else if let b = best90, b.v.id == p.v.id, b.platform == p.platform, in90 >= 3 { label = "Your best post in 90 days" }
            else if rank < 3 && posts.count >= 5 { label = "#\(rank + 1) of your \(posts.count) posts" }
            else if median > 0, posts.count >= 4, Double(p.reach) >= 2 * Double(median) {
                label = String(format: "%.1f× your typical post", Double(p.reach) / Double(median))
            } else { continue }
            g.wins.append(Win(id: p.v.id + "#" + p.platform, title: p.v.title, url: p.v.url, platform: p.platform,
                              reach: p.reach, label: label, at: p.at))
        }
        g.wins = Array(g.wins.sorted { $0.at > $1.at }.prefix(3))

        // Lifetime milestones.
        let reach = posts.reduce(0) { $0 + $1.reach }
        let outVideos = videos.filter { !$0.out.isEmpty }.count
        if reach > 0, let m = milestone("reach", "impressions", reach, reachMarks) { g.milestones.append(m) }
        if outVideos > 0, let m = milestone("videos", outVideos == 1 ? "video out" : "videos out", outVideos, videoMarks) { g.milestones.append(m) }

        return g
    }

    nonisolated static func milestone(_ id: String, _ unit: String, _ total: Int, _ marks: [Int]) -> Milestone? {
        let next = marks.first { $0 > total } ?? (marks.last.map { m in (total / m + 1) * m } ?? total + 1)
        return Milestone(id: id, unit: unit, total: total, passed: marks.last { $0 <= total }, next: next)
    }

    nonisolated private static func newestVideo(_ dir: URL) -> Date? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// One line for the board chat, so it can cheer the right thing.
    var brief: String {
        let r = rings.map { "\($0.name) \($0.count)/\($0.goal)" }.joined(separator: ", ")
        var s = "This week's rings: \(r). Week streak at the posting goal: \(streak)."
        if !almost.isEmpty { s += " One or two steps from out: " + almost.map(\.title).joined(separator: "; ") + "." }
        if let w = wins.first { s += " Latest win: \(w.title), \(w.label.lowercased())." }
        return s
    }
}

// MARK: - Words

/// Warm, short, never a guilt trip.
enum GameWords {
    static func rings(_ g: WeekGame) -> String {
        if g.rings.allSatisfy(\.done) { return "All three rings closed. What a week!" }
        if g.posts.done { return "Posting goal done this week. Nice." }
        let any = g.rings.reduce(0) { $0 + $1.count }
        if any == 0 { return "A fresh week. One idea is a great start." }
        return "Good going this week."
    }

    static func streak(_ g: WeekGame) -> String {
        if g.streak == 0 { return "Reach your posting goal this week to start one" }
        if g.weekCounted { return "This week counts already" }
        let left = max(g.posts.goal - g.posts.count, 0)
        return "\(left) more post\(left == 1 ? "" : "s") this week adds week \(g.streak + 1)"
    }

    static func rest(_ g: WeekGame) -> String {
        if g.rested { return g.restLeft ? "A rest week kept it going" : "This month's rest week kept it going" }
        return g.restLeft ? "1 rest week free this month" : "Rest week used this month"
    }

    static func next(_ a: WeekGame.Almost) -> String {
        if a.step >= 3 { return a.readyNoDay ? "Next: pick a day" : "Next: post it" }
        return "Next: the edit"
    }
}

// MARK: - Seen

/// The wins already celebrated on this Mac.
enum GameSeen {
    private static let winsKey = "planWinsSeen"

    /// The wins not celebrated yet (each is a crown on the chart); marks them seen. The first look
    /// marks all without confetti, so an old library does not explode on day one.
    static func fresh(_ g: WeekGame) -> Bool {
        let ids = Set(g.wins.map(\.id))
        let d = UserDefaults.standard
        let first = d.object(forKey: winsKey) == nil
        let seen = Set(d.stringArray(forKey: winsKey) ?? [])
        let new = ids.subtracting(seen)
        if !new.isEmpty || first { d.set(Array(seen.union(ids)), forKey: winsKey) }
        return !first && !new.isEmpty
    }
}

// MARK: - Views

extension Theme {
    /// The streak and the crown: a warm gold, the same in light and dark.
    static let gold = Color(red: 0.95, green: 0.66, blue: 0.18)
}

/// Five small dots: Idea, Script, Record, Edit, Post. Filled up to the step reached.
struct StepDots: View {
    let step: Int
    var size: CGFloat = 6

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(i <= step ? (step >= 4 ? Theme.live : Theme.accent) : Theme.border)
                    .frame(width: i == step ? size * 2.2 : size, height: size)
            }
        }
        .animation(Theme.spring, value: step)
        .help("Done: " + WeekGame.stepNames.prefix(step + 1).joined(separator: ", "))
    }
}


