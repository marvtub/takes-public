import Foundation
import Testing
@testable import Takes

/// Plan on the iPhone (2026-10-25): what the Mac sends (PlanPhone.snapshot) and what the phone's
/// buttons do. `TAKES_PLAN_FIXTURE=/file.json swift test --filter PlanPhoneTests` writes the stand-in
/// Mac's answers (ios/TakesPhoneUITests/plan-standin.json).
@Suite struct PlanPhoneTests {
    static func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    static func session(_ root: URL, _ name: String, post: [String: String]? = nil) throws {
        let s = root.appending(path: "Proj/\(name)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": name, "createdAt": "2026-09-01T10:00:00Z", "named": true, "takes": []])
            .write(to: s.appending(path: "session.json"))
        if let post { PostFile.write(PostFile.Content(text: "Hook.\n", meta: post), to: s, .linkedin) }
    }

    /// Wed Oct 7 in LA. Tue and Thu, three weeks: one posted card today, a scheduled one, a plain one,
    /// a ready post with a time and no card. The game: two weeks at the goal, a crown on a win.
    static func board(_ root: URL) throws -> (PostingPlan, ConsistencyStats, WeekGame, Date) {
        let now = date("2026-10-07T19:00:00Z")
        let tz = "America/Los_Angeles"
        try session(root, "Why I film on my phone", post: ["status": "posted", "at": "2026-10-07T17:00:00Z", "tz": tz])
        try session(root, "Teleprompter tricks", post: ["status": "scheduled", "at": "2026-10-15T15:02:00Z", "tz": tz])
        try session(root, "Three cheap formats")
        try session(root, "Mic test", post: ["status": "ready", "at": "2026-10-08T15:02:00Z", "tz": tz])
        let plan = PostingPlan(days: ["tue", "thu"], time: "08:02", platforms: ["linkedin"], since: "2026-09-01", weeks: 3,
                               videos: [.init(session: "Proj/Why I film on my phone", day: "2026-10-06"),
                                        .init(session: "Proj/Teleprompter tricks", day: "2026-10-13"),
                                        .init(session: "Proj/Three cheap formats", day: "2026-10-13")])
        PostingPlan.write(root, plan)
        var stats = ConsistencyStats.scan(root, plan: plan, now: now, cal: cal())
        func v(_ id: String, _ at: String, reach: Int? = nil) -> WeekGame.Video {
            var x = WeekGame.Video(id: "Proj/" + id, url: root.appending(path: "Proj/" + id), title: id)
            x.out = [("LinkedIn", date(at), reach)]
            return x
        }
        let game = WeekGame.game([v("a", "2026-09-22T15:00:00Z", reach: 900), v("b", "2026-09-24T15:00:00Z", reach: 1_100),
                                  v("c", "2026-09-29T15:00:00Z", reach: 1_000), v("d", "2026-10-01T15:00:00Z", reach: 1_200),
                                  v("Why I film on my phone", "2026-10-07T17:00:00Z", reach: 4_800)],
                                 plan: plan, now: now, cal: cal())
        for (day, cards) in stats.videos { stats.videos[day] = cards.map { c in var c = c; c.step = game.steps[c.id] ?? 1; return c } }
        return (plan, stats, game, now)
    }

    @Test func snapshotSaysWhatTheBoardSays() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "planphone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (plan, stats, game, now) = try Self.board(root)
        let p = PlanPhone.snapshot(plan, stats, game, now: now, cal: Self.cal())

        #expect(p.plan?.days == ["tue", "thu"] && p.plan?.weeks == 3)
        #expect(p.subtitle == "Tue, Thu at 8:02 AM")
        #expect(p.headline == CoachWords.headline(stats, now: now, cal: Self.cal()))
        #expect(p.rank == 2 && p.level == "The sweet spot" && p.perMonth == "That's 2 posts a week, about 9 a month.")
        // The chart: six weeks back, this week, then the plan's three.
        #expect(p.weeks.count == stats.weeks.count && p.weeks.count == 10 && p.weeks.filter(\.now).count == 1)
        #expect(p.weeks[6].now && p.weeks[6].words.hasPrefix("This week: "))
        #expect(p.goal == 2 && p.note == CoachWords.recording(stats))
        // The streak chain: Sep 20 and Sep 27 at the goal, this week open. The crown on this week's post.
        #expect(p.streak == 2 && p.weeks[4].link == "counted" && p.weeks[5].link == "counted" && p.weeks[6].link == "open")
        #expect(p.streakWords == "1 more post this week adds week 3")
        #expect(p.crown?.week == 6 && p.crown?.session == "Proj/Why I film on my phone" && p.crown?.reach == Num.short(4_800))
        // The weeks: 21 days from today, the cards on their days, the ready post's label, the open days.
        #expect(p.days.count == 21 && p.days[0].label == "Today" && p.days[0].today && !p.days[0].planned)
        #expect(p.days[0].cards.first?.statusText == "Posted" && p.days[0].cards.first?.status == "posted")
        let thu = try #require(p.days.first { $0.day == "2026-10-08" })
        #expect(thu.planned && thu.filled == "Mic test" && thu.cards.isEmpty && !thu.open)
        let tue = try #require(p.days.first { $0.day == "2026-10-13" })
        #expect(tue.label == "Tue 13" && tue.cards.map(\.title) == ["Teleprompter tricks", "Three cheap formats"])
        #expect(tue.cards[0].statusText?.hasPrefix("Scheduled Thu ") == true && tue.cards[1].status == nil && tue.cards[1].step == 1)
        #expect(p.days.first { $0.day == "2026-10-20" }?.open == true)
        #expect(p.stripTitle == "Next 3 weeks" && p.summary.hasPrefix("3 videos planned · "))
        #expect(p.minWeeks == 2 && p.maxWeeks == 12)

        let enc = JSONEncoder()
        #expect(try JSONDecoder().decode(PhonePlan.self, from: enc.encode(p)) == p)
        // Without a plan the page asks for the days.
        do {
            let p = PlanPhone.snapshot(nil, ConsistencyStats(), WeekGame())
            #expect(p.plan == nil && p.subtitle == "Show up on the days you choose" && p.rank == 0)
            #expect(p.days.isEmpty && p.streakWords == "Reach your posting goal this week to start one")
        }
    }

    @Test func chatLinesNameThePlan() {
        let p = PostingPlan(days: ["thu", "tue"], time: "17:33", platforms: ["linkedin", "x"])
        #expect(ConsistencyStore.words(p) == "Tue and Thu at 5:33 PM, on LinkedIn and X")
        #expect(ConsistencyStore.words(PostingPlan(days: ["mon"], time: "08:02", platforms: [])) == "Mon at 8:02 AM")
    }

    @MainActor @Test func phoneButtonsChangeThePlanFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "planphone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func status(_ r: PhoneResponse) -> Int { if case .json(_, let s) = r { return s }; return 0 }
        func settle(_ ok: () -> Bool) async { for _ in 0..<40 where !ok() { try? await Task.sleep(for: .milliseconds(50)) } }

        #expect(status(PlanPhone.act(["action": "save", "days": [], "time": "08:02", "platforms": ["linkedin"]], root: root)) == 400)
        #expect(status(PlanPhone.act(["action": "save", "days": ["tue"], "time": "8am", "platforms": ["linkedin"]], root: root)) == 400)
        #expect(status(PlanPhone.act(["action": "place", "id": "Proj/a", "day": "2026-10-13"], root: root)) == 409)
        #expect(status(PlanPhone.act(["action": "nope"], root: root)) == 400)

        // A plan saved from the phone before the Mac's board was ever shown.
        #expect(status(PlanPhone.act(["action": "save", "days": ["thu", "tue"], "time": "12:07", "platforms": ["x", "linkedin"]], root: root)) == 200)
        await settle { PostingPlan.read(root) != nil }
        let p = try #require(PostingPlan.read(root))
        #expect(p.days == ["tue", "thu"] && p.time == "12:07" && p.platforms == ["linkedin", "x"] && p.since != nil)

        #expect(status(PlanPhone.act(["action": "weeks", "n": 4], root: root)) == 200)
        await settle { PostingPlan.read(root)?.weeks == 4 }
        #expect(PostingPlan.read(root)?.weeks == 4)

        try Self.session(root, "a")
        #expect(status(PlanPhone.act(["action": "place", "id": "Proj/gone", "day": "2026-10-13"], root: root)) == 404)
        #expect(status(PlanPhone.act(["action": "place", "id": "Proj/a", "day": "2026-10-13"], root: root)) == 200)
        await settle { PostingPlan.read(root)?.videos?.isEmpty == false }
        #expect(PostingPlan.read(root)?.videos == [PlannedVideo(session: "Proj/a", day: "2026-10-13")])
        #expect(status(PlanPhone.act(["action": "remove", "id": "Proj/a"], root: root)) == 200)
        await settle { PostingPlan.read(root)?.videos?.isEmpty == true }
        #expect(PostingPlan.read(root)?.videos == [])
    }

    @Test func writeStandIn() throws {
        guard let path = ProcessInfo.processInfo.environment["TAKES_PLAN_FIXTURE"] else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "planphone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (plan, stats, game, now) = try Self.board(root)
        let enc = JSONEncoder()
        func json<T: Encodable>(_ v: T) throws -> Any { try JSONSerialization.jsonObject(with: enc.encode(v)) }
        let choices = ["Why I film on my phone", "Teleprompter tricks", "Three cheap formats", "Mic test", "Office tour"].map {
            PhonePlanChoice(id: "Proj/" + $0, title: $0, project: "Proj", done: false)
        }
        let out: [String: Any] = ["plan": try json(PlanPhone.snapshot(plan, stats, game, now: now, cal: Self.cal())),
                                  "first": try json(PlanPhone.snapshot(nil, ConsistencyStats(), WeekGame())),
                                  "choices": try json(choices)]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: path))
    }
}
