import Foundation
import Testing
@testable import Takes

// 2026-10-02: the LinkedIn comment copilot. The MCP server writes suggestions; the board records
// The user's decisions in the same files without losing fields it does not know.

@MainActor
struct CopilotTests {
    /// A suggestion as mcp/takes_mcp.py writes it, plus a field this app does not know.
    func library(_ files: [String: String] = [:]) throws -> (URL, CopilotStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: "copilot-\(UUID().uuidString)")
        let dir = CopilotStore.suggestions(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (id, created) in files {
            let json = """
            {"id": "\(id)", "created": "\(created)", "status": "review", "future_field": 7,
             "post": {"url": "https://l.in/\(id)", "author": "Jane", "author_url": "https://l.in/in/r",
                      "text": "A post", "posted": "3h", "comments": 12},
             "angle": "His story", "drafts": [{"text": "ngl same", "at": "\(created)", "by": "agent"}]}
            """
            try json.write(to: dir.appending(path: "\(id).json"), atomically: true, encoding: .utf8)
        }
        let store = CopilotStore()
        store.scan(root)
        return (root, store)
    }

    func raw(_ root: URL, _ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: CopilotStore.suggestions(root).appending(path: "\(id).json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func readsWhatTheServerWrites() throws {
        let (_, store) = try library(["a": "2026-10-02T16:00:00Z"])
        let s = try #require(store.review.first)
        #expect(s.post.authorURL == "https://l.in/in/r")
        #expect(s.post.comments == 12)
        #expect(s.text == "ngl same")
    }

    @Test func approveKeepsTheDraftNextToTheEdit() throws {
        let (root, store) = try library(["a": "2026-10-02T16:00:00Z", "b": "2026-10-02T16:01:00Z"])
        store.approve(store.review[0], text: "ngl same")
        store.approve(store.review[0], text: "mine now")
        let a = try raw(root, "a"), b = try raw(root, "b")
        #expect((a["decision"] as? [String: Any])?["kind"] as? String == "approved")
        #expect((b["decision"] as? [String: Any])?["kind"] as? String == "edited")
        #expect(b["final"] as? String == "mine now")
        #expect((b["drafts"] as? [[String: Any]])?.first?["text"] as? String == "ngl same")
        #expect(b["future_field"] as? Int == 7)
        #expect(store.approved.count == 2 && store.review.isEmpty)
    }

    @Test func approveRecordsTheVariantPicked() throws {
        let (root, store) = try library(["a": "2026-10-02T16:00:00Z", "b": "2026-10-02T16:01:00Z"])
        for id in ["a", "b"] {
            var d = try raw(root, id)
            d["drafts"] = [["text": "one", "variants": ["one", "two?", "three."], "by": "agent"]]
            try JSONSerialization.data(withJSONObject: d).write(to: CopilotStore.suggestions(root).appending(path: "\(id).json"))
        }
        store.scan(root)
        #expect(store.review[0].options == ["one", "two?", "three."])
        store.approve(store.review[0], text: "two?", variant: 1)
        store.approve(store.review[0], text: "three, mine", variant: 2)
        let a = try #require(try raw(root, "a")["decision"] as? [String: Any])
        let b = try #require(try raw(root, "b")["decision"] as? [String: Any])
        #expect(a["kind"] as? String == "approved" && a["variant"] as? Int == 1)
        #expect(b["kind"] as? String == "edited" && b["variant"] as? Int == 2)
    }

    @Test func declineKeepsKindReasonAndNote() throws {
        let (root, store) = try library(["a": "2026-10-02T16:00:00Z"])
        store.decline(store.review[0], wrongPost: true, reason: .person, note: "  not my crowd ")
        let d = try #require(try raw(root, "a")["decision"] as? [String: Any])
        #expect(d["kind"] as? String == "wrong_post")
        #expect(d["reason"] as? String == "wrong person")
        #expect(d["note"] as? String == "not my crowd")
        #expect(store.declined.count == 1)
    }

    @Test func feedbackGoesOnTheNewestDraft() throws {
        let (root, store) = try library(["a": "2026-10-02T16:00:00Z"])
        var asked: [String] = []
        store.askChat = { asked.append($0) }
        store.feedback(store.review[0], note: "shorter", variant: 1)
        #expect(asked.count == 1)  // the redraft goes to the chat, where the user watches it
        #expect(asked.first?.contains("\"shorter\"") == true)
        #expect(asked.first?.contains("variant 2") == true)
        let s = try raw(root, "a")
        #expect(s["status"] as? String == "redraft")
        #expect((s["drafts"] as? [[String: Any]])?.last?["feedback"] as? String == "shorter")
        #expect(store.redrafting.count == 1)
    }

    @Test func skippedCardsLeaveReviewUntilSentBack() throws {
        let (_, store) = try library(["a": "2026-10-02T16:00:00Z", "b": "2026-10-02T16:01:00Z", "c": "2026-10-02T16:02:00Z"])
        store.skip(store.review[0])
        #expect(store.review.map(\.id) == ["b", "c"])
        #expect(store.skippedList.map(\.id) == ["a"])
        #expect(store.lastSkipped == "a")
        store.unskip("a")
        #expect(store.review.map(\.id) == ["a", "b", "c"])
        #expect(store.skippedList.isEmpty && store.lastSkipped == nil)
    }

    @Test func pullBackAndPost() throws {
        let (root, store) = try library(["a": "2026-10-02T16:00:00Z"])
        store.approve(store.review[0], text: "x")
        store.pullBack(store.approved[0])
        let back = try raw(root, "a")
        #expect(store.review.count == 1 && back["final"] == nil)
        store.approve(store.review[0], text: "x")
        store.markPosted(store.approved[0], url: "https://l.in/c")
        #expect(store.posted.first?.posted?.url == "https://l.in/c")
    }

    @Test func unattendedRedraftsGetNoShellBrowserOrEdits() {
        let a = CopilotRunner.arguments(system: "s")
        #expect(!a.contains("--chrome"))
        #expect(a[a.firstIndex(of: "--permission-mode")! + 1] == "dontAsk")
        #expect(a[a.firstIndex(of: "--tools")! + 1] == "Read")
        #expect(!a.contains { $0.hasPrefix("Bash") || $0.hasPrefix("Edit") || $0.hasPrefix("Write") })
        #expect(!a.contains { $0.hasPrefix("mcp__claude-in-chrome") })
        #expect(!a.contains("mcp__takes__set_comment_posted"))
    }

    @Test func postAskIsUsersYesForApprovedOnly() {
        #expect(CopilotAsk.post(3).contains("3 approved comments"))
        #expect(CopilotAsk.context.contains("Never post a draft that is not approved"))
        #expect(CopilotAsk.context.contains("never use the system clipboard"))
    }

    @Test func readsTheRunResult() {
        let out = "some warning\n{\"type\":\"result\",\"is_error\":false,\"result\":\"Looked at 9 posts.\\nAdded 4 drafts.\"}\n"
        let (text, error) = CopilotRunner.result(Data(out.utf8))
        #expect(text == "Added 4 drafts.")
        #expect(!error)
        #expect(CopilotRunner.result(Data("boom".utf8)) == ("boom", true))
    }

    @Test func fileEventsThatMatter() {
        let root = URL(fileURLWithPath: "/m/Takes")
        #expect(CopilotStore.matters(["/m/Takes/_library/comments/suggestions"], root: root))
        #expect(!CopilotStore.matters(["/m/Takes/_library/comments/runs"], root: root))
        #expect(!CopilotStore.matters(["/m/Takes/Proj/2026-10-02-x"], root: root))
    }

    /// Posted counts per day, the running total, the streak, and 48h numbers only from measured comments.
    @Test func postedTallyCountsDaysAndTotals() throws {
        func posted(_ id: String, _ at: String, seen: Int? = nil) throws -> Suggestion {
            let stats = seen.map { #", "stats": [{"at": "\#(at)", "impressions": \#($0), "likes": 2, "replies": 1}]"# } ?? ""
            let json = #"{"id": "\#(id)", "created": "\#(at)", "status": "posted", "post": {}, "drafts": [], "posted": {"at": "\#(at)"}\#(stats)}"#
            return try CopilotStore.decoder.decode(Suggestion.self, from: Data(json.utf8))
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z"))
        let t = PostedTally([
            try posted("a", "2026-09-30T10:00:00Z", seen: 400),
            try posted("b", "2026-10-01T10:00:00Z"),
            try posted("c", "2026-10-01T18:00:00Z", seen: 100),
            try posted("d", "2026-09-20T10:00:00Z"),
        ], now: now, calendar: cal)
        #expect(t.total == 4)
        #expect(t.days.count == 14)  // two weeks on the axis
        #expect(t.days.last?.total == 4)
        #expect(t.days.map(\.count).reduce(0, +) == 4)
        #expect(t.bestDay == 2)
        #expect(t.thisWeek == 3)
        #expect(t.streak == 2)  // Sep 30 and Oct 1; today is still open
        #expect(t.seen == 500 && t.likes == 4 && t.replies == 2 && t.measured == 2)
        #expect(PostedTally([]).days.isEmpty)
    }
}
