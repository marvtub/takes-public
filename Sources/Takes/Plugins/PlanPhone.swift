import Foundation

// The Plan board on the iPhone (2026-10-25): the same words, chart, streak chain, crown and weeks as
// the Mac's board (Consistency.swift, PlanWeeks.swift, PlanGame.swift), sent ready to draw. The phone's
// buttons call the store's own functions, so each writes the same line in the Plan chat. The phone
// side is ios/TakesPhone/PlanView.swift. Public.

/// What the phone's Plan screen draws. `plan` nil: no plan yet, the phone shows the commitment.
struct PhonePlan: Codable, Equatable {
    struct Plan: Codable, Equatable {
        var days: [String]
        var time: String
        var platforms: [String]
        var weeks: Int
    }

    /// A week of the chart, with its link in the streak chain: "counted", "rest", "open" (this week,
    /// still open, in a running streak) or nil.
    struct Week: Codable, Equatable {
        var label: String
        var now: Bool
        var posted: Int
        var scheduled: Int
        var planned: Int
        /// What hovering it says on the Mac: "Week of Oct 12: 2 posted".
        var words: String
        var link: String?
    }

    /// The best recent post, over its week's bar.
    struct Crown: Codable, Equatable {
        var week: Int
        var title: String
        var label: String
        var reach: String
        var platform: String
        var session: String
    }

    struct Card: Codable, Equatable {
        /// "Project/folder": the phone's session id too.
        var id: String
        var title: String
        /// The poster's path on the Mac, for /api/thumb.
        var poster: String?
        /// "posted", "scheduled" or nil.
        var status: String?
        /// "Posted", "Scheduled 9:41 AM", "Scheduled Thu 9:41 AM".
        var statusText: String?
        /// 0 Idea ... 4 Post.
        var step: Int?
        var late: Bool
    }

    struct Day: Codable, Equatable {
        /// "yyyy-MM-dd": what place sends back.
        var day: String
        /// "Today", "Tue 27".
        var label: String
        var today: Bool
        /// A posting day.
        var planned: Bool
        var cards: [Card]
        /// Posts on this day whose video has no card, as the mint label.
        var filled: String?
        /// A posting day with nothing on it.
        var open: Bool
    }

    var plan: Plan?
    /// "Tue, Thu at 8:02 AM", or the line before a plan.
    var subtitle: String
    var headline: String
    /// The flame: 0 none ... 4 Super Takes, and its name.
    var rank: Int
    var level: String
    var perMonth: String

    var goal: Int
    var weeks: [Week]
    var note: String
    var streak: Int
    /// The right side of "Videos per week": what adds the next week.
    var streakWords: String
    /// The streak pill's help: the rest week.
    var restWords: String
    var crown: Crown?

    var stripTitle: String
    var summary: String
    var days: [Day]
    var weekCount: Int
    var minWeeks: Int
    var maxWeeks: Int
    var ready: [String]
}

/// A session the phone can put on a day (a day's +).
struct PhonePlanChoice: Codable, Equatable {
    var id: String
    var title: String
    var project: String
    var done: Bool
}

enum PlanPhone {
    static let hook = PhoneHook { req, root in
        switch (req.method, req.path) {
        case ("GET", "/api/plan"):
            if req.query["choices"] != nil {
                return await MainActor.run { () -> PhoneResponse in
                    let list = Consistency.app.map { PlanChoice.all($0.library) } ?? []
                    return .encode(list.map { PhonePlanChoice(id: $0.id, title: $0.title, project: $0.project, done: $0.done) })
                }
            }
            // ?days=tue,thu&time=08:02&platforms=linkedin: Change days' preview of where the videos land.
            let draft = req.query["days"].map { d in
                PostingPlan(days: d.split(separator: ",").map(String.init), time: req.query["time"] ?? PostingPlan.times[0].value,
                            platforms: (req.query["platforms"] ?? "linkedin").split(separator: ",").map(String.init))
            }
            let saved = PostingPlan.read(root)
            let shown = draft.map { d -> PostingPlan in var p = saved ?? d; p.days = d.days; p.time = d.time; p.platforms = d.platforms; p.weeks = nil; return p } ?? saved
            let scanned = await Task.detached(priority: .userInitiated) { () -> (ConsistencyStats, WeekGame)? in
                guard let shown else { return nil }
                var stats = ConsistencyStats.scan(root, plan: shown)
                let game = WeekGame.scan(root, plan: shown)
                for (day, cards) in stats.videos { stats.videos[day] = cards.map { c in var c = c; c.step = game.steps[c.id]; return c } }
                return (stats, game)
            }.value
            return .encode(snapshot(shown, scanned?.0 ?? ConsistencyStats(), scanned?.1 ?? WeekGame()))
        case ("POST", "/api/plan"):
            // {"action": "save", "days": [...], "time", "platforms": [...]} Save on Change days;
            // {"action": "place", "id", "day", "before"?} a day's + or Move to; {"action": "remove", "id"};
            // {"action": "weeks", "n"} Add a week and Show less.
            let j = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            return await MainActor.run { act(j, root: root) }
        default:
            return nil
        }
    }

    @MainActor static func act(_ j: [String: Any], root: URL) -> PhoneResponse {
        let store = ConsistencyStore.shared(root)
        switch j["action"] as? String {
        case "save":
            let days = PostingPlan.weekdays.filter(Set(j["days"] as? [String] ?? []).contains)
            let time = j["time"] as? String ?? ""
            let platforms = (j["platforms"] as? [String] ?? []).filter { PostPlatform(rawValue: $0) != nil }
            guard !days.isEmpty else { return .error(400, "Pick at least one day.") }
            guard PostingPlan.validTime(time) else { return .error(400, "That time does not work. Use 24-hour, like 09:41.") }
            guard !platforms.isEmpty else { return .error(400, "Pick at least one place to post.") }
            store.save(root, PostingPlan(days: days, time: time, platforms: platforms.sorted()))
        case "place":
            guard let id = j["id"] as? String, let day = (j["day"] as? String).flatMap({ ConsistencyStats.parseDay($0) }) else {
                return .error(400, "Which video and which day?")
            }
            guard PostingPlan.read(root) != nil else { return .error(409, "Set your posting days first.") }
            guard store.stats.videos.values.joined().contains(where: { $0.id == id }) || ConsistencyStats.card(root, id) != nil else {
                return .error(404, "That video is gone from the Mac.")
            }
            store.place(root, id, on: day, before: j["before"] as? String)
        case "remove":
            guard let id = j["id"] as? String else { return .error(400, "Which video?") }
            store.remove(root, id)
        case "weeks":
            guard let n = (j["n"] as? Int) ?? (j["n"] as? String).flatMap(Int.init) else { return .error(400, "How many weeks?") }
            store.setWeeks(root, n)
        default:
            return .error(400, "Takes does not know that button.")
        }
        return .encode(["ok": true])
    }

    /// The board as the Mac draws it from this plan, stats and game.
    static func snapshot(_ plan: PostingPlan?, _ stats: ConsistencyStats, _ game: WeekGame, now: Date = Date(), cal: Calendar = .current) -> PhonePlan {
        let level = FireLevel(days: plan?.days.count ?? 0)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start
        let open = game.streak > 0 && !game.weekCounted ? thisWeek : nil
        let weeks = stats.weeks.map { w in
            let link: String? = switch game.chain[w.start] {
            case .counted: "counted"
            case .rest: "rest"
            case nil: w.start == open ? "open" : nil
            }
            return PhonePlan.Week(label: PlanWeeks.label(w.start), now: w.start == thisWeek, posted: w.posted, scheduled: w.scheduled,
                                  planned: w.planned, words: PlanWeeks.words(w, now: w.start == thisWeek), link: link)
        }
        var crown: PhonePlan.Crown?
        if let w = game.wins.first, let week = cal.dateInterval(of: .weekOfYear, for: w.at)?.start,
           let i = stats.weeks.firstIndex(where: { $0.start == week }) {
            crown = PhonePlan.Crown(week: i, title: w.title, label: w.label, reach: Num.short(w.reach), platform: w.platform,
                                    session: w.url.deletingLastPathComponent().lastPathComponent + "/" + w.url.lastPathComponent)
        }
        let onPlan = Set(stats.videos.values.flatMap { $0.map(\.id) })
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        let days = stats.days.map { d -> PhonePlan.Day in
            let cards = (stats.videos[d.date] ?? []).map { c in card(c, day: d.date, cal: cal) }
            let slot = stats.slots.first { $0.date == d.date }
            var filled: String?
            if let slot {
                let shown = onPlan.union(cards.map(\.id))
                let others = slot.filled.indices.filter { $0 >= slot.filledBy.count || !shown.contains(slot.filledBy[$0]) }.map { slot.filled[$0] }
                if !others.isEmpty { filled = others.joined(separator: ", ") }
            }
            let today = cal.isDate(d.date, inSameDayAs: now)
            return PhonePlan.Day(day: PostingPlan.day(d.date), label: today ? "Today" : f.string(from: d.date), today: today,
                                 planned: d.planned, cards: cards, filled: filled,
                                 open: slot.map { $0.filled.isEmpty && cards.isEmpty } ?? false)
        }
        let n = stats.videos.values.reduce(0) { $0 + $1.count }
        let slots = "\(stats.slots.filter { !$0.open }.count) of \(stats.slots.count) posting days have a video"
        let count = plan?.weekCount ?? 2
        let subtitle = plan.map { p in
            p.days.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ", ") + " at " + PostingPlan.clock(p.time)
        } ?? "Show up on the days you choose"
        return PhonePlan(
            plan: plan.map { PhonePlan.Plan(days: $0.days, time: $0.time, platforms: $0.platforms, weeks: $0.weekCount) },
            subtitle: subtitle, headline: CoachWords.headline(stats, now: now, cal: cal), rank: level.rank, level: level.name,
            perMonth: plan.map { CoachWords.perMonth($0.days.count) } ?? CoachWords.forCount(0),
            goal: stats.goal, weeks: weeks, note: CoachWords.recording(stats), streak: game.streak,
            streakWords: GameWords.streak(game), restWords: GameWords.rest(game) + ". Miss a week? One rest week a month keeps your streak.",
            crown: crown,
            stripTitle: count == 2 ? "Next two weeks" : "Next \(count) weeks",
            summary: n == 0 ? slots : "\(n) video\(n == 1 ? "" : "s") planned · " + slots,
            days: days, weekCount: count, minWeeks: PostingPlan.weekRange.lowerBound, maxWeeks: PostingPlan.weekRange.upperBound,
            ready: stats.readyWithoutTime)
    }

    static func card(_ c: ConsistencyStats.Card, day: Date, cal: Calendar) -> PhonePlan.Card {
        var status: String?, text: String?
        switch c.status {
        case .posted:
            status = "posted"; text = "Posted"
        case .scheduled(let at):
            let other = !cal.isDate(day, inSameDayAs: at)
            status = "scheduled"
            text = "Scheduled \(other ? at.formatted(.dateTime.weekday(.abbreviated)) + " " : "")\(at.formatted(date: .omitted, time: .shortened))"
        case nil: break
        }
        return PhonePlan.Card(id: c.id, title: c.title, poster: c.poster?.path, status: status, statusText: text, step: c.step, late: c.late)
    }
}
