import Foundation
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct FeedbackTests {
    private func library() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "feedback-\(UUID().uuidString)")
        let s = root.appending(path: "Proj/2026-10-01-a")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        return (root, s)
    }

    /// Comments, lessons, repeats and checks add up; a video counts in the week of its first comment.
    @Test func statsCount() throws {
        let (root, s) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let iso = ISO8601DateFormatter()
        let recent = iso.string(from: now.addingTimeInterval(-3 * 86_400))
        let old = iso.string(from: now.addingTimeInterval(-40 * 86_400))
        CommentStore.change(s) { f in
            f.comments = [
                Comment(id: "c1", file: "edits/a-v1.mp4", text: "a", status: "resolved", by: "user", at: recent, lesson: "cut-1"),
                Comment(id: "c2", file: "edits/a-v1.mp4", text: "b", status: "resolved", by: "user", at: recent, lesson: "cut-1", repeat: true),
                Comment(id: "c3", file: "edits/a-v1.mp4", text: "c", status: "resolved", by: "user", at: recent, lesson: "one-off"),
                Comment(id: "c4", file: "edits/a-v1.mp4", text: "reply", status: "open", by: "claude", at: recent),
            ]
        }
        let s2 = root.appending(path: "Proj/2026-09-01-b")
        try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)
        CommentStore.change(s2) { f in
            f.comments = (1...5).map { Comment(id: "c\($0)", file: "edits/b.mp4", text: "x", status: "resolved", by: "user", at: old) }
        }
        try Data(#"{"edits/a-v1.mp4": {"at": "x", "results": [{"rule": "cut-1", "pass": false}, {"rule": "sound-1", "pass": true}]}}"#.utf8)
            .write(to: s.appending(path: "checks.json"))
        // _library is not a session.
        try FileManager.default.createDirectory(at: root.appending(path: "_library/x"), withIntermediateDirectories: true)

        let rules = [LearnedRule(id: "cut-1", area: "cut", text: "Short pauses.", made: iso.string(from: now.addingTimeInterval(-10 * 86_400)))]
        let st = FeedbackStats.scan(root, rules: rules, now: now)
        #expect(st.comments == 8)
        #expect(st.videos == 2)
        #expect(st.learned == 2)
        #expect(st.oneOff == 1)
        #expect(st.repeats == 1)
        #expect(st.checksRun == 1)
        #expect(st.checksCaught == 1)
        #expect(st.builtinCaught == 0)
        #expect(st.recent == 3)
        #expect(st.before == 5)
        #expect(st.weeks.count == 12)
        #expect(st.weeks.map(\.comments).reduce(0, +) == 8)
        #expect(st.unlabeled == 0)
    }

    /// Built-in check failures (2026-10-11) count apart from the rules'; old entries count as before.
    @Test func builtinChecksCountApart() throws {
        let (root, s) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"""
        {"edits/a-v1.mp4": {"at": "x", "results": [{"rule": "cut-1", "pass": false}]},
         "edits/a-v2.mp4": {"v": 2, "mtime": 1, "results": [{"check": "echo", "pass": false, "label": "Echo"},
           {"check": "words", "pass": null, "skip": "x"}, {"check": "streams", "pass": true},
           {"rule": "sound-1", "text": "Loud.", "pass": false}]}}
        """#.utf8).write(to: s.appending(path: "checks.json"))
        let st = FeedbackStats.scan(root, rules: [])
        #expect(st.checksRun == 2)
        #expect(st.checksCaught == 2)
        #expect(st.builtinCaught == 1)
    }

    /// A rule from the board is yours; an edit makes an agent's rule yours; a full area takes no more.
    @Test func editRules() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        Lessons.change(root) { f in
            f.rules = [LearnedRule(id: "cut-1", area: "cut", text: "Old.", on: true, by: "takes", made: "2026-10-01T00:00:00Z", from: ["P/s#c1"], repeats: [])]
        }
        Lessons.edit(root, "cut-1") { $0.text = "New." }
        var r = Lessons.read(root).rules[0]
        #expect(r.text == "New.")
        #expect(r.yours)
        #expect(r.from == ["P/s#c1"])
        let added = Lessons.add(root, area: "cut", text: "  Two   words. ")
        #expect(added?.id == "cut-2")
        #expect(added?.text == "Two words.")
        for i in 0..<20 { Lessons.add(root, area: "sound", text: "Rule \(i).") }
        #expect(Lessons.read(root).rules.filter { $0.area == "sound" }.count == Feedback.areaMax)
        Lessons.delete(root, "cut-1")
        #expect(Lessons.read(root).rules.filter { $0.area == "cut" }.map(\.id) == ["cut-2"])
        // One file per area.
        #expect(FileManager.default.fileExists(atPath: Lessons.file(root, area: "sound").path))
        #expect(!FileManager.default.fileExists(atPath: Lessons.file(root, area: "post-x").path))
    }

    /// The one lessons.json splits into a file per area, once, and the old Post rules go to their platform.
    @Test func oldFileSplits() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "_library"), withIntermediateDirectories: true)
        try Data(#"{"rules": [{"id": "cut-1", "area": "cut", "text": "a"}, {"id": "post-1", "area": "post", "text": "b"}, {"id": "post-3", "area": "post", "text": "c"}]}"#.utf8)
            .write(to: Lessons.oldFile(root))
        let areas = Dictionary(uniqueKeysWithValues: Lessons.read(root).rules.map { ($0.id, $0.area) })
        #expect(areas == ["cut-1": "cut", "post-1": "post-linkedin", "post-3": "post-all"])
        #expect(!FileManager.default.fileExists(atPath: Lessons.oldFile(root).path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "_library/lessons-before-split.json").path))
    }

    /// A rule file with a typo is left as it is when the board writes the others.
    @Test func brokenFileIsNeverEmptied() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        Lessons.add(root, area: "cut", text: "Tight.")
        let bad = Lessons.file(root, area: "sound")
        try "{\"rules\": [ oops".write(to: bad, atomically: true, encoding: .utf8)
        Lessons.add(root, area: "cut", text: "Cut on the breath.")
        #expect((try? String(contentsOf: bad, encoding: .utf8)) == "{\"rules\": [ oops")
        #expect(Lessons.read(root).rules.filter { $0.area == "cut" }.count == 2)
    }

    /// The copilot's lessons move next to the other rules.
    @Test func copilotLessonsMove() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = CopilotStore.folder(root).appending(path: "lessons.md")
        try FileManager.default.createDirectory(at: CopilotStore.folder(root), withIntermediateDirectories: true)
        try "- No polish.".write(to: old, atomically: true, encoding: .utf8)
        let now = CopilotStore.lessons(root)
        #expect(now.lastPathComponent == "comments.md" && now.deletingLastPathComponent().lastPathComponent == "rules")
        #expect((try? String(contentsOf: now, encoding: .utf8)) == "- No polish.")
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// Comments keep their lesson when the app writes the file (a reply from the app, say).
    @Test func lessonSurvivesAppWrite() throws {
        let (root, s) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"comments": [{"id": "c1", "file": "a.mp4", "text": "x", "status": "resolved", "by": "user", "at": "2026-10-01T00:00:00Z", "lesson": "cut-1", "repeat": true}]}"#.utf8)
            .write(to: CommentStore.file(s))
        CommentStore.change(s) { $0.comments[0].text = "y" }
        let c = CommentStore.read(s).comments[0]
        #expect(c.lesson == "cut-1")
        #expect(c.repeat == true)
    }

    /// Ten counting cut rules from Takes, and cut-11 waiting to merge into cut-3.
    private func fullCut(_ root: URL, by: String = "takes", was: String? = "Rule 3.") {
        Lessons.change(root) { f in
            f.rules = (1...10).map { LearnedRule(id: "cut-\($0)", area: "cut", text: "Rule \($0).", on: true, by: $0 == 3 ? by : "takes",
                                                 made: "2026-10-01T00:00:00Z", from: ["P/s#c\($0)"], repeats: $0 == 3 ? ["P/s#r1"] : []) }
            f.rules.append(LearnedRule(id: "cut-11", area: "cut", text: "Cut the breath.", on: true, by: "takes",
                                       made: "2026-10-10T00:00:00Z", from: ["P/s#c11"], repeats: ["P/s#r2"],
                                       merge: RuleMerge(into: "cut-3", text: "Rule 3, and cut the breath.", was: was)))
        }
    }

    private func rule(_ root: URL, _ id: String) -> LearnedRule? { Lessons.read(root).rules.first { $0.id == id } }

    /// The MCP's new fields stay when the board writes the file.
    @Test func newFieldsSurviveAppWrite() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: Lessons.folder(root), withIntermediateDirectories: true)
        try Data(#"""
        {"rules": [{"id": "cut-1", "area": "cut", "text": "A.", "details": "More words."},
                   {"id": "cut-2", "area": "cut", "text": "B.", "merge": {"into": "cut-1", "text": "A and B.", "was": "A."}},
                   {"id": "cut-3", "area": "cut", "text": "C.", "on": false, "merged_into": "cut-1"},
                   {"id": "cut-4", "area": "cut", "text": "D."}]}
        """#.utf8).write(to: Lessons.file(root, area: "cut"))
        Lessons.edit(root, "cut-4") { $0.text = "E." }
        let raw = try String(contentsOf: Lessons.file(root, area: "cut"), encoding: .utf8)
        #expect(raw.contains("\"details\" : \"More words.\""))
        #expect(raw.contains("\"merged_into\" : \"cut-1\""))
        #expect(raw.contains("\"was\" : \"A.\""))
        #expect(rule(root, "cut-2")?.merge == RuleMerge(into: "cut-1", text: "A and B.", was: "A."))
    }

    /// Merge: the other rule gets the merged text and the comments, keeps its owner; this one turns off.
    @Test func mergeMovesTextAndHidesTheOld() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root, by: "you")
        Lessons.merge(root, "cut-11")
        let target = try #require(rule(root, "cut-3")), source = try #require(rule(root, "cut-11"))
        #expect(target.text == "Rule 3, and cut the breath.")
        #expect(target.from == ["P/s#c3", "P/s#c11"])
        #expect(target.repeats == ["P/s#r1", "P/s#r2"])
        #expect(target.by == "you")
        #expect(target.changed != nil)
        #expect(!source.isOn && source.mergedInto == "cut-3" && source.merge == nil)
        #expect(!Lessons.shown(Lessons.read(root).rules).contains { $0.id == "cut-11" })
        #expect(Lessons.read(root).rules.filter { $0.area == "cut" && $0.counts }.count == 10)
    }

    @Test func keepBothClearsTheSuggestion() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root)
        Lessons.keepBoth(root, "cut-11")
        let source = try #require(rule(root, "cut-11"))
        #expect(source.merge == nil && source.isOn && source.mergedInto == nil)
        #expect(rule(root, "cut-3")?.text == "Rule 3.")
        #expect(Lessons.read(root).rules.filter { $0.area == "cut" && $0.counts }.count == 11)
    }

    /// The other rule deleted or off: Merge leaves the file as it was.
    @Test func mergeWithTargetGoneDoesNothing() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root)
        Lessons.edit(root, "cut-3") { $0.on = false }
        var before = try Data(contentsOf: Lessons.file(root, area: "cut"))
        Lessons.merge(root, "cut-11")
        #expect(try Data(contentsOf: Lessons.file(root, area: "cut")) == before)
        Lessons.delete(root, "cut-3")
        before = try Data(contentsOf: Lessons.file(root, area: "cut"))
        Lessons.merge(root, "cut-11")
        #expect(try Data(contentsOf: Lessons.file(root, area: "cut")) == before)
    }

    /// The other rule changed after Takes wrote the merged sentence: Merge does nothing.
    @Test func mergeWithTargetChangedDoesNothing() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root, was: "An older rule 3.")
        let before = try Data(contentsOf: Lessons.file(root, area: "cut"))
        #expect(Lessons.mergeTarget(try #require(rule(root, "cut-11")), in: Lessons.read(root).rules) == nil)
        Lessons.merge(root, "cut-11")
        #expect(try Data(contentsOf: Lessons.file(root, area: "cut")) == before)
    }

    /// The other rule changed since, but you saw both and approved the words: the merge goes in,
    /// and words you changed make the rule yours (2026-10-14: the board offered only Keep both).
    @Test func mergeWithApprovedWords() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root, was: "An older rule 3.")
        Lessons.merge(root, "cut-11", text: "Rule 3, and no breath.")
        let target = try #require(rule(root, "cut-3")), source = try #require(rule(root, "cut-11"))
        #expect(target.text == "Rule 3, and no breath.")
        #expect(target.by == "you")
        #expect(!source.isOn && source.mergedInto == "cut-3" && source.merge == nil)
        // Off is still off: approved words do not bring back a rule you turned off.
        let (root2, _) = try library()
        defer { try? FileManager.default.removeItem(at: root2) }
        fullCut(root2)
        Lessons.edit(root2, "cut-3") { $0.on = false }
        let before = try Data(contentsOf: Lessons.file(root2, area: "cut"))
        Lessons.merge(root2, "cut-11", text: "Rule 3, and no breath.")
        #expect(try Data(contentsOf: Lessons.file(root2, area: "cut")) == before)
    }

    /// Undo puts a deleted rule back where it was; a move gives the rule a new id in its new area.
    @Test func restoreAndMove() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try #require(Lessons.add(root, area: "cut", text: "First."))
        let b = try #require(Lessons.add(root, area: "cut", text: "Second."))
        _ = Lessons.add(root, area: "cut", text: "Third.")
        Lessons.delete(root, b.id)
        Lessons.restore(root, b, before: "cut-3")
        #expect(Lessons.read(root).rules.map(\.text) == ["First.", "Second.", "Third."])
        Lessons.restore(root, b, before: nil)
        #expect(Lessons.read(root).rules.count == 3)
        Lessons.move(root, a.id, to: "sound")
        let moved = try #require(Lessons.read(root).rules.first { $0.text == "First." })
        #expect(moved.id == "sound-1" && moved.area == "sound" && moved.by == "you")
        #expect(FileManager.default.fileExists(atPath: Lessons.file(root, area: "sound").path))
    }

    @Test func wordDiffMarksAddedAndRemoved() {
        let d = Lessons.wordDiff("Keep pauses short, about 0.2 s.", "Keep pauses short and cut the breath.")
        #expect(d.map(\.kind) == [.same, .removed, .added])
        #expect(d[0].words == "Keep pauses short")
        #expect(Lessons.wordDiff("", "New words").map(\.kind) == [.added])
    }

    /// A waiting or merged rule does not count toward the 10: the board and the MCP agree.
    @Test func countsSkipsWaitingAndMerged() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        fullCut(root)
        #expect(Lessons.add(root, area: "cut", text: "One more.") == nil)
        Lessons.delete(root, "cut-10")
        Lessons.change(root) { f in
            f.rules.append(LearnedRule(id: "cut-12", area: "cut", text: "Old.", on: false, mergedInto: "cut-1"))
            f.rules.append(LearnedRule(id: "cut-13", area: "cut", text: "Waits too.", on: true,
                                       merge: RuleMerge(into: "cut-2", text: "Both.", was: "Rule 2.")))
        }
        #expect(Lessons.add(root, area: "cut", text: "One more.")?.id == "cut-14")
    }

    @Test func detailsEditAndClear() throws {
        let (root, _) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        Lessons.add(root, area: "cut", text: "Tight.")
        Lessons.edit(root, "cut-1") { $0.details = "x" }
        #expect(rule(root, "cut-1")?.details == "x")
        Lessons.edit(root, "cut-1") { $0.details = nil }
        #expect(!(try String(contentsOf: Lessons.file(root, area: "cut"), encoding: .utf8)).contains("details"))
    }
}

extension Snap {
    /// The Feedback board with counts, the weekly chart and a few rules.
    @Test(.enabled(if: snapDir != nil)) func feedbackBoard() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        revealAtOnce = true
        defer { revealAtOnce = false }
        let store = FeedbackStore()
        store.loaded = true
        store.rules = [
            LearnedRule(id: "cut-1", area: "cut", text: "Pauses 0.15–0.25 s between sentences, about 0.14 s inside one.",
                        on: true, by: "takes", made: "2026-09-20T00:00:00Z", from: ["a", "b", "c"], repeats: ["d"],
                        check: RuleCheck(kind: "pauses", max: 0.25)),
            LearnedRule(id: "cut-2", area: "cut", text: "Never clip a word end: end a piece after a final t, k or p.",
                        on: true, by: "takes", made: "2026-09-22T00:00:00Z", from: ["a", "b"], repeats: []),
            LearnedRule(id: "cut-3", area: "cut", text: "Cut the breath before the hook.", on: true, by: "takes",
                        made: "2026-10-10T00:00:00Z", from: ["e"], repeats: [],
                        merge: RuleMerge(into: "cut-1", text: "Pauses 0.15–0.25 s between sentences, and no breath before the hook.",
                                         was: "Pauses 0.15–0.25 s between sentences, about 0.14 s inside one.")),
            LearnedRule(id: "sound-1", area: "sound", text: "Voice to −14 LUFS, peak at −1 dBTP.", on: true, by: "you",
                        made: "2026-09-25T00:00:00Z", from: [], repeats: [], check: RuleCheck(kind: "loudness", target: -14, tolerance: 1),
                        details: "Measure the whole edit, music and voice together. A quiet intro is fine when the voice part is at −14."),
            LearnedRule(id: "captions-1", area: "captions", text: "Captions in the bottom third, never over the face.",
                        on: false, by: "you", made: "2026-10-01T00:00:00Z", from: ["a"], repeats: []),
        ]
        let cal = Calendar.current
        let week = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        var st = FeedbackStats(comments: 214, learned: 31, oneOff: 40, repeats: 4, videos: 18, checksRun: 9, checksCaught: 6)
        st.weeks = (0..<12).reversed().map { i in
            var w = FeedbackStats.Week(start: cal.date(byAdding: .weekOfYear, value: -i, to: week)!)
            if i % 3 != 2 { w.videos = 2; w.comments = 2 * (4 + i); w.repeats = i < 4 ? 1 : 0; w.titles = ["Takes launch video", "How I make my videos"] }
            return w
        }
        st.recent = 5.5
        st.before = 9.2
        store.stats = st
        shoot("feedback-board", FeedbackPage(store: store, root: root), size: CGSize(width: 1100, height: 1200))
        shoot("feedback-chart-hover", WeeklyBars(weeks: st.weeks, hovered: 7).card(padding: 16).padding(20).background(Theme.paper),
              size: CGSize(width: 900, height: 420))
        let none = FeedbackStore()
        none.loaded = true
        shoot("feedback-rules-empty", RulesCard(store: none, root: root).padding(20).background(Theme.paper), size: CGSize(width: 900, height: 200))
        shoot("feedback-rules-add", RulesCard(store: store, root: root, adding: true, area: "cut").padding(20).background(Theme.paper),
              size: CGSize(width: 900, height: 760))
        // The other rule changed after Takes wrote the merge: both rules side by side, Merge still there.
        store.rules[0].text = "Pauses 0.15–0.25 s between sentences."
        shoot("feedback-rules-merge", RulesCard(store: store, root: root, area: "cut", merges: true).padding(20).background(Theme.paper),
              size: CGSize(width: 1000, height: 560))
        shoot("feedback-rules-merge-dark", RulesCard(store: store, root: root, area: "cut", merges: true).padding(20).background(Theme.paper),
              size: CGSize(width: 1000, height: 560), dark: true)
        shoot("feedback-rules-dark", RulesCard(store: store, root: root, area: "cut").padding(20).background(Theme.paper),
              size: CGSize(width: 1000, height: 560), dark: true)
        shoot("feedback-rules-search", RulesCard(store: store, root: root, search: "never").padding(20).background(Theme.paper),
              size: CGSize(width: 1000, height: 460))
    }
}
