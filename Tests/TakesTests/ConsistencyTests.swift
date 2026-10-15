import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Takes

/// The Consistency plugin: slots, buffer, slots kept and the recording streak, from the plan file,
/// the post files and the takes (2026-10-09).
@Suite struct ConsistencyTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func session(_ root: URL, _ name: String, takes: [String] = [], post: [String: String]? = nil) throws {
        let s = root.appending(path: "Proj/\(name)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let json: [String: Any] = ["title": name, "createdAt": "2026-09-01T10:00:00Z", "named": true,
                                   "takes": takes.enumerated().map { ["number": $0.offset + 1, "kind": "camera",
                                                                      "file": "take-0\($0.offset + 1)-camera.mov", "startedAt": $0.element] }]
        try JSONSerialization.data(withJSONObject: json).write(to: s.appending(path: "session.json"))
        if let post { PostFile.write(PostFile.Content(text: "Hook.\n", meta: post), to: s, .linkedin) }
    }

    @Test func slotsBufferKeptAndStreak() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "consistency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Wed Oct 7, noon in LA. Plan: Tue and Thu since Mon Sep 28.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T19:00:00Z"))
        let plan = PostingPlan(days: ["thu", "tue"], time: "08:02", platforms: ["linkedin"], since: "2026-09-28")
        PostingPlan.write(root, plan)
        try session(root, "live", takes: ["2026-09-16T18:00:00Z", "2026-09-30T18:00:00Z"],
                    post: ["status": "posted", "at": "2026-09-29T15:02:00Z", "tz": "America/Los_Angeles"])
        try session(root, "next", takes: ["2026-10-06T18:00:00Z"],
                    post: ["status": "ready", "at": "2026-10-08T15:02:00Z", "tz": "America/Los_Angeles"])
        try session(root, "waiting", post: ["status": "ready"])
        try session(root, "draft", post: ["status": "draft", "at": "2026-10-13T15:02:00Z"])

        let read = try #require(PostingPlan.read(root))
        #expect(read.days == ["tue", "thu"] && read.since == "2026-09-28")
        let s = ConsistencyStats.scan(root, plan: read, now: now, cal: cal())
        #expect(s.days.count == 14)
        #expect(s.slots.count == 4)                       // Thu 8, Tue 13, Thu 15, Tue 20
        #expect(s.slots[0].filled == ["next"])            // a draft never fills a slot
        #expect(s.buffer == 1)
        #expect(s.readyWithoutTime == ["waiting"])
        #expect(s.due == 3 && s.kept == 1)                // Sep 29, Oct 1, Oct 6
        #expect(s.streak == 2 && s.recordedThisWeek && s.takesThisWeek == 1)
        #expect(CoachWords.headline(s, now: now, cal: cal()) == "Next posting day without a video: Tue, Oct 13.")
    }

    @Test func videoCardsOrderWeeksAndLateCards() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "consistency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Drag order: onto a card goes before it, onto a day goes last, nil takes it off.
        var v = PostingPlan.moved([], "P/a", to: "2026-10-13")
        v = PostingPlan.moved(v, "P/b", to: "2026-10-13")
        v = PostingPlan.moved(v, "P/c", to: "2026-10-13", before: "P/a")
        #expect(v.map(\.session) == ["P/c", "P/a", "P/b"])
        v = PostingPlan.moved(v, "P/c", to: "2026-10-15")
        #expect(v.map(\.session) == ["P/a", "P/b", "P/c"] && v[2].day == "2026-10-15")
        #expect(PostingPlan.moved(v, "P/a", to: nil).map(\.session) == ["P/b", "P/c"])

        // Wed Oct 7 in LA. Cards: one passed (shows on today), two on Tue 13, one past the weeks, one gone.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T19:00:00Z"))
        try session(root, "a"); try session(root, "b"); try session(root, "c"); try session(root, "far")
        let plan = PostingPlan(days: ["tue"], time: "08:02", platforms: ["linkedin"], since: "2026-10-01", weeks: 3,
                               videos: [.init(session: "Proj/a", day: "2026-10-05"), .init(session: "Proj/b", day: "2026-10-13"),
                                        .init(session: "Proj/c", day: "2026-10-13"), .init(session: "Proj/far", day: "2026-10-28"),
                                        .init(session: "Proj/gone", day: "2026-10-13")])
        #expect(PostingPlan(days: ["tue"], time: "08:02", platforms: [], weeks: 40).weekCount == 12)
        PostingPlan.write(root, plan)
        let read = try #require(PostingPlan.read(root))
        #expect(read.videos?.count == 5 && read.weekCount == 3)
        let c = cal()
        let s = ConsistencyStats.scan(root, plan: read, now: now, cal: c)
        #expect(s.days.count == 21 && s.slots.count == 3)
        let today = c.startOfDay(for: now)
        let tue = try #require(c.date(byAdding: .day, value: 6, to: today))
        #expect(s.videos[today]?.map(\.title) == ["a"] && s.videos[today]?.first?.late == true)
        #expect(s.videos[tue]?.map(\.id) == ["Proj/b", "Proj/c"])
        #expect(s.videos.values.joined().count == 3)  // "far" is after the third week, "gone" has no folder
    }

    /// Seven videos planned left the buffer at 0 (2026-10-10): a card covers its slot as planned.
    @Test func plannedVideosCoverTheirSlots() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "consistency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Wed Oct 7 in LA. Slots: Thu 8 (a post), Tue 13 (a card), Thu 15 (open), Tue 20 (a card).
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T19:00:00Z"))
        try session(root, "next", post: ["status": "ready", "at": "2026-10-08T15:02:00Z", "tz": "America/Los_Angeles"])
        try session(root, "flip"); try session(root, "later")
        let plan = PostingPlan(days: ["tue", "thu"], time: "08:02", platforms: ["linkedin"], since: "2026-10-01",
                               videos: [.init(session: "Proj/flip", day: "2026-10-13"), .init(session: "Proj/later", day: "2026-10-20")])
        let s = ConsistencyStats.scan(root, plan: plan, now: now, cal: cal())
        #expect(s.slots.map(\.open) == [false, false, true, false])
        #expect(s.slots[1].planned == ["flip"] && s.slots[1].filled.isEmpty)
        #expect(s.buffer == 2 && s.bufferReady == 1)
        #expect(s.nextOpen?.date == s.slots[2].date)
        #expect(CoachWords.bufferNote(s) == "1 ready, 1 planned")
        #expect(CoachWords.headline(s, now: now, cal: cal()) == "Your next 2 posting days have a video. Next free one: Thu, Oct 15.")
    }

    /// A video the chat marked posted showed no sign of it on the board (2026-10-10). Cards now
    /// show posted or scheduled, a video posted before today leaves, and the chart counts each week.
    @Test func cardsShowTheirPostAndTheChartCountsWeeks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "consistency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Wed Oct 7 in LA. Plan: Tue and Thu, two weeks.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-07T19:00:00Z"))
        let tz = "America/Los_Angeles"
        try session(root, "done", post: ["status": "posted", "at": "2026-10-07T17:00:00Z", "tz": tz])
        try session(root, "old", post: ["status": "posted", "at": "2026-10-02T15:02:00Z", "tz": tz])
        try session(root, "sched", post: ["status": "scheduled", "at": "2026-10-13T15:02:00Z", "tz": tz])
        try session(root, "plain")
        let plan = PostingPlan(days: ["tue", "thu"], time: "08:02", platforms: ["linkedin"], since: "2026-10-01",
                               videos: [.init(session: "Proj/done", day: "2026-10-06"), .init(session: "Proj/old", day: "2026-10-02"),
                                        .init(session: "Proj/sched", day: "2026-10-13"), .init(session: "Proj/plain", day: "2026-10-15")])
        let c = cal()
        let s = ConsistencyStats.scan(root, plan: plan, now: now, cal: c)
        let today = c.startOfDay(for: now)
        let done = try #require(s.videos[today]?.first)
        #expect(done.id == "Proj/done" && done.status == .posted && !done.late)
        #expect(!s.videos.values.joined().contains { $0.id == "Proj/old" })
        let tue = try #require(c.date(byAdding: .day, value: 6, to: today))
        let at = try #require(ISO8601DateFormatter().date(from: "2026-10-13T15:02:00Z"))
        #expect(s.videos[tue]?.first?.status == .scheduled(at))
        #expect(s.slots.first { $0.date == tue }?.filledBy == ["Proj/sched"])
        #expect(s.videos.values.joined().first { $0.id == "Proj/plain" }?.status == nil)

        // Weeks start Sunday: six back, this week (Oct 4), then Oct 11 and Oct 18.
        #expect(s.goal == 2 && s.weeks.count == 9)
        #expect(s.weeks[5].posted == 1)                                   // "old", week of Sep 27
        #expect(s.weeks[6].posted == 1 && s.weeks[6].total == 1)          // "done"
        #expect(s.weeks[7].scheduled == 1 && s.weeks[7].planned == 1)     // "sched", "plain"
        #expect(s.weeks[8].total == 0)
    }

    @Test func offHidesThePlanFromTheChatButKeepsIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "consistency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        PostingPlan.write(root, PostingPlan(days: ["mon"], time: "12:07", platforms: ["linkedin"]))
        PostingPlan.setOff(root, true)
        #expect(PostingPlan.read(root)?.off == true)
        PostingPlan.setOff(root, false)
        #expect(PostingPlan.read(root)?.off == nil)
        #expect(PostingPlan.clock("17:33") == "5:33 PM" && PostingPlan.clock("00:05") == "12:05 AM")
        #expect(PostingPlan.validTime("09:41") && !PostingPlan.validTime("9:41") && !PostingPlan.validTime("24:00"))
    }

    @Test func pickerFindsSessionsByTitleAndProject() {
        let d = Date()
        let list = [PlanChoice(id: "Launch/a", title: "Kebab shop demo", project: "Launch", createdAt: d, done: false),
                    PlanChoice(id: "Posts/b", title: "Morning routine", project: "Posts", createdAt: d, done: true)]
        #expect(PlanChoice.matching(list, "").count == 2)
        #expect(PlanChoice.matching(list, "kebab").map(\.id) == ["Launch/a"])
        #expect(PlanChoice.matching(list, "posts morning").map(\.id) == ["Posts/b"])
        #expect(PlanChoice.matching(list, "kebab posts").isEmpty)
    }

    /// The board keeps its store between visits, so a second visit shows the plan at once.
    @MainActor @Test func boardKeepsItsStoreBetweenVisits() {
        let a = URL(fileURLWithPath: "/tmp/plan-a"), b = URL(fileURLWithPath: "/tmp/plan-b")
        let store = ConsistencyStore.shared(a)
        #expect(ConsistencyStore.shared(a) === store)
        #expect(ConsistencyStore.shared(b) !== store)
    }

    @Test func flameGrowsWithTheDays() {
        #expect(FireLevel(days: 0).name == "Pick a day to start")
        #expect(FireLevel(days: 0).opacity == 0)
        #expect(FireLevel(days: 2).name == "The sweet spot")
        #expect(FireLevel(days: 3).name == "On fire")
        #expect(FireLevel(days: 7) == FireLevel(days: 4))
        #expect(FireLevel(days: 7).name == "Super Takes")
        #expect((0...6).map { FireLevel(days: $0).scale } == (0...6).map { FireLevel(days: $0).scale }.sorted())
    }
}

extension Snap {
    /// The commitment card and the board with a plan.
    @Test(.enabled(if: snapDir != nil)) func consistencyBoard() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        revealAtOnce = true
        defer { revealAtOnce = false }
        let empty = ConsistencyStore()
        empty.loaded = true
        shoot("consistency-commit", ConsistencyPage(store: empty, root: root), size: CGSize(width: 1100, height: 820))

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let store = ConsistencyStore()
        store.loaded = true
        store.plan = PostingPlan(days: ["tue", "thu"], time: "08:02", platforms: ["linkedin"], since: "2026-09-28")
        var s = ConsistencyStats()
        for i in 0..<14 {
            let d = cal.date(byAdding: .day, value: i, to: today)!
            let planned = ["tue", "thu"].contains(PostingPlan.weekday(d, cal))
            s.days.append((d, planned))
            if planned { s.slots.append(.init(date: d, filled: s.slots.count < 2 ? [s.slots.isEmpty ? "WebMCP in 60 seconds" : "Bookkeeping with Claude"] : [])) }
        }
        s.buffer = 2
        s.readyWithoutTime = ["Your first video"]
        s.streak = 3; s.recordedThisWeek = true; s.takesThisWeek = 7
        s.kept = 5; s.due = 6
        let card = { (t: String) in ConsistencyStats.Card(id: "P/\(t)", title: t, url: root, poster: nil) }
        s.videos[s.slots[2].date] = [card("Open models flip"), card("Second Takes video")]
        s.videos[s.days[5].date] = [card("AI tutorial reaction")]
        var posted = card("Bookkeeping agent"); posted.status = .posted
        s.videos[today] = [posted]
        var sched = card("Bezos AI opportunities")
        sched.status = .scheduled(cal.date(bySettingHour: 8, minute: 2, second: 0, of: s.slots[3].date)!)
        s.videos[s.slots[3].date] = [sched]
        s.goal = 2
        let week = cal.dateInterval(of: .weekOfYear, for: today)!.start
        s.weeks = (-6...1).map { i in
            var w = ConsistencyStats.WeekCount(start: cal.date(byAdding: .weekOfYear, value: i, to: week)!)
            w.posted = i < 0 ? [1, 2, 0, 2, 3, 1][i + 6] : i == 0 ? 2 : 0
            w.scheduled = i == 0 ? 1 : i == 1 ? 1 : 0
            w.planned = i == 0 ? 1 : i == 1 ? 2 : 0
            return w
        }
        store.stats = s
                // Change days: the flame at each level, with the two-week preview.
        let mascot = NSImage(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../assets/brand/mascot.png").standardized)
        for dark in [true, false] {
            shoot("consistency-board-\(dark ? "dark" : "light")", ConsistencyPage(store: store, root: root, mascot: mascot),
                  size: CGSize(width: 1100, height: 820), dark: dark)
        }
        for (name, days) in [("1", ["tue"]), ("2", ["tue", "thu"]), ("3", ["tue", "thu", "fri"]), ("5", ["mon", "tue", "wed", "thu", "fri"])] {
            let plan = PostingPlan(days: days, time: "08:02", platforms: ["linkedin"])
            for dark in [true, false] {
                shoot("consistency-edit-\(name)-\(dark ? "dark" : "light")",
                      ScrollView { CommitCard(start: plan, first: false, preview: s, mascot: mascot) { _ in } cancel: {}.padding(28) }
                        .background(Theme.paper),
                      size: CGSize(width: 900, height: 940), dark: dark)
            }
        }
        let d = Date()
        let choices = [PlanChoice(id: "Launch/a", title: "Kebab shop demo", project: "Launch", createdAt: d, done: false),
                       PlanChoice(id: "Launch/b", title: "Why I record every morning", project: "Launch", createdAt: d, done: false),
                       PlanChoice(id: "Posts/c", title: "Three hooks that worked", project: "Posts", createdAt: d, done: true)]
        shoot("consistency-picker", PlanPicker(choices: choices, planned: ["Launch/b"]) { _ in }, size: CGSize(width: 300, height: 260))
    }
}

// 2026-10-11: the Plan and Feedback boards rescanned the whole library on every file change.
struct BoardRefreshTests {
    let root = URL(fileURLWithPath: "/L")

    @Test func planBoardCountsOnlyTheFilesItReads() {
        func m(_ p: String) -> Bool { ConsistencyStore.matters(["/L/" + p], root: root) }
        #expect(m("_library/plan.json"))
        #expect(m("P/2026-10-01-a/session.json"))
        #expect(m("P/2026-10-01-a/posts/linkedin.md"))
        #expect(m("P/2026-10-01-a/edits/cut-v2.mp4"))
        #expect(m("P/2026-10-02-new"))
        #expect(!m("P/2026-10-01-a/.claude-chat.json"))
        #expect(!m("P/2026-10-01-a/comments.json"))
        #expect(!m("P/2026-10-01-a/stills/a.png"))
        #expect(!m("P/2026-10-01-a/edits/.tmp-cut.mp4"))
        #expect(!m("_library/rules/edit.json"))
    }

    @Test func feedbackBoardCountsCommentsAndRules() {
        func m(_ p: String) -> Bool { FeedbackStore.matters(["/L/" + p], root: root) }
        #expect(m("_library/rules/edit.json"))
        #expect(m("P/2026-10-01-a/comments.json"))
        #expect(m("P/2026-10-01-a/checks.json"))
        #expect(!m("P/2026-10-01-a/posts/linkedin.md"))
        #expect(!m("_library/plan.json"))
    }
}
