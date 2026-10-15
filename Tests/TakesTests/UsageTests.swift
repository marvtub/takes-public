import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

/// The opt-in usage counts and the counted update check (2026-10-10).
@MainActor
struct UsageTests {
    @Test func theReportHoldsOnlyCountsAndNoText() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = root.appending(path: "Secret Project/My private video title")
        let b = root.appending(path: "Secret Project/Second video")
        try fm.createDirectory(at: a.appending(path: "edits"), withIntermediateDirectories: true)
        try fm.createDirectory(at: Storyboard.folder(b), withIntermediateDirectories: true)
        for f in ["cut-v1.mp4", "cut-v2.mov", "notes.txt"] { try Data().write(to: a.appending(path: "edits/\(f)")) }
        try Data("{}".utf8).write(to: Storyboard.file(b))

        let r = Usage.report(id: "3F2A1B4C-1111-2222-3333-444455556666", version: "v2026.10.10", os: "26.1",
                             root: root, projects: 1, sessions: [(a, 7, true), (b, 2, false)],
                             plugins: ["voices", "feedback"], phone: true)
        #expect(r.counts.projects == 1 && r.counts.sessions == 2 && r.counts.takes == 9 && r.counts.edits == 2)
        #expect(r.counts.storyboards == 1 && r.counts.published == 1 && r.counts.phone == 1)
        #expect(r.plugins == ["feedback", "voices"])

        let json = String(decoding: try Usage.encode(r), as: UTF8.self)
        for word in ["Secret", "private", "title", "cut-v1", "notes"] { #expect(!json.contains(word)) }
        // The site keeps exactly these fields (gettakes-site functions/ping.js COUNTS).
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "v", "os", "counts", "plugins", "agent"])
        let counts = try #require(object["counts"] as? [String: Int])
        #expect(Set(counts.keys) == ["projects", "sessions", "takes", "edits", "storyboards", "posts_ready",
                                     "posts_scheduled", "posts_posted", "published", "phone",
                                     "chats_7d", "takes_7d", "record_min_7d", "edits_7d", "crashes_7d", "age_days",
                                     "tokens_7d", "out_tokens_7d"])
    }

    @Test func tokensAreSummedFromUsageLinesOnlyAndKeptOnlyWhenOn() throws {
        // Claude: the result's modelUsage, every model. The secret words must never reach the count store.
        var p = ChatParser([], adapter: ClaudeAdapter())
        p.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"secret answer"}],"usage":{"input_tokens":5,"output_tokens":7}}}"#)
        p.consume(#"{"type":"result","subtype":"success","result":"secret answer","modelUsage":{"opus":{"inputTokens":100,"outputTokens":40,"cacheReadInputTokens":800,"cacheCreationInputTokens":60},"haiku":{"inputTokens":10,"outputTokens":5}}}"#)
        #expect(p.spent == 1015 && p.spentOut == 45)
        var c = ChatParser([], adapter: CodexAdapter())
        c.consume(#"{"type":"turn.completed","usage":{"input_tokens":3000,"cached_input_tokens":2000,"output_tokens":200}}"#)
        #expect(c.spent == 3200 && c.spentOut == 200)

        let d = try #require(UserDefaults(suiteName: "usage-tokens-\(UUID().uuidString)"))
        let now = Date()
        Usage.addTokens(5000, out: 400, on: false, defaults: d, now: now)
        #expect(Usage.tokens(d).isEmpty)
        Usage.addTokens(9000, out: 900, on: true, defaults: d, now: now.addingTimeInterval(-30 * 86_400))
        Usage.addTokens(5000, out: 400, on: true, defaults: d, now: now)
        Usage.addTokens(1600, out: 100, on: true, defaults: d, now: now)
        Usage.addTokens(9000, out: 900, on: true, defaults: d, now: now.addingTimeInterval(-10 * 86_400))
        #expect(Usage.tokens(d).count == 2)
        let raw = String(decoding: d.data(forKey: Usage.tokensKey) ?? Data(), as: UTF8.self)
        #expect(!raw.contains("secret"))
        let r = Usage.report(id: "3F2A1B4C-1111-2222-3333-444455556666", version: "", os: "", root: FileManager.default.temporaryDirectory,
                             projects: 0, sessions: [], plugins: [], phone: false, tokens: Usage.tokens(d), now: now)
        #expect(r.counts.tokens_7d == 7 && r.counts.out_tokens_7d == 1)
    }

    @Test func theWeekCountsChatsTakesEditsAndCrashesButNoWords() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "usage-week-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let s = root.appending(path: "P/Walk and talk"), boards = root.appending(path: "boards"), crashes = root.appending(path: "crashes")
        for d in [s.appending(path: "edits"), s.appending(path: ".claude-chats"), boards, crashes] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        var meta = SessionMeta(title: "Walk and talk", createdAt: now)
        meta.takes = [Take(number: 1, kind: .camera, file: "a.mov", startedAt: now.addingTimeInterval(-3600), duration: 150),
                      Take(number: 2, kind: .camera, file: "b.mov", startedAt: now.addingTimeInterval(-86_400), duration: 90),
                      Take(number: 3, kind: .camera, file: "c.mov", startedAt: now.addingTimeInterval(-20 * 86_400), duration: 600)]
        try Store.encoder.encode(meta).write(to: s.appending(path: "session.json"))
        try Data().write(to: s.appending(path: "edits/cut-v1.mp4"))
        let old = s.appending(path: "edits/cut-v0.mp4")
        try Data().write(to: old)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: old.path)

        func log(_ msgs: [(ChatMessage.Role, Double)]) throws -> Data {
            var l = ChatLog(conversation: UUID().uuidString)
            l.messages = msgs.map { var m = ChatMessage(role: $0.0, text: "a private secret prompt"); m.at = now.addingTimeInterval(-$0.1); return m }
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            return try e.encode(l)
        }
        try log([(.user, 60), (.claude, 50), (.user, 9 * 86_400)]).write(to: ClaudeChat.file(s))
        try log([(.user, 2 * 86_400)]).write(to: s.appending(path: ".claude-chats/old.json"))
        try log([(.user, 100), (.user, 200)]).write(to: boards.appending(path: "Posts-chat.json"))
        try Data().write(to: crashes.appending(path: "Takes-2026-10-12-101010.ips"))
        try Data().write(to: crashes.appending(path: "Safari-2026-10-12-101010.ips"))

        let r = Usage.report(id: "3F2A1B4C-1111-2222-3333-444455556666", version: "v2026.10.13", os: "26.1",
                             root: root, projects: 1, sessions: [(s, 3, false)], plugins: [], phone: false,
                             agent: "codex", firstSeen: now.addingTimeInterval(-12.5 * 86_400),
                             boards: boards, crashes: crashes, now: now)
        #expect(r.counts.chats_7d == 4 && r.counts.takes_7d == 2 && r.counts.record_min_7d == 4)
        #expect(r.counts.edits == 2 && r.counts.edits_7d == 1 && r.counts.crashes_7d == 1 && r.counts.age_days == 12)
        #expect(r.agent == "codex")
        let json = String(decoding: try Usage.encode(r), as: UTF8.self)
        for word in ["private", "secret", "prompt", "Walk"] { #expect(!json.contains(word)) }
        #expect(Usage.report(id: r.id, version: "", os: "", root: root, projects: 0, sessions: [], plugins: [],
                             phone: false, agent: "gpt", boards: boards, crashes: crashes).agent == "")
    }

    @Test func aPhoneSeenThisWeekCounts() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "phones-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date()
        #expect(!PhoneServer.usedRecently(file: file, now: now))
        let old = PairedPhone(name: "Phone", hash: "x", paired: now.addingTimeInterval(-30 * 86_400), seen: now.addingTimeInterval(-9 * 86_400))
        try JSONEncoder.iso.encode([old]).write(to: file)
        #expect(!PhoneServer.usedRecently(file: file, now: now))
        var fresh = old
        fresh.seen = now.addingTimeInterval(-2 * 86_400)
        try JSONEncoder.iso.encode([old, fresh]).write(to: file)
        #expect(PhoneServer.usedRecently(file: file, now: now))
    }

    @Test func theUpdateCheckSaysTheVersionAndThePhone() throws {
        let url = Updater.checkURL(own: "v2026.10.10", phone: true)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.host == "gettakes.app" && c.path == "/latest")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["v"] == "v2026.10.10" && q["phone"] == "1" && !(q["os"] ?? "").isEmpty)
        #expect(Set(q.keys) == ["v", "os", "phone"])
    }

    @Test func theFirstCheckOfAVersionSaysWhereItCameFrom() throws {
        let d = try #require(UserDefaults(suiteName: "usage-\(UUID().uuidString)"))
        #expect(Updater.checkFrom(own: "v2026.10.10", defaults: d) == "new")
        d.set(true, forKey: Onboarding.doneKey)
        #expect(Updater.checkFrom(own: "v2026.10.10", defaults: d) == nil)
        d.set("v2026.10.9", forKey: Updater.checkedKey)
        #expect(Updater.checkFrom(own: "v2026.10.10", defaults: d) == "v2026.10.9")
        d.set("v2026.10.10", forKey: Updater.checkedKey)
        #expect(Updater.checkFrom(own: "v2026.10.10", defaults: d) == nil)
        let q = URLComponents(url: Updater.checkURL(own: "v2026.10.10", phone: false, from: "new"), resolvingAgainstBaseURL: false)?.queryItems
        #expect(q?.first { $0.name == "from" }?.value == "new")
    }

    @Test func theNeverPanelNamesTheChats() {
        #expect(UsageCopy.neverTitle.contains("chats"))
        #expect(UsageCopy.neverDetail.contains("chat history"))
    }

    /// The ask card and Settings › Usage, rendered to look at. `TAKES_SNAPSHOT=/some/dir`.
    @Test func snapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let app = AppModel()
        let views: [(String, CGSize, AnyView)] = [
            ("usage-ask", CGSize(width: 560, height: 480), AnyView(UsageAskCard(usage: .shared).padding(40))),
            ("usage-ask-details", CGSize(width: 640, height: 860), AnyView(UsageAskCard(usage: .shared, showDetails: true).padding(40))),
            ("usage-settings", CGSize(width: 580, height: 560), AnyView(UsagePage())),
        ]
        for (name, size, view) in views {
            for (mode, dark) in [("dark", true), ("light", false)] {
                let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(Theme.canvas)
                    .environment(app).environment(\.colorScheme, dark ? .dark : .light)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(mode).png"))
            }
        }
    }
}
