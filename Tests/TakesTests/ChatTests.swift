import AppKit
import Foundation
import SwiftUI
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
        // A subagent's own steps stay hidden.
        do {
            var p = ChatParser([])
            p.consume(#"{"type":"assistant","parent_tool_use_id":"t9","message":{"content":[{"type":"text","text":"inner"}]}}"#)
            #expect(p.messages.isEmpty)
        }
    }

    @Test func toolCallRunsThenEnds() {
        var p = ChatParser([])
        p.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/b/script.md"}}]}}"#)
        #expect(p.messages.first?.text == "Read · script.md")
        #expect(p.messages.first?.done == false)
        p.consume(#"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"x"}]}}"#)
        #expect(p.messages.first?.done == true)
        // How MCP and Bash calls read.
        #expect(ChatParser.describe("mcp__takes__get_comments", [:]) == "get comments")
        #expect(ChatParser.describe("Bash", ["command": "ffmpeg -i a.mov\nmore", "description": "Cut the silences"]) == "Bash · Cut the silences")
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
        // Where each open comment is, and the label.
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
        #expect(p.compacted)
    }

    /// A compaction may drop the rules from the conversation: the app deletes the MCP's seen file,
    /// so the next get_session shows them again (2026-10-10).
    @Test func compactionResetsSeenRules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ClaudeChat.rulesSeenFile(root: root, conversation: "abc-123")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        let other = ClaudeChat.rulesSeenFile(root: root, conversation: "other-1")
        try Data("{}".utf8).write(to: other)
        var p = ChatParser([])
        #expect(!p.compacted)
        p.consume(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto"}}"#)
        #expect(p.compacted)
        ClaudeChat.forgetRules(root: root, conversation: "abc-123")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(file.path.hasSuffix("_library/.rules-seen/abc-123.json"))
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
        // Missing files and plain links stay text.
        #expect(ChatRefs.reference("/m/missing.mp4") { files.contains($0) } == nil)
        #expect(ChatRefs.reference("https://example.com/a") { _ in false } == nil)
        #expect(ChatRefs.reference("See https://x.com/a/status/1 for it") { _ in false } == nil)
        // A path in backticks or a markdown link still counts.
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

    @Test func postKeysMatchAcrossForms() {
        #expect(ChatRefs.key("https://www.linkedin.com/posts/a-1/?utm=x") == ChatRefs.key("http://linkedin.com/posts/a-1"))
        #expect(ChatRefs.key("https://twitter.com/m/status/1") == ChatRefs.key("https://x.com/m/status/1"))
    }
}

struct AgentCommandTests {
    @Test func aClaudeCodeShellShowsTheCommandItRuns() {
        let line = #"/bin/zsh -c source /Users/m/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'cd $TMPDIR/site/public && python3 -m http.server 4391 --bind 127.0.0.1' < /dev/null && pwd -P >| /tmp/claude-d961-cwd"#
        #expect(AgentCommands.shown(line) == "python3 -m http.server 4391 --bind 127.0.0.1")
        #expect(AgentCommands.shown(#"/bin/zsh -c eval 'echo '\''hi'\'' && sleep 60' < /dev/null"#) == "echo 'hi' && sleep 60")
        #expect(AgentCommands.shown("/usr/bin/python3 /x/takes_mcp.py") == nil)
    }

    @Test func elapsedTimesAndClock() {
        #expect(AgentCommands.seconds("04:12") == 252)
        #expect(AgentCommands.seconds("1-02:00:05") == 93605)
        #expect(AgentCommands.clock(252) == "4:12")
        #expect(AgentCommands.clock(3729) == "1:02:09")
    }

    @Test func aRealServerUnderAParentShowsWithItsPort() async throws {
        // A shell under this test process stands in for the agent's Bash call.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "eval 'python3 -m http.server 47391 --bind 127.0.0.1' < /dev/null"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        try await Task.sleep(for: .seconds(Double(AgentCommands.shownAfter) + 1.5))
        let found = AgentCommands.list(under: getpid()).first { $0.pid == p.processIdentifier }
        #expect(found?.command == "python3 -m http.server 47391 --bind 127.0.0.1")
        #expect(found?.port == 47391)
        AgentCommands.stop(p.processIdentifier)
        try await Task.sleep(for: .seconds(1))
        #expect(!p.isRunning)
    }

    /// TAKES_SNAPSHOT=<dir> writes the row above the message box, light and dark.
    @MainActor @Test func commandRowSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let v = VStack(spacing: 6) {
                AgentCommandChip(command: AgentCommand(pid: 1, command: "python3 -m http.server 4391 --bind 127.0.0.1", seconds: 252, port: 4391)) {}
                AgentCommandChip(command: AgentCommand(pid: 2, command: "npx hyperframes render comp.html --out edits/hook-v3.mp4", seconds: 1325)) {}
                QueuedChip(text: "shipt it") {}
            }
            .frame(width: 470).padding(20).background(Theme.raised)
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "chat-commands-\(name).png"))
        }
    }
}

struct ChatParagraphTests {

    @Test func tablesHeadingsListsCodeAndQuotesBecomeBlocks() {
        let t = """
        ## Claims
        Checks: one H1.

        | Takes claim | Source | Status |
        |---|---|---|
        | Free, MIT license | `scripts/public/LICENSE:1` | true |
        | No account | public README:17 | true |

        1. First
        2. Second
           still second
        - a bullet
          - nested

        > a quote
        > two lines

        ```
        let a = 1 | 2
        ```
        ---
        Ship it?
        """
        #expect(ChatRefs.blocks(t) == [
            .heading(2, "Claims"),
            .text(["Checks: one H1."]),
            .table([["Takes claim", "Source", "Status"],
                    ["Free, MIT license", "`scripts/public/LICENSE:1`", "true"],
                    ["No account", "public README:17", "true"]]),
            .list([ChatListItem(depth: 0, mark: "1.", text: "First"),
                   ChatListItem(depth: 0, mark: "2.", text: "Second still second"),
                   ChatListItem(depth: 0, mark: nil, text: "a bullet"),
                   ChatListItem(depth: 1, mark: nil, text: "nested")]),
            .quote("a quote\ntwo lines"),
            .code("let a = 1 | 2"),
            .rule,
            .text(["Ship it?"]),
        ])
        // Blank lines and lists split paragraphs.
        do {
            let t = "Intro line\nmore\n\n- one\n- two\nAfter the list"
            #expect(ChatRefs.paragraphs(t) == [["Intro line", "more"], ["- one", "- two"], ["After the list"]])
            #expect(ChatRefs.bullet("- **Bold.** rest") == "**Bold.** rest")
        }
    }

    @Test func aTableWithoutItsSeparatorYetStaysText() {
        // While a reply streams in, the header row comes before the separator line.
        #expect(ChatRefs.blocks("| a | b |") == [.text(["| a | b |"])])
        #expect(ChatRefs.blocks("**Bold.** rest\n- one") == [.text(["**Bold.** rest"]), .list([ChatListItem(depth: 0, mark: nil, text: "one")])])
    }

    /// TAKES_SNAPSHOT=<dir> writes the reply as the chat panel draws it, light and dark.
    @MainActor @Test func aRichReplySnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let reply = """
        **Checks:** one H1, no sideways scroll at 390 wide, every image loads.

        ## Claims on the page

        | Takes claim | Source | Status |
        |---|---|---|
        | Free, MIT license | `scripts/public/LICENSE:1` | true |
        | Needs macOS 15, Apple silicon | Package.swift:6 | true |
        | Text follows your voice in the script's language | ScriptFollower.swift:91 | true |
        | Mirrored text in its own window | Notch.swift:522, Views.swift:2752 | true |
        | No account | public README:17 | true |

        1. Ship the page
        2. Check the sitemap
        - a bullet with **bold**
          - nested one

        > Remote: keyboard only, no phone remote in the source.

        ```
        ./build.sh install
        ```
        ---
        Ship it?
        """
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let v = ChatReply(text: reply).frame(width: 470).padding(20).background(Theme.paper)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "chat-rich-\(name).png"))
        }
    }

    @MainActor @Test func everyToolRunIsOneTimeline() {
        let tool = { (t: String) in ChatMessage(role: .tool, text: t) }
        let msgs = [tool("computer"), tool("computer"), ChatMessage(role: .claude, text: "ok"),
                    tool("computer"), tool("javascript tool"), tool("computer"), tool("Bash · ls")]
        let items = ChatItem.group(msgs)
        #expect(items.count == 3)
        guard case .tools(let run) = items[2] else { Issue.record("no run"); return }
        #expect(run.count == 4)
        #expect(ChatItem.summary(run) == "4 steps · computer, javascript tool, Bash")
        // A job's note stays its own line and does not fold into the steps.
        let note = ChatMessage(role: .tool, text: "Render edit v3 is done", toolID: ChatMessage.jobNote)
        let tools = (1...3).map { ChatMessage(role: .tool, text: "Bash · step \($0)", toolID: "t\($0)") }
        let noted = ChatItem.group([note] + tools)
        #expect(noted.count == 2)
        if case .message(let m) = noted[0] { #expect(m.isJobNote) } else { Issue.record("the note was folded") }
        if case .tools(let t) = noted[1] { #expect(t.count == 3) } else { Issue.record("the steps did not fold") }
        #expect(ClaudeChat.recap([note]).contains("Render edit v3 is done"))
    }

    @Test func callsOfOneToolInARowJoin() {
        let tool = { (t: String, done: Bool) in ChatMessage(role: .tool, text: t, done: done) }
        let steps = StepWords.steps([tool("get session", true), tool("Read · cut.md", true), tool("Read · captions.md", true),
                                     tool("Read · hooks.md", false), tool("computer", true), tool("computer", true),
                                     tool("Bash · Cut the silences", true), tool("Bash · Check the stills", true)])
        #expect(steps.map(\.count) == [1, 3, 2, 1, 1])
        #expect(steps[1].run == "Reading 3 files" && !steps[1].done)
        #expect(steps[1].chips == ["cut.md", "captions.md", "hooks.md"])
        #expect(steps[2].finished == "Worked in Chrome · 2")
        #expect(steps[0].chips.isEmpty)
        var failed = tool("Read · desk.mov", true)
        failed.failed = true
        let dead = StepWords.steps([tool("Read · cut.md", true), failed])
        #expect(dead.count == 2 && dead[1].failed && !dead[0].failed)
        #expect(StepWords.time(72) == "1m 12s" && StepWords.time(9) == "9s")
        // Each step's words change tense when done.
        do {
            func w(_ line: String) -> (String, String) {
                let (tool, d) = StepWords.split(line)
                let r = StepWords.words(tool, details: d.map { [$0] } ?? [], count: 1)
                return (r.run, r.done)
            }
            #expect(w("get session") == ("Opening the session", "Opened the session"))
            #expect(w("Read · script.md") == ("Reading script.md", "Read script.md"))
            #expect(w("Bash · Cut the silences") == ("Cutting the silences", "Cut the silences"))
            #expect(w("Bash · List the stills") == ("Listing the stills", "Listed the stills"))
            #expect(w("Bash · Render edit v3") == ("Rendering edit v3", "Rendered edit v3"))
            #expect(w("Bash · Make a thumbnail") == ("Making a thumbnail", "Made a thumbnail"))
            #expect(w("Grep · silence") == ("Searching for “silence”", "Searched for “silence”"))
            #expect(w("set post hooks") == ("Writing hooks", "Wrote hooks"))
            #expect(w("add broll") == ("Adding the broll", "Added the broll"))
            #expect(w("Bash · ffmpeg -i a.mov").0 == "Running a command")
        }
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

    // 2026-10-11: a trashed session's chat searched every chat log again on each session opened.
    @Test func aTrashedSessionIsSearchedForOnce() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "follow-\(UUID().uuidString)")
        let old = root.appending(path: "P/2026-10-01-a"), later = root.appending(path: "P/2026-10-01-b")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let log = try JSONEncoder().encode(ChatLog(conversation: "c7", started: true, messages: []))
        try log.write(to: ClaudeChat.file(old))
        let chat = ChatHub().chat(old)
        try fm.removeItem(at: old)           // trashed
        #expect(!chat.follow())
        try fm.createDirectory(at: later, withIntermediateDirectories: true)
        try log.write(to: ClaudeChat.file(later))
        #expect(!chat.follow())              // no second walk of the library
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

    /// The browser extension's "Record in Takes": a new Inbox session with the words as its
    /// script, left as a notice; the screen stays where it was.
    @Test func recordInTakesAddsAnInboxSession() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "new-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appending(path: "P"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = AppModel()
        let home = app.library.root
        defer { app.library.setRoot(home) }
        app.library.setRoot(root)
        var c = URLComponents(string: "takes://new")!
        c.queryItems = [.init(name: "text", value: "  Most founders never post video.\nHere is why.  "),
                        .init(name: "title", value: "Why founders skip video")]
        app.handle(url: c.url!)
        let made = try #require(app.notices.first?.session)
        #expect(made.deletingLastPathComponent().lastPathComponent == "Inbox")
        #expect(made.lastPathComponent.hasSuffix("-why-founders-skip-video"))
        #expect(try String(contentsOf: made.appending(path: "script.md"), encoding: .utf8)
                == "Most founders never post video.\nHere is why.\n")
        #expect(SessionDoc(url: made).meta.title == "Why founders skip video")
        #expect(app.library.current == nil)
        // No words, no session.
        app.handle(url: URL(string: "takes://new?title=Empty")!)
        #expect(app.notices.count == 1)
        // The link exactly as the extension writes it (extension/takes.js, encodeURIComponent).
        app.handle(url: URL(string: "takes://new?text=Hi%20%26%20bye%3F%0A%232&title=A%2FB%20title")!)
        let second = try #require(app.notices.last?.session)
        #expect(try String(contentsOf: second.appending(path: "script.md"), encoding: .utf8) == "Hi & bye?\n#2\n")
        #expect(SessionDoc(url: second).meta.title == "A/B title")
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
        # Only chat turns count: a sign-in check another test starts may call this too.
        case "$1" in auth|mcp|--version) exit 0;; esac
        n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 ))
        # The ask is whole before the run counts: a test that sees the run reads all of it.
        cat > "\(dir.path)/ask-$n.part"; mv "\(dir.path)/ask-$n.part" "\(dir.path)/ask-$n.txt"; echo $n > "\(dir.path)/n"
        echo '{"type":"system","subtype":"init"}'
        \(body)
        echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        ClaudeChat.claudeOverride = script.path
    }

    func ask(_ n: Int) -> String? { try? String(contentsOf: dir.appending(path: "ask-\(n).txt"), encoding: .utf8) }
    var runs: Int { Int((try? String(contentsOf: dir.appending(path: "n"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }

    /// Waits until `ok`. The deadline only matters when the test fails: a busy Mac (load 20+)
    /// took over 10 s for a fast fake run.
    func until(_ seconds: Double = 30, _ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Bash that waits until the test calls `openGate()`, or until its folder is gone. In place of
    /// a fixed sleep: the run ends when the test or the chat ends it, never because the Mac was slow.
    var gate: String { #"while [ -d "\#(dir.path)" ] && [ ! -e "\#(dir.path)/gate" ]; do sleep 0.05; done"# }
    func openGate() { FileManager.default.createFile(atPath: dir.appending(path: "gate").path, contents: nil) }

    func cleanup() {
        ClaudeChat.claudeOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// 2026-10-11: after a rename the waiting message went out with the old title, and the agent kept
    /// the old path. The chat follows the folder first; its context names the new title and the id.
    @Test func chatFollowsRenameBeforeTitle() async throws {
        defer { cleanup() }
        try fake(#"printf '%s\n' "$@" > "$(dirname "$0")/args-$n.txt""#)
        try Store.encoder.encode(SessionMeta(title: "Old", createdAt: Date())).write(to: session.appending(path: "session.json"))
        try JSONEncoder().encode(ChatLog(conversation: "c-rename", pending: ["Cut it"])).write(to: ClaudeChat.file(session))
        let chat = ClaudeChat(session: session)  // sends what waited, on the next turn
        let renamed = session.deletingLastPathComponent().appending(path: "2026-10-03-new-title")
        try FileManager.default.moveItem(at: session, to: renamed)
        try Store.encoder.encode(SessionMeta(title: "New title", createdAt: Date())).write(to: renamed.appending(path: "session.json"))
        await until(30) { runs == 1 && !chat.running }
        let args = (try? String(contentsOf: dir.appending(path: "args-1.txt"), encoding: .utf8)) ?? ""
        #expect(args.contains("\"New title\", folder \(renamed.standardizedFileURL.path)"))
        #expect(args.contains("session id \(Store.derivedID(renamed) ?? "?")"))
        #expect(FileManager.default.fileExists(atPath: renamed.appending(path: ".claude-chat.json").path))
        #expect(!FileManager.default.fileExists(atPath: session.path), "the old folder never comes back")
    }

    /// Takes chats compact at 30% of the window; the variable lives only in their process.
    @Test func chatsCompactEarly() {
        let env = ClaudeChat.environment()
        #expect(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] == "30")
        // The takes MCP loads its main tools at the start only in Takes' own chats.
        #expect(env["TAKES_CHAT"] == "1")
        #expect(!env.keys.contains { $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("CLAUDECODE") })
        // A board's chat says which board it is.
        #expect(ClaudeChat.environment()["TAKES_BOARD"] == nil)
        #expect(ClaudeChat.environment(board: "styles")["TAKES_BOARD"] == "styles")
        #expect(ClaudeChat.environment(board: "styles")["TAKES_CHAT"] == "1")
    }

    @Test func aKillFromOutsideEndsTheRunAndSendsWhatWaited() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 0.8; kill -TERM $$; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        #expect(chat.running)
        chat.send("Still on it?!", title: "T", onStage: nil)
        #expect(chat.queued == ["Still on it?!"])
        // 30 s: under a busy build (load 20) the second run took longer than 10 s.
        await until(30) { runs == 2 && !chat.running }
        #expect(!chat.running)
        #expect(chat.queued.isEmpty)
        #expect(chat.messages.contains { $0.role == .error && $0.text.contains("signal 15") })
        #expect(chat.messages.last { $0.role == .user }?.text == "Still on it?!")
        #expect(ask(2)?.hasPrefix(ClaudeChat.cutOffNote) == true)
        #expect(ask(2)?.hasSuffix("Still on it?!") == true)
    }

    /// 2026-10-10: an update quit Takes under two chats, and their work stopped for good. A cut
    /// chat now keeps a "go on" and sends it when it opens again.
    @Test func aChatCutOffByAQuitGoesOnAtTheNextLaunch() async throws {
        defer { cleanup() }
        try fake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        let chat = ClaudeChat(session: session)
        chat.send("Make the cut", title: "T", onStage: nil)
        await until { runs == 1 }
        chat.quit()
        #expect(chat.queued == [ClaudeChat.goOn])
        let next = ClaudeChat(session: session)  // the next launch
        await until(30) { runs == 2 && !next.running }
        #expect(ask(2)?.hasSuffix(ClaudeChat.goOn) == true)
        #expect(next.queued.isEmpty)
        // A message that waited at the quit goes out on load, and the chat settles.
        #expect(!next.running)
    }

    @Test func aSteerShowsNoErrorAndGoesOn() async throws {
        defer { cleanup() }
        // Run 1 waits on a gate that never opens. Its child outlives bash and keeps the output pipe
        // open: the end must not wait for it.
        try fake("if [ $n = 1 ]; then \(gate) & \(gate); fi")
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        // Steer once run 1 counted (2026-10-21): a steer before bash saved ask-1 made the next run
        // number 1 again, and it waited.
        await until { runs == 1 }
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

    /// 2026-10-19: what the user does on a board shows as its own line, and the agent gets it once,
    /// with the next message, without a reply of its own.
    @Test func boardActionsShowAndReachTheAgentOnce() async throws {
        defer { cleanup() }
        try fake("")
        let chat = ClaudeChat(session: session)
        let id = chat.action("Suggest now: picking three searches", running: true)
        #expect(chat.messages.count == 1 && !chat.messages[0].done && chat.messages[0].isActionNote)
        chat.action("Suggest now picked “a”, “b” and “c”", agent: "Picked a, b and c, because of the numbers", update: id)
        chat.action("Showing 7 days: 10 visits")
        #expect(chat.messages.map(\.text) == ["Suggest now picked “a”, “b” and “c”", "Showing 7 days: 10 visits"])
        #expect(chat.messages.allSatisfy { $0.done && $0.isActionNote })
        #expect(ChatItem.group(Array(repeating: chat.messages[1], count: 6)).count == 6, "own lines, never folded into steps")
        #expect(runs == 0, "an action starts no reply")
        chat.send("What happened?", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        let first = ask(1) ?? ""
        #expect(first.contains("Picked a, b and c, because of the numbers") && first.contains("Showing 7 days: 10 visits"))
        #expect(!first.contains("picking three searches"), "a running line is not told; its result is")
        chat.send("And now?", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        #expect(!(ask(2) ?? "").contains("Showing 7 days"), "told once")
    }

    @Test func compactQueuesAloneAndRunsFirst() async throws {
        defer { cleanup() }
        try fake("if [ $n = 1 ]; then \(gate); fi")
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        // From the phone every message steers; /compact must not become part of a steer.
        chat.send("/compact", title: "T", onStage: nil, now: true)
        chat.send("And then this", title: "T", onStage: nil)
        #expect(chat.queued == ["/compact", "And then this"])
        // Run 1 goes on: a steer would have ended it.
        await until { runs == 1 }
        #expect(chat.running && chat.queued == ["/compact", "And then this"])
        openGate()
        await until { runs == 3 && !chat.running }
        #expect(ask(2) == "/compact")
        #expect(ask(3) == "And then this")
        #expect(!chat.running)
    }

    @Test func stopEndsARunAndDropsTheQueue() async throws {
        defer { cleanup() }
        try fake("if [ $n = 1 ]; then \(gate); fi")
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        chat.send("Later", title: "T", onStage: nil)
        // Until the first run started: a fixed 300 ms stopped it before it ran on a busy Mac (2026-10-20).
        await until { runs == 1 }
        chat.stop()
        await until { !chat.running }
        #expect(!chat.running)
        #expect(chat.messages.last?.text == "Stopped.")
        // Nothing waits, so nothing can run later: no fixed wait to prove it.
        #expect(chat.queued.isEmpty)
        #expect(runs == 1)
    }

    @Test func resetWhileRunningKeepsTheNewAsk() async throws {
        defer { cleanup() }
        try fake("if [ $n = 1 ]; then \(gate); fi")
        let chat = ClaudeChat(session: session)
        chat.send("Old run", title: "T", onStage: nil)
        await until { runs == 1 }
        // The phone's "Run now": a new conversation, then its ask at once.
        chat.reset()
        chat.send("New run", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        #expect(chat.messages.first?.text == "New run")
        #expect(!chat.messages.contains { $0.text == "Old run" })
        #expect(!chat.running)
    }
}

@MainActor
struct ChatTimelineSnapshots {
    /// The timeline in four moments of one run, to look at. `TAKES_SNAPSHOT=/some/dir`.
    @Test func snapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let t0 = Date().addingTimeInterval(-12)
        func m(_ role: ChatMessage.Role, _ text: String, _ s: Double, done: Bool = true, failed: Bool = false) -> ChatMessage {
            var x = ChatMessage(role: role, text: text, toolID: role == .tool ? UUID().uuidString : nil, done: done)
            x.at = t0.addingTimeInterval(s)
            if failed { x.failed = true }
            return x
        }
        let ask = m(.user, "Cut the silences in today's keeper take and draft the LinkedIn post for it.", 0)
        let early = [ask, m(.tool, "get session", 0.4), m(.tool, "Read · cut.md", 1.6), m(.tool, "Read · captions.md", 2.0),
                     m(.tool, "Read · hooks.md", 2.4, done: false)]
        let mid = [ask, m(.tool, "get session", 0.4), m(.tool, "Read · cut.md", 1.6), m(.tool, "Read · captions.md", 2.0),
                   m(.tool, "Read · hooks.md", 2.4), m(.tool, "Read · desk.mov", 3.5, failed: true),
                   m(.tool, "find words", 5.2), m(.tool, "Bash · Cut the silences", 6.8, done: false)]
        let done = mid.dropLast() + [m(.tool, "Bash · Cut the silences", 6.8), m(.tool, "Bash · Check the stills", 10.1),
                                     m(.tool, "set post", 12.3), m(.tool, "set post hooks", 14.0),
                                     m(.claude, "Done. The cut is 1:42 and the post has 3 hooks to pick from.", 17.2)]
        let folded = Array(done) + [m(.user, "Make it vertical too.", 40)]
        // The narrowest chat (360 pt) with long file names: the chips must stay inside (2026-10-12).
        let long = [ask, m(.tool, "Read · 2026-10-12-teleprompter-hook-take-03-camera-transcript.md", 0.4),
                    m(.tool, "Read · 2026-10-12-teleprompter-hook-take-04-camera-transcript.md", 0.8),
                    m(.tool, "Read · 2026-10-12-teleprompter-hook-captions-final.md", 1.2),
                    m(.tool, "Read · 2026-10-12-teleprompter-hook-post-draft.md", 1.6),
                    m(.claude, "Read the four files.", 3)]
        let shots: [(String, [ChatMessage], Bool, Bool)] = [
            ("1-early", early, true, false), ("2-mid", mid, true, false),
            ("3-done", Array(done), false, false), ("4-folded", folded, false, false), ("5-done-dark", Array(done), false, true),
            ("6-narrow-long", long, false, false),
        ]
        for (name, msgs, running, dark) in shots {
            let width: CGFloat = name.hasPrefix("6") ? 360 : 420
            let view = ChatTranscript(messages: msgs, running: running)
                .padding(16).frame(width: width, height: 520, alignment: .top).background(Theme.raised)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 520),
                               styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appending(path: "timeline-\(name).png"))
        }
    }
}
