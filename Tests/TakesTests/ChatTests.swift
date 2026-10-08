import AppKit
import Foundation
import Testing
@testable import Takes

// The chat panel reads the claude CLI's stream-json lines (Chat.swift). Lines copied from a real
// run of Claude Code 2.1.286, shortened.

struct ChatTests {
    @Test func aCommitReadsAsAChange() {
        let c = Updater.Change.parse(subject: "Install only main; Script beside chat moves into the camera caption row", body: "Why: a branch dropped a tab.")
        #expect(c.area == "Takes")
        #expect(c.headline == "Install only main")
        #expect(c.detail == "Script beside chat moves into the camera caption row.\n\nWhy: a branch dropped a tab.")
        let d = Updater.Change.parse(subject: "Post tab: Article, a post for the blog as your blog shows it")
        #expect(d.area == "Post tab")
        #expect(d.headline == "Article, a post for the blog as your blog shows it")
        #expect(d.detail.isEmpty)
        let json = #"[{"hash":"798dd72","date":"2026-10-04T09:42:00-07:00","subject":"Notices: unseen ones are saved","body":""}]"#
        #expect(Updater.Change.load(Data(json.utf8)).map(\.area) == ["Notices"])
        #expect(Updater.Change.load(nil).isEmpty)
    }

    @Test func aReleaseIsNewerAndItsNotesReadAsChanges() {
        #expect(Updater.isNewer("v2026.10.6.2", than: "v2026.10.6"))
        #expect(Updater.isNewer("v2026.10.10", than: "v2026.10.9.3"))
        #expect(Updater.isNewer("v2026.11.1", than: "v2026.10.30"))
        #expect(!Updater.isNewer("v2026.10.6", than: "v2026.10.6"))
        #expect(!Updater.isNewer("v2026.10.5", than: "v2026.10.6.2"))
        let body = "### Chat\n- Sound files play right in their card\n\n### ⌘K\n- One search\n- Footage too\n\n### Install\nThe easy way:\n\n    curl -fsSL https://gettakes.app/install | bash\n\n<!-- source: b11ec45 -->"
        let n = Updater.Change.notes(body)
        #expect(n.map(\.area) == ["Chat", "⌘K", "⌘K"])
        #expect(n.map(\.headline) == ["Sound files play right in their card", "One search", "Footage too"])
        #expect(Set(n.map(\.id)).count == 3)
    }

    /// Three releases behind: one update, and What's new lists all three releases' changes.
    @Test func skippedReleasesNotesMergeIntoOne() {
        let newest = "### Chat\n- Replies stream\n\n### Install\n- not news"
        let middle = "### ⌘K\n- Results glide in\n\n### Chat\n- Tools fold away\n- Replies stream"
        let oldest = "### Record\n- Prompter follows your voice"
        let n = Updater.Change.notes(Updater.mergeNotes([newest, middle, oldest]))
        #expect(n.map(\.area) == ["Chat", "Chat", "⌘K", "Record"])
        #expect(n.map(\.headline) == ["Replies stream", "Tools fold away", "Results glide in", "Prompter follows your voice"])
    }

    /// The whole path against a stand-in for GitHub: TAKES_UPDATE_E2E=<dir> with api.txt (the
    /// release URL), own.txt (the old tag), stamp.txt (the old build stamp) and Apps/, made by
    /// a test script. Read the release, download the DMG, stage it, read it as the sidebar does.
    @Test func aReleaseUpdatesEndToEnd() async throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_UPDATE_E2E"].map({ URL(fileURLWithPath: $0) }) else { return }
        func text(_ f: String) throws -> String { try String(contentsOf: dir.appending(path: f), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        let api = try #require(URL(string: try text("api.txt")))
        let own = try text("own.txt"), stage = dir.appending(path: "Apps/.update.noindex")
        #expect(await Updater.fetchRelease(api: api, own: "v2099.1.1", skip: nil, bundleID: "de.marvinaziz.takes", into: stage) == nil)
        #expect(await Updater.fetchRelease(api: api, own: own, skip: nil, bundleID: "de.other", into: stage) == nil)
        let tag = await Updater.fetchRelease(api: api, own: own, skip: nil, bundleID: "de.marvinaziz.takes", into: stage)
        #expect(tag != nil)
        #expect(await Updater.fetchRelease(api: api, own: own, skip: tag, bundleID: "de.marvinaziz.takes", into: stage) == nil)
        let staged = try #require(Updater.read(stage.appending(path: "Takes.app"), ownStamp: try text("stamp.txt")))
        #expect(staged.release == tag)
        #expect(!staged.log.isEmpty)
        #expect(!staged.log.contains { $0.area == "Install" })
        #expect(Updater.read(stage.appending(path: "Takes.app"), ownStamp: staged.stamp) == nil)
        try "\(staged.release ?? "") \(staged.log.map { "\($0.area): \($0.headline)" })".write(to: dir.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
    }

    /// A release's DMG stages its app and notes; a DMG at another tag stages nothing.
    @Test func aReleaseDMGIsStaged() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let app = dir.appending(path: "disk/Takes.app/Contents")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["ReleaseTag": "v2026.10.7", "CFBundleIdentifier": "de.example.takes", "BuildStamp": "abc Oct 7 10:00"]
        try info.write(to: app.appending(path: "Info.plist"))
        let dmg = dir.appending(path: "Takes.dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-quiet", "-volname", "Takes", "-srcfolder", dir.appending(path: "disk").path, "-format", "UDZO", dmg.path]
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let stage = dir.appending(path: ".update.noindex")
        let notes = try JSONEncoder().encode(["tag": "v2026.10.7", "body": "### Chat\n- New"])
        #expect(!Updater.stage(dmg: dmg, tag: "v2026.10.8", bundleID: "de.example.takes", notes: notes, into: stage))
        #expect(!fm.fileExists(atPath: stage.appending(path: "Takes.app").path))
        #expect(!Updater.stage(dmg: dmg, tag: "v2026.10.7", bundleID: "de.other", notes: notes, into: stage))
        #expect(Updater.stage(dmg: dmg, tag: "v2026.10.7", bundleID: "de.example.takes", notes: notes, into: stage))
        let staged = NSDictionary(contentsOf: stage.appending(path: "Takes.app/Contents/Info.plist"))
        #expect(staged?["ReleaseTag"] as? String == "v2026.10.7")
        #expect(fm.fileExists(atPath: stage.appending(path: "release.json").path))
        #expect(!fm.fileExists(atPath: stage.appending(path: "incoming.app").path))
    }

    @Test func aLostConnectionGoesOnARateLimitDoesNot() {
        #expect(ClaudeChat.isConnectionError("API Error: Connection error."))
        #expect(ClaudeChat.isConnectionError("Request timed out."))
        #expect(ClaudeChat.isConnectionError("API Error: 529 {\"type\":\"overloaded_error\"}"))
        #expect(ClaudeChat.isConnectionError("TypeError: fetch failed (ECONNRESET)"))
        #expect(!ClaudeChat.isConnectionError("Claude AI usage limit reached|1759500000"))
        #expect(!ClaudeChat.isConnectionError("Invalid API key · Please run /login"))
        #expect(!ClaudeChat.isConnectionError("Claude quit (code 1)."))
    }

    @Test func streamsTextThenSettlesIt() {
        var p = ChatParser([])
        p.consume(#"{"type":"system","subtype":"init","session_id":"s"}"#)
        p.consume(#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#)
        p.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"File"}}}"#)
        p.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" says hi."}}}"#)
        #expect(p.started)
        #expect(p.messages.map(\.text) == ["File says hi."])
        #expect(p.messages.last?.done == false)
        p.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"File says hi."}]}}"#)
        #expect(p.messages.count == 1)
        #expect(p.messages.last?.done == true)
    }

    @Test func toolCallRunsThenEnds() {
        var p = ChatParser([])
        p.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/b/script.md"}}]}}"#)
        #expect(p.messages.first?.text == "Read · script.md")
        #expect(p.messages.first?.done == false)
        p.consume(#"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"x"}]}}"#)
        #expect(p.messages.first?.done == true)
    }

    @Test func openCommentsGoWithATypedMessageButTheChatShowsOnlyTheMessage() {
        let c = [Comment(id: "c1", file: "edits/a-v2.mp4", start: 3, end: 5, text: "Too loud\nhere", status: "open", by: "user", at: ""),
                 Comment(id: "c2", file: "edits/a-v2.mp4", text: "Done", status: "resolved", by: "user", at: ""),
                 Comment(id: "c3", file: "storyboard/storyboard.json", text: "Wider", status: "open", by: "user", at: "", shot: "s4")]
        let sent = ClaudeChat.withComments("fix that one", c)
        #expect(sent.contains("- c1 · edits/a-v2.mp4 @ 0:03.0–0:05.0 · Too loud here"))
        #expect(sent.contains("- c3 · shot s4 · Wider"))
        #expect(!sent.contains("c2"))
        #expect(CopilotAsk.shown(sent) == "fix that one")
        #expect(ClaudeChat.withComments("hi", [c[1]]) == "hi")
    }

    @Test func openCommentsSayWhereTheyAre() {
        let v17 = Comment(id: "c7", file: "edits/short-v17.mp4", start: 12, text: "Captions\ntoo low", status: "open", by: "user", at: "")
        let v18 = Comment(id: "c8", file: "edits/short-v18.mp4", text: "Cut", status: "open", by: "user", at: "")
        let shot = Comment(id: "c9", file: "storyboard/storyboard.json", text: "Wider", status: "open", by: "user", at: "", shot: "s4")
        #expect(v17.place == "v17 @ 0:12.0")
        #expect(v18.place == "v18")
        #expect(shot.place == "shot s4")
        #expect(Comment(id: "c1", file: "script.md", quote: "x", text: "y", status: "open", by: "user", at: "").place == "the script")
        #expect(OpenCommentsLabel.text([v17], count: 1) == "1 open comment · v17")
        #expect(OpenCommentsLabel.text([v17, v18], count: 2) == "2 open comments")
        #expect(OpenCommentsLabel.text([], count: 3) == "3 open comments")
        #expect(v17.ask.hasPrefix("Fix my comment c7 on v17 @ 0:12.0: \"Captions too low\"."))
        #expect(ClaudeChat.withComments("center the captions", [v17]).contains("older versions"))
    }

    @Test func unseenNoticesSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appending(path: "edit-v1.mp4")
        try Data().write(to: kept)
        let saved = [AgentNotice(path: kept, session: dir), AgentNotice(path: dir.appending(path: "gone.mp4"), session: dir)]
        let back = AgentNotice.restore(try JSONEncoder().encode(saved))
        #expect(back == [saved[0]])
        #expect(AgentNotice.restore(nil).isEmpty)
    }

    @Test func aNoticeSaysWhatTheFileIsInWords() {
        let s = URL(fileURLWithPath: "/tmp/Acme/era-of-personal-software")
        func d(_ rel: String) -> String { let r = AgentNotice.describe(s.appending(path: rel), session: s); return "\(r.what)|\(r.name)" }
        #expect(d("edits/mg-s3-linux-phones-v2.mp4") == "Edit v2|Mg s3 linux phones")
        #expect(d("thumbnails/cover_v12.png") == "Thumbnail v12|Cover")
        #expect(d("stills/take-01-00m12.40s.png") == "Frame|Take 01 00m12.40s")
        #expect(d("script.md") == "Script|")
        #expect(d("storyboard/storyboard.json") == "Storyboard|")
        #expect(d("notes.txt") == "File|Notes")
        #expect(AgentNotice.describe(s, session: s).what == "Session")
    }

    @Test func onlyThisLibrarySendsNotices() {
        let root = URL(fileURLWithPath: "/Users/m/Movies/Takes")
        #expect(AppModel.inside(root.appending(path: "Acme/2026-10-04-x/edits/a-v1.mp4"), root))
        #expect(AppModel.inside(root.appending(path: "_library/styles/Magazine"), root))
        #expect(AppModel.inside(root, root))
        #expect(!AppModel.inside(URL(fileURLWithPath: "/tmp/takes-demo/Shorts/2026-10-04-phone"), root))
        #expect(!AppModel.inside(URL(fileURLWithPath: "/Users/m/Movies/Takes-demo/Shorts"), root))
    }

    @Test func theCommentsTokenIsTextInTheBox() {
        #expect(ClaudeChat.mentionsComments("@comments fix the loud one"))
        #expect(ClaudeChat.mentionsComments("fix it @comments"))
        #expect(!ClaudeChat.mentionsComments("fix the loud one"))
        #expect(!ClaudeChat.mentionsComments("me@comments.io"))
        #expect(ClaudeChat.withoutCommentsToken("@comments fix the loud one") == "fix the loud one")
        #expect(ClaudeChat.withoutCommentsToken("fix it @comments") == "fix it")
        #expect(ClaudeChat.withoutCommentsToken("@comments ").isEmpty)
    }

    @Test func messagesKeepWhenTheyWereSentAndOldOnesStillLoad() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi","done":true}"#
        #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8)).at == nil)
        let m = ChatMessage(role: .user, text: "hi")
        let back = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(m))
        #expect(back.at != nil && abs(back.at!.timeIntervalSince(m.at!)) < 0.001)
    }

    @Test func linesAreCutAcrossChunksAndBigResultsShrink() {
        let big = String(repeating: "A", count: 200_000)
        let picture = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":[{"type":"image","source":{"data":""# + big + #""}}]}]},"parent_tool_use_id":null}"#
        let lines = StreamLines()
        let all = Data((#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/still.png"}}]}}"# + "\n" + picture + "\n").utf8)
        var got: [String] = []
        // In odd chunks, as a pipe hands them over.
        var i = all.startIndex
        while i < all.endIndex {
            let j = min(i + 7_919, all.endIndex)
            got += lines.feed(all.subdata(in: i..<j))
            i = j
        }
        #expect(got.count == 2)
        #expect(got[1].utf8.count < 200)
        var p = ChatParser([])
        for l in got { p.consume(l) }
        #expect(p.messages.first?.done == true)
        // A subagent's result keeps its parent, so it stays hidden.
        let inner = StreamLines.shrink(#"{"type":"user","message":{"content":[{"tool_use_id":"t2","type":"tool_result","content":""# + big + #""}]},"parent_tool_use_id":"t9"}"#)
        #expect(inner.contains("t9"))
    }

    @Test func subagentStepsStayHidden() {
        var p = ChatParser([])
        p.consume(#"{"type":"assistant","parent_tool_use_id":"t9","message":{"content":[{"type":"text","text":"inner"}]}}"#)
        #expect(p.messages.isEmpty)
    }

    @Test func errorResultShows() {
        var p = ChatParser([ChatMessage(role: .tool, text: "Bash", toolID: "t", done: false)])
        p.consume(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#)
        #expect(p.finished)
        #expect(p.messages.allSatisfy { $0.done })
        #expect(p.messages.last?.role == .error)
    }

    @Test func tracksContextAndCompaction() {
        var p = ChatParser([])
        p.consume(#"{"type":"assistant","message":{"usage":{"input_tokens":9,"cache_creation_input_tokens":17160,"cache_read_input_tokens":13970,"output_tokens":3},"content":[]}}"#)
        #expect(p.context == ChatContext(used: 31142, window: 200_000))
        p.consume(#"{"type":"result","subtype":"success","result":"","modelUsage":{"claude-opus-5-5":{"contextWindow":1000000},"claude-haiku-4-5":{"contextWindow":200000}}}"#)
        #expect(p.context?.window == 1_000_000)
        p.consume(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":31190,"post_tokens":6207}}"#)
        #expect(p.context?.used == 6207)
        #expect(p.messages.last?.text == "Compacted the conversation · 31k → 6k tokens")
    }

    @Test func describesMcpAndBash() {
        #expect(ChatParser.describe("mcp__takes__get_comments", [:]) == "get comments")
        #expect(ChatParser.describe("Bash", ["command": "ffmpeg -i a.mov\nmore", "description": "Cut the silences"]) == "Bash · Cut the silences")
    }
}

struct ChatRefTests {
    private let files: Set<String> = ["/m/WebMCP/edits/webmcp-short-v11.mp4", "/m/WebMCP/posts/linkedin.md"]

    @Test func pathAndPostLinesBecomeCards() {
        let reply = """
        Your best edit:
        /m/WebMCP/edits/webmcp-short-v11.mp4
        It did well:
        https://www.linkedin.com/posts/jane-doe_abc-ugcPost-1
        """
        let p = ChatRefs.split(reply) { files.contains($0) }
        #expect(p == [.text("Your best edit:"), .file(URL(fileURLWithPath: "/m/WebMCP/edits/webmcp-short-v11.mp4")),
                      .text("It did well:"), .post(URL(string: "https://www.linkedin.com/posts/jane-doe_abc-ugcPost-1")!)])
    }

    @Test func wrappedReferencesCount() {
        #expect(ChatRefs.reference("`/m/WebMCP/posts/linkedin.md`") { files.contains($0) } == .file(URL(fileURLWithPath: "/m/WebMCP/posts/linkedin.md")))
        #expect(ChatRefs.reference("- [the post](https://x.com/janedoe/status/1)") { _ in false } == .post(URL(string: "https://x.com/janedoe/status/1")!))
    }

    @Test func droppedFilesGoAfterTheText() {
        let files = [URL(fileURLWithPath: "/m/a.png"), URL(fileURLWithPath: "/m/b c.pdf")]
        #expect(ChatAttach.message("  Look at this \n", files: files) == "Look at this\n\n/m/a.png\n/m/b c.pdf")
        #expect(ChatAttach.message("", files: files) == "/m/a.png\n/m/b c.pdf")
        #expect(ChatAttach.message("Hi", files: []) == "Hi")
        let p = ChatRefs.split(ChatAttach.message("Look", files: files)) { _ in true }
        #expect(p == [.text("Look"), .file(files[0]), .file(files[1])])
    }

    /// Muse's chat keeps its own files: a dropped Finder file reaches it through the closure.
    @MainActor @Test func aDroppedFileReachesAnyChat() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID().uuidString).txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var got: [URL] = []
        #expect(ChatAttach.take([NSItemProvider(contentsOf: file)!]) { got.append($0) })
        #expect(!ChatAttach.take([NSItemProvider(object: "text" as NSString)]) { got.append($0) })
        let end = Date().addingTimeInterval(3)
        while got.isEmpty && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(got.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test func pastedImageIsSavedLossless() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = try #require(ChatAttach.save(rep.tiffRepresentation!))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == (ChatAttach.cwebp == nil ? "png" : "webp"))
        #expect(NSImage(contentsOf: url)?.size == NSSize(width: 4, height: 4))
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("png").path) || url.pathExtension == "png")
    }

    @Test func otherLinesStayText() {
        #expect(ChatRefs.reference("/m/missing.mp4") { files.contains($0) } == nil)
        #expect(ChatRefs.reference("https://example.com/a") { _ in false } == nil)
        #expect(ChatRefs.reference("See https://x.com/a/status/1 for it") { _ in false } == nil)
    }

    @Test func postKeysMatchAcrossForms() {
        #expect(ChatRefs.key("https://www.linkedin.com/posts/a-1/?utm=x") == ChatRefs.key("http://linkedin.com/posts/a-1"))
        #expect(ChatRefs.key("https://twitter.com/m/status/1") == ChatRefs.key("https://x.com/m/status/1"))
    }
}

struct ChatParagraphTests {
    @Test func blankLinesAndListsSplitBlocks() {
        let t = "Intro line\nmore\n\n- one\n- two\nAfter the list"
        #expect(ChatRefs.paragraphs(t) == [["Intro line", "more"], ["- one", "- two"], ["After the list"]])
        #expect(ChatRefs.bullet("- **Bold.** rest") == "**Bold.** rest")
    }

    @Test func threeToolCallsInARowFold() {
        let tool = { (t: String) in ChatMessage(role: .tool, text: t) }
        let msgs = [tool("computer"), tool("computer"), ChatMessage(role: .claude, text: "ok"),
                    tool("computer"), tool("javascript tool"), tool("computer"), tool("Bash · ls")]
        let items = ChatItem.group(msgs)
        #expect(items.count == 4)
        guard case .tools(let run) = items[3] else { Issue.record("no run"); return }
        #expect(run.count == 4)
        #expect(ChatItem.summary(run) == "4 steps · computer, javascript tool, Bash")
    }
}

@MainActor
struct ChatHistoryTests {
    @Test func newConversationKeepsTheOldOneToReopen() throws {
        let session = FileManager.default.temporaryDirectory.appending(path: "chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let old = ChatLog(conversation: "c1", started: true, messages: [
            ChatMessage(role: .user, text: "Cut the silences\nplease"), ChatMessage(role: .claude, text: "Done.")])
        try JSONEncoder().encode(old).write(to: ClaudeChat.file(session))

        let chat = ClaudeChat(session: session)
        #expect(chat.messages.count == 2)
        chat.reset()
        #expect(chat.messages.isEmpty)
        let past = chat.past()
        #expect(past.map(\.title) == ["Cut the silences"])
        #expect(past.first?.count == 1)

        chat.resume(try #require(past.first))
        #expect(chat.messages.map(\.text) == ["Cut the silences\nplease", "Done."])
        #expect(chat.past().isEmpty)
        // It survives a restart.
        #expect(ClaudeChat(session: session).messages.count == 2)
    }

    /// Typed but not sent: it stays on the chat through a tab or session switch, goes to disk, and
    /// a new conversation keeps it. Sending clears it.
    @Test func unsentTextStaysThroughSwitchesAndAQuit() throws {
        let session = FileManager.default.temporaryDirectory.appending(path: "chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let hub = ChatHub()
        hub.chat(session).draft = "Make the hook shorter"
        #expect(hub.chat(session).draft == "Make the hook shorter")  // the same chat when you come back

        hub.chat(session).quit()
        #expect(ClaudeChat(session: session).draft == "Make the hook shorter")  // after a quit

        let chat = ClaudeChat(session: session)
        chat.reset()
        #expect(chat.draft == "Make the hook shorter")
        chat.draft = ""
        chat.saveDraft()
        #expect(ClaudeChat(session: session).draft == "")
    }
}

@MainActor
struct ChatFollowTests {
    @Test func chatFollowsARenamedSessionAndNeverRecreatesTheOldFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "follow-\(UUID().uuidString)")
        let old = root.appending(path: "P/2026-10-01-untitled"), new = root.appending(path: "P/2026-10-01-how-i-make-my-videos")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try JSONEncoder().encode(ChatLog(conversation: "c9", started: true, messages: [ChatMessage(role: .user, text: "Make a video")]))
            .write(to: ClaudeChat.file(old))

        let hub = ChatHub()
        let chat = hub.chat(old)
        try fm.moveItem(at: old, to: new)  // Claude renamed the session
        chat.reset()                       // saves
        #expect(!fm.fileExists(atPath: old.path))
        #expect(chat.session == new.standardizedFileURL)
        #expect(chat.past().map(\.title) == ["Make a video"])
        #expect(hub.chat(new) === chat)
    }
}

@MainActor
struct NoticeTests {
    @Test func aFileBelongsToItsSession() throws {
        let fm = FileManager.default
        let s = fm.temporaryDirectory.appending(path: "notice-\(UUID().uuidString)/P/2026-10-01-a")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        #expect(AppModel.session(containing: s.appending(path: "edits/a-v2.mp4")) == s.standardizedFileURL)
        #expect(AppModel.session(containing: s) == s.standardizedFileURL)
        #expect(AppModel.session(containing: s.deletingLastPathComponent()) == nil)
    }
}

// Serialized: two tests set the shared rightTab default.
@MainActor
@Suite(.serialized)
struct PoliteOpenTests {
    @Test func anAgentRequestNeverChangesTheScreen() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "polite-\(UUID().uuidString)")
        let s = root.appending(path: "P/2026-10-01-a")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        let file = s.appending(path: "edits/a-v2.mp4")
        try Data().write(to: file)

        let app = AppModel()
        let home = app.library.root
        defer { app.library.setRoot(home) }
        app.library.setRoot(root)
        app.handle(url: URL(string: "takes://open?path=" + file.path)!)
        #expect(app.notices.map(\.path) == [file.standardizedFileURL])
        #expect(app.notice(for: s)?.session == s.standardizedFileURL)
        // Another library (a demo built in /tmp) sends nothing.
        app.handle(url: URL(string: "takes://open?path=/tmp/takes-demo/Shorts/2026-10-04-phone")!)
        #expect(app.notices.count == 1)
    }

    /// Show on a new edit: its session, the Assets tab, the file on the stage, the chat open.
    /// Before (2026-10-04), from Post the file played unseen behind it.
    @Test func showingANoticePlaysTheFileInSight() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "show-\(UUID().uuidString)")
        let s = root.appending(path: "P/2026-10-01-a")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        let file = s.appending(path: "edits/a-v2.mp4")
        try Data().write(to: file)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: "rightTab"), d.bool(forKey: "chatOpen"))
        let app = AppModel()
        let home = app.library.root
        defer {
            app.library.setRoot(home)
            d.set(saved.0, forKey: "rightTab"); app.chats.open = saved.1
        }
        app.library.setRoot(root)
        d.set("post", forKey: "rightTab")
        app.chats.open = false
        app.handle(url: URL(string: "takes://open?path=" + file.path)!)
        app.show(try #require(app.notices.first))
        for _ in 0..<20 where app.preview == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(app.library.current?.url.standardizedFileURL == s.standardizedFileURL)
        #expect(app.preview == file.standardizedFileURL)
        #expect(d.string(forKey: "rightTab") == "assets")
        #expect(app.chats.open)
    }

    /// A click on a video card in the chat opens it now; before (2026-10-04), it only left a notice.
    @Test func aClickOpensTheFileAtOnce() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "click-\(UUID().uuidString)")
        let s = root.appending(path: "P/2026-10-01-a")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        let file = s.appending(path: "edits/a-v2.mp4")
        try Data().write(to: file)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: "rightTab"), d.bool(forKey: "chatOpen"))
        let app = AppModel()
        let home = app.library.root
        defer {
            app.library.setRoot(home)
            d.set(saved.0, forKey: "rightTab"); app.chats.open = saved.1
        }
        app.library.setRoot(root)
        app.handle(url: URL(string: "takes://open?path=" + file.path)!)
        app.follow(file)
        #expect(app.notices.isEmpty)
        for _ in 0..<20 where app.preview == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(app.preview == file.standardizedFileURL)
        #expect(d.string(forKey: "rightTab") == "assets")
        // A file outside the library does nothing.
        app.follow(URL(fileURLWithPath: "/tmp/elsewhere.mp4"))
        #expect(app.preview == file.standardizedFileURL)
    }

    @Test func seenClearsOnlyThatSessionsNotices() throws {
        let app = AppModel()
        let saved = app.notices
        defer { app.notices = saved }
        let a = URL(fileURLWithPath: "/tmp/P/a"), b = URL(fileURLWithPath: "/tmp/P/b")
        app.notices = [AgentNotice(path: a.appending(path: "x.mp4"), session: a),
                       AgentNotice(path: b.appending(path: "y.mp4"), session: b)]
        app.seen(URL(fileURLWithPath: "/tmp/P/./a"))
        #expect(app.notices.map(\.session) == [b])
    }
}

// A run that ends badly must leave the chat idle, and nothing the user sent meanwhile may be lost
// (2026-10-03: a killed run showed "Claude quit (code 15)." and "Claude is working" for good).
// A fake claude: a shell script that saves each ask as ask-N.txt and acts by its run number.
@MainActor
@Suite(.serialized)
struct ChatRunTests {
    let dir: URL
    let session: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fakeclaude-\(UUID().uuidString)")
        session = dir.appending(path: "P/2026-10-03-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    }

    /// `body` runs after the ask is saved; $n is the run number.
    func fake(_ body: String) throws {
        let script = dir.appending(path: "claude")
        try """
        #!/bin/bash
        n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 )); echo $n > "\(dir.path)/n"
        cat > "\(dir.path)/ask-$n.txt"
        echo '{"type":"system","subtype":"init"}'
        \(body)
        echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        ClaudeChat.claudeOverride = script.path
    }

    func ask(_ n: Int) -> String? { try? String(contentsOf: dir.appending(path: "ask-\(n).txt"), encoding: .utf8) }
    var runs: Int { Int((try? String(contentsOf: dir.appending(path: "n"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }

    func until(_ seconds: Double = 10, _ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cleanup() {
        ClaudeChat.claudeOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aKillFromOutsideEndsTheRunAndSendsWhatWaited() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 0.8; kill -TERM $$; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        #expect(chat.running)
        chat.send("Still on it?!", title: "T", onStage: nil)
        #expect(chat.queued == ["Still on it?!"])
        await until { runs == 2 && !chat.running }
        #expect(!chat.running)
        #expect(chat.queued.isEmpty)
        #expect(chat.messages.contains { $0.role == .error && $0.text.contains("signal 15") })
        #expect(chat.messages.last { $0.role == .user }?.text == "Still on it?!")
        #expect(ask(2)?.hasPrefix(ClaudeChat.cutOffNote) == true)
        #expect(ask(2)?.hasSuffix("Still on it?!") == true)
    }

    @Test func aSteerShowsNoErrorAndGoesOn() async throws {
        defer { cleanup() }
        // The sleep outlives bash and keeps its output pipe open: the end must not wait for it.
        try fake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        try? await Task.sleep(for: .milliseconds(300))
        chat.send("Still on it?!", title: "T", onStage: nil, now: true)
        await until { runs == 2 && !chat.running }
        #expect(!chat.running)
        #expect(!chat.messages.contains { $0.role == .error })
        #expect(ask(2) == "I interrupted you.\nStill on it?!")
    }

    @Test func aChildHoldingThePipeDoesNotKeepTheChatWorking() async throws {
        defer { cleanup() }
        try fake(#"sleep 20 &"#)
        let chat = ClaudeChat(session: session)
        chat.send("Hi", title: "T", onStage: nil)
        await until(5) { !chat.running }
        #expect(!chat.running)
    }

    @Test func compactQueuesAloneAndRunsFirst() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 0.8; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        // From the phone every message steers; /compact must not become part of a steer.
        chat.send("/compact", title: "T", onStage: nil, now: true)
        chat.send("And then this", title: "T", onStage: nil)
        #expect(chat.queued == ["/compact", "And then this"])
        await until { runs == 3 && !chat.running }
        #expect(ask(2) == "/compact")
        #expect(ask(3) == "And then this")
        #expect(!chat.running)
    }

    @Test func stopEndsARunAndDropsTheQueue() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        chat.send("Later", title: "T", onStage: nil)
        try? await Task.sleep(for: .milliseconds(300))
        chat.stop()
        await until { !chat.running }
        #expect(!chat.running)
        #expect(chat.messages.last?.text == "Stopped.")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 1)
    }

    @Test func messagesThatWaitedAtAQuitGoOutOnLoad() async throws {
        defer { cleanup() }
        try fake("")
        var log = ChatLog(conversation: "c1", started: true, messages: [ChatMessage(role: .user, text: "Find posts")])
        log.pending = ["Still on it?!"]
        try JSONEncoder().encode(log).write(to: ClaudeChat.file(session))
        let chat = ClaudeChat(session: session)
        await until { runs == 1 && !chat.running }
        #expect(ask(1)?.hasSuffix("Still on it?!") == true)
        #expect(chat.queued.isEmpty)
        #expect(!chat.running)
    }

    @Test func resetWhileRunningKeepsTheNewAsk() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Old run", title: "T", onStage: nil)
        try? await Task.sleep(for: .milliseconds(300))
        // The phone's "Run now": a new conversation, then its ask at once.
        chat.reset()
        chat.send("New run", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        #expect(chat.messages.first?.text == "New run")
        #expect(!chat.messages.contains { $0.text == "Old run" })
        #expect(!chat.running)
    }
}
