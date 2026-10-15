import Foundation
import Testing
@testable import Takes

// Long jobs (Jobs.swift, 2026-10-10): the board reads the job files the takes MCP writes, shows them
// in the session's Jobs row and tells the chat when one ends. Temp folders only.

/// A temp session with job files, written the way takes_mcp.py writes them.
struct JobFixture {
    let root: URL
    let session: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "jobs-\(UUID().uuidString)")
        session = root.appending(path: "Launch/2026-10-10-demo")
        try FileManager.default.createDirectory(at: session.appending(path: ".jobs"), withIntermediateDirectories: true)
        try #"{"title": "Demo", "createdAt": "2026-10-10T00:00:00Z", "named": true, "takes": []}"#
            .write(to: session.appending(path: "session.json"), atomically: true, encoding: .utf8)
    }

    static func iso(_ ago: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date().addingTimeInterval(-ago))
    }

    /// Writes .jobs/<id>.json (or generated/.jobs with `generate`).
    @discardableResult
    func job(_ id: String, _ fields: [String: Any], generate: Bool = false) throws -> URL {
        let folder = session.appending(path: generate ? "generated/.jobs" : ".jobs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var d: [String: Any] = ["v": 1, "id": id, "label": "Render edit v3", "outputs": ["edits/launch-v3.mp4"],
                                "from_chat": true, "status": "running", "started": Self.iso(5)]
        d.merge(fields) { $1 }
        let url = folder.appending(path: "\(id).json")
        try JSONSerialization.data(withJSONObject: d).write(to: url)
        return url
    }

    /// Holds a job's lock the way its runner does, until `release`.
    func hold(_ id: String, generate: Bool = false) -> Int32 {
        let path = session.appending(path: (generate ? "generated/.jobs/" : ".jobs/") + id + ".lock").path
        // O_CLOEXEC: a process another test starts must not keep the lock after close (lostRule failed so).
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        flock(fd, LOCK_EX)
        return fd
    }

    /// The runner died. Unlock before close: a process another test spawned at that moment can
    /// hold a copy of the fd for a while, and close alone leaves the lock with that copy.
    func drop(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct JobsTests {
    @Test func decodesBothStores() throws {
        let f = try JobFixture()
        defer { f.cleanup() }
        try f.job("job-7f3a1c", ["status": "done", "ended": JobFixture.iso(1), "progress": 1, "future_key": [1, 2]])
        try f.job("shot-3-v2", ["kind": "video", "file": "generated/shot-3-v2.mp4", "status": "error",
                                "error": "Session expired.", "label": NSNull()], generate: true)
        try f.job("rep-1-v1", ["provider": "replicate", "kind": "video", "file": "generated/rep-1-v1.mp4",
                               "label": "Seedance 2.5 clip for shot 3", "status": "done"], generate: true)
        try Data(#"{"id": "job-bro"#.utf8).write(to: f.session.appending(path: ".jobs/job-broken.json"))
        let jobs = JobBoard.load(f.session)
        #expect(jobs.count == 3)
        let mine = try #require(jobs.first { $0.id == "job-7f3a1c" })
        #expect(mine.status == .done && !mine.isGenerate && mine.icon == "film" && mine.fromChat)
        let hf = try #require(jobs.first { $0.id == "shot-3-v2" })
        #expect(hf.status == .failed && hf.isGenerate && hf.label == "shot-3-v2" && hf.icon == "sparkles" && !hf.stoppable)
        #expect(hf.outputs == ["generated/shot-3-v2.mp4"])
        #expect(hf.session == f.session.standardizedFileURL)
        #expect(jobs.first { $0.id == "rep-1-v1" }?.label == "Seedance 2.5 clip for shot 3")
    }

    @Test func lostRule() throws {
        let f = try JobFixture()
        defer { f.cleanup() }
        try f.job("job-aaaaaa", ["status": "running"])
        let fd = f.hold("job-aaaaaa")
        #expect(JobBoard.load(f.session).first?.status == .running)
        f.drop(fd)  // the runner died
        #expect(JobBoard.load(f.session).first?.status == .lost)
        try f.job("job-aaaaaa", ["status": "starting", "started": JobFixture.iso(5)])
        #expect(JobBoard.load(f.session).first?.status == .starting)
        try f.job("job-aaaaaa", ["status": "starting", "started": JobFixture.iso(31)])
        #expect(JobBoard.load(f.session).first?.status == .lost)
        // A Higgsfield file from before locks: the clock decides. With a held lock, it runs.
        try FileManager.default.removeItem(at: f.session.appending(path: ".jobs/job-aaaaaa.json"))
        try f.job("shot-1-v1", ["status": "running", "started": JobFixture.iso(60 * 60)], generate: true)
        #expect(JobBoard.load(f.session).first?.status == .running)
        try f.job("shot-1-v1", ["status": "running", "started": JobFixture.iso(100 * 60)], generate: true)
        #expect(JobBoard.load(f.session).first?.status == .lost)
        let g = f.hold("shot-1-v1", generate: true)
        #expect(JobBoard.load(f.session).first?.status == .running)
        f.drop(g)
        #expect(JobBoard.load(f.session).first?.status == .lost)  // a free lock file: its runner is gone
    }

    @Test func rowCopy() {
        let now = Date()
        var j = Job(id: "job-1", label: "Render edit v3", outputs: ["edits/launch-v3.mp4"], fromChat: true, status: .starting,
                    started: now.addingTimeInterval(-20), isGenerate: false, folder: URL(fileURLWithPath: "/tmp/s/.jobs"))
        #expect(JobBoard.line(j, now: now) == "Just started")
        j.status = .running
        #expect(JobBoard.line(j, now: now) == "Just started")
        j.started = now.addingTimeInterval(-200)
        #expect(JobBoard.line(j, now: now) == "3 min")
        j.progress = 0.42; j.eta = 120
        #expect(JobBoard.line(j, now: now) == "42% · about 2 min left")
        j.eta = 40
        #expect(JobBoard.line(j, now: now) == "42% · less than a minute left")
        var g = j; g.isGenerate = true; g.progress = nil
        #expect(JobBoard.line(g, now: now) == "Making the clip · 3 min")
        j.status = .done
        #expect(JobBoard.line(j, now: now) == "Ready")
        j.status = .failed
        #expect(JobBoard.line(j, woken: true, now: now) == "Render edit v3 did not finish. Takes is on it.")
        #expect(JobBoard.line(j, now: now) == "Render edit v3 did not finish.")
        #expect(JobBoard.line(j, again: true, now: now) == "Render edit v3 did not finish again.")
        j.status = .lost
        #expect(JobBoard.line(j, now: now) == "Render edit v3 stopped. The Mac restarted or the job quit.")
        j.status = .stopped; j.stoppedBy = "you"
        #expect(JobBoard.line(j, now: now) == "You stopped it")
        j.stoppedBy = "takes"
        #expect(JobBoard.line(j, now: now) == "Takes stopped it")
        #expect(JobBoard.duration(212) == "3 min 32 s")
        #expect(JobBoard.duration(45) == "45 s")
    }

    @Test func notesSayWhatToDoNext() {
        let start = Date().addingTimeInterval(-212)
        let done = Job(id: "job-7f3a1c", label: "Render edit v3", outputs: ["edits/launch-v3.mp4"], fromChat: true, status: .done,
                       started: start, ended: start.addingTimeInterval(212), isGenerate: false, folder: URL(fileURLWithPath: "/tmp/s/.jobs"))
        #expect(JobBoard.note(for: [done]) == "[Takes] Job job-7f3a1c ended: Render edit v3 is done after 3 min 32 s. It wrote edits/launch-v3.mp4. Go on with the next step you planned. If nothing is left, tell the user in one line.")
        var failed = done
        failed.status = .failed; failed.error = "boom"; failed.ended = start.addingTimeInterval(64)
        #expect(JobBoard.note(for: [failed]) == "[Takes] Job job-7f3a1c failed after 1 min 4 s: boom. get_job id=job-7f3a1c has the log. Fix it and run it again, or tell the user in one line what went wrong.")
        #expect(JobBoard.note(for: [done, failed]).split(separator: "\n").count == 2)
        // A lost job's note names the job and where its command is: the chat may have lost both.
        var lost = done
        lost.status = .lost
        #expect(JobBoard.note(for: [lost]) == "[Takes] Job job-7f3a1c stopped: Render edit v3 did not finish, because the Mac restarted or the job quit. get_job id=job-7f3a1c gives its command: run it again with run_job and new outputs from next_path.")
        #expect(JobBoard.tick(done).text == "Render edit v3 is done" && JobBoard.tick(done).isJobNote)
        #expect(JobBoard.tick(failed).text == "Render edit v3 did not finish" && JobBoard.tick(failed).role == .tool)
    }

    @MainActor @Test func visibleRules() throws {
        let f = try JobFixture()
        defer { f.cleanup() }
        let defaults = try #require(UserDefaults(suiteName: "jobs-test-\(UUID().uuidString)"))
        try f.job("job-done", ["status": "done", "ended": JobFixture.iso(10)])
        try f.job("job-fail", ["status": "failed", "ended": JobFixture.iso(10), "outputs": []])
        try f.job("job-stop", ["status": "stopped", "stopped_by": "you", "ended": JobFixture.iso(1)])
        try f.job("job-old", ["status": "done", "started": JobFixture.iso(90000), "ended": JobFixture.iso(90000)])
        try FileManager.default.createDirectory(at: f.session.appending(path: ".jobs/job-fail.partial"), withIntermediateDirectories: true)
        let board = JobBoard(defaults: defaults)
        board.scan(root: f.root)
        var ids = Set(board.visible(f.session).map(\.id))
        #expect(ids == ["job-done", "job-fail", "job-stop"])
        #expect(!board.visible(f.session, now: Date().addingTimeInterval(6)).contains { $0.id == "job-stop" })
        let all = JobBoard.load(f.session)
        board.seen(try #require(all.first { $0.id == "job-done" }))
        board.dismiss(try #require(all.first { $0.id == "job-fail" }))
        ids = Set(board.visible(f.session).map(\.id))
        #expect(ids == ["job-stop"])
        #expect(!FileManager.default.fileExists(atPath: f.session.appending(path: ".jobs/job-fail.partial").path))
        // Seen and closed rows stay gone after a quit.
        let again = JobBoard(defaults: defaults)
        again.scan(root: f.root)
        #expect(Set(again.visible(f.session).map(\.id)) == ["job-stop"])
    }

    /// The chat's row: what runs, and ends the chat never hears about. The chat tells the rest itself.
    @MainActor @Test func rowRules() throws {
        let f = try JobFixture()
        defer { f.cleanup() }
        let defaults = try #require(UserDefaults(suiteName: "jobs-test-\(UUID().uuidString)"))
        try f.job("job-run", [:])
        try f.job("job-done", ["status": "done", "ended": JobFixture.iso(10)])
        try f.job("job-fail", ["status": "failed", "ended": JobFixture.iso(10)])
        try f.job("job-lost", ["status": "lost", "ended": JobFixture.iso(10)])
        try f.job("job-mine", ["status": "failed", "from_chat": false, "ended": JobFixture.iso(10)])
        try f.job("job-stop", ["status": "stopped", "stopped_by": "you", "ended": JobFixture.iso(1)])
        let board = JobBoard(defaults: defaults)
        board.scan(root: f.root)
        #expect(Set(board.row(f.session).map(\.id)) == ["job-run", "job-lost", "job-mine"])
    }

    @Test func watcherRoutesJobFiles() {
        let s = "/Movies/Takes/p/2026-10-10-demo"
        let paths = [s + "/.jobs/job-1.json", s + "/.jobs/job-1.log", s + "/.jobs/job-1.lock", s + "/.jobs/job-1.json.tmp",
                     s + "/.jobs/job-1.partial/a.mp4", s + "/generated/.jobs/shot-1-v1.json", s + "/.jobs/job-1.told",
                     "/Movies/Takes/.jobs.claims"]
        #expect(FileWatch.folders(paths).isEmpty)
        #expect(FileWatch.jobSessions(paths) == [s])
        #expect(FileWatch.folders(paths + [s + "/edits/launch-v3.mp4"]) == [s + "/edits"])
    }

    @MainActor @Test func noteLineStaysVisible() {
        let note = ChatMessage(role: .tool, text: "Render edit v3 is done", toolID: ChatMessage.jobNote)
        let tools = (1...3).map { ChatMessage(role: .tool, text: "Bash · step \($0)", toolID: "t\($0)") }
        let items = ChatItem.group([note] + tools)
        #expect(items.count == 2)
        if case .message(let m) = items[0] { #expect(m.isJobNote) } else { Issue.record("the note was folded") }
        if case .tools(let t) = items[1] { #expect(t.count == 3) } else { Issue.record("the steps did not fold") }
        #expect(ClaudeChat.recap([note]).contains("Render edit v3 is done"))
    }

    @Test func twoStepStop() {
        var arm = StopArm()
        let t0 = Date()
        let first = arm.click("a", now: t0)
        #expect(!first)
        #expect(arm.asking("a", now: t0.addingTimeInterval(1)))
        let second = arm.click("a", now: t0.addingTimeInterval(2))
        #expect(second)
        #expect(!arm.asking("a", now: t0.addingTimeInterval(2)))
        let late = arm.click("a", now: t0.addingTimeInterval(10))
        #expect(!late)
        #expect(!arm.asking("a", now: t0.addingTimeInterval(14)))  // 3 s later it resets
        let again = arm.click("a", now: t0.addingTimeInterval(14))
        #expect(!again)
    }

    @Test func chatEnvTellsBoardsApart() {
        #expect(ClaudeChat.environment()["TAKES_BOARD"] == nil)
        #expect(ClaudeChat.environment(board: "styles")["TAKES_BOARD"] == "styles")
        #expect(ClaudeChat.environment(board: "styles")["TAKES_CHAT"] == "1")
    }

    @Test func toldIsClaimedOnce() throws {
        let f = try JobFixture()
        defer { f.cleanup() }
        let told = f.session.appending(path: ".jobs/job-1.told")
        #expect(JobBoard.claimTold(told))
        #expect(!JobBoard.claimTold(told))
    }
}

// The chat-side tests run a fake claude, so they join ChatRunTests: its tests run one at a time,
// and the fake claude is one setting for all of them.
extension ChatRunTests {
    func board(_ chat: ClaudeChat) throws -> JobBoard {
        let b = JobBoard(defaults: try #require(UserDefaults(suiteName: "jobs-test-\(UUID().uuidString)")))
        b.chatFor = { _ in chat }
        ClaudeChat.heldNotes = { [b] s in b.takeHeld(s) }
        return b
    }

    func jobFile(_ id: String, _ fields: [String: Any]) throws {
        let folder = session.appending(path: ".jobs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var d: [String: Any] = ["v": 1, "id": id, "label": "Render edit v3", "outputs": ["edits/launch-v3.mp4"],
                                "from_chat": true, "status": "done", "started": JobFixture.iso(60), "ended": JobFixture.iso(1)]
        d.merge(fields) { $1 }
        try JSONSerialization.data(withJSONObject: d).write(to: folder.appending(path: "\(id).json"))
    }

    func told(_ id: String) -> Bool { FileManager.default.fileExists(atPath: session.appending(path: ".jobs/\(id).told").path) }

    @Test func aJobEndWakesTheChatOnceWithATickLine() async throws {
        defer { cleanup(); ClaudeChat.heldNotes = nil }
        try fake("")
        let chat = ClaudeChat(session: session)
        let b = try board(chat)
        try jobFile("job-1", [:])
        try jobFile("job-2", ["status": "failed", "error": "boom", "started": JobFixture.iso(30)])
        try jobFile("job-3", ["stopped_by": "you", "status": "stopped"])
        try jobFile("job-4", ["from_chat": false])
        try jobFile("job-5", ["status": "running"])  // lost: never told by itself
        b.reload(session)
        await until { runs == 1 && !chat.running }
        let sent = try #require(ask(1))
        #expect(sent.contains("[Takes] Job job-1 ended") && sent.contains("[Takes] Job job-2 failed"))
        #expect(!sent.contains("job-3") && !sent.contains("job-4") && !sent.contains("job-5"))
        #expect(told("job-1") && told("job-2") && !told("job-4"))
        // The panel: two tick lines, no message from the user, nothing red.
        #expect(chat.messages.filter(\.isJobNote).map(\.text) == ["Render edit v3 is done", "Render edit v3 did not finish"])
        #expect(!chat.messages.contains { $0.role == .user || $0.role == .error })
        b.reload(session)  // the same ends again: nothing new
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 1)
        #expect(b.woken.count == 1 && b.woken.first?.contains("/job-2@") == true)  // "Takes is on it."
    }

    @Test func endsAtLaunchOrAfterAStopWaitForTheNextMessage() async throws {
        defer { cleanup(); ClaudeChat.heldNotes = nil }
        try fake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        let chat = ClaudeChat(session: session)
        let b = try board(chat)
        try jobFile("job-1", [:])
        b.scan(root: dir)  // the launch: nothing wakes
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 0)
        #expect(!told("job-1"))
        // The user stops a run; a job that ends then waits too.
        chat.send("Make the cut", title: "T", onStage: nil)
        await until { runs == 1 }
        // His message carries the end that waited since the launch.
        #expect(ask(1)?.hasPrefix("[Takes] Job job-1 ended") == true)
        #expect(ask(1)?.hasSuffix("Make the cut") == true)
        #expect(told("job-1"))
        chat.stop()
        await until { !chat.running }
        try jobFile("job-2", ["started": JobFixture.iso(30)])
        b.reload(session)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 1)
        #expect(!told("job-2"))
        // His next message carries it in front, and the panel shows it as a tick line.
        chat.send("What now?", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        let sent = try #require(ask(2))
        #expect(sent.hasPrefix("[Takes] Job job-2 ended") && sent.hasSuffix("What now?"))
        #expect(!sent.contains("job-1"))
        #expect(told("job-2"))
        #expect(chat.messages.last { $0.role == .user }?.text == "What now?")
        #expect(chat.messages.filter(\.isJobNote).count == 2)
    }

    @Test func aBusyChatHearsAboutAJobWhenItIsDone() async throws {
        defer { cleanup(); ClaudeChat.heldNotes = nil }
        try fake(#"if [ $n = 1 ]; then sleep 1; fi"#)
        let chat = ClaudeChat(session: session)
        let b = try board(chat)
        let idle = NotificationCenter.default.addObserver(forName: .takesChatIdle, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let s = n.object as? URL { b.chatIdle(s) } }
        }
        defer { NotificationCenter.default.removeObserver(idle) }
        chat.send("Render it", title: "T", onStage: nil)
        try jobFile("job-1", [:])
        b.reload(session)
        #expect(runs <= 1)
        await until { runs == 2 && !chat.running }
        #expect(ask(2)?.hasPrefix("[Takes] Job job-1 ended") == true)
    }

    @Test func wakeCaps() async throws {
        defer { cleanup(); ClaudeChat.heldNotes = nil }
        try fake("")
        let chat = ClaudeChat(session: session)
        let b = try board(chat)
        for i in 1...3 {
            try jobFile("job-f\(i)", ["status": "failed", "error": "boom", "started": JobFixture.iso(Double(100 + i))])
            b.reload(session)
            await until { runs == min(i, 2) && !chat.running }
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 2)  // the third failure in a row waits
        let third = try #require(JobBoard.load(session).first { $0.id == "job-f3" })
        #expect(b.capped.contains(third.key))
        #expect(JobBoard.line(third, again: b.capped.contains(third.key)) == "Render edit v3 did not finish again.")
        chat.send("Try once more", title: "T", onStage: nil)  // the user's message resets the count
        await until { runs == 3 && !chat.running }
        #expect(ask(3)?.contains("job-f3") == true)
        #expect(!b.capped.contains(third.key))
        // Done notes: at most 5 an hour.
        for i in 1...6 {
            try jobFile("job-d\(i)", ["started": JobFixture.iso(Double(50 + i))])
            b.reload(session)
            await until { runs == 3 + min(i, 5) && !chat.running }
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(runs == 8)
    }
}
