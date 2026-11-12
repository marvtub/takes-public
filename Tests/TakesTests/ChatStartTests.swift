import Foundation
import Testing
@testable import Takes

// A run's setup (the MCP file from ~/.claude.json, the login shell's PATH, the warm key's files,
// the process start) runs off the main thread (2026-11-07). On 2026-10-24 a phone message froze
// Takes 1.7 s: the main thread waited in open() on ~/.claude.json. Here the setup itself waits
// until the test releases it, as a stalled disk would make it.
extension ChatRunTests {
    /// Every start waits at its beginning until `release()`; `onMain` says if one ran on the main thread.
    func stalledStart() -> (release: @Sendable () -> Void, onMain: Locked<Bool>) {
        let gate = DispatchGroup()
        gate.enter()
        let onMain = Locked(false)
        ClaudeChat.startProbe = { main in
            if main { onMain.set(true) }
            gate.wait()
        }
        let once = Locked(false)
        return ({ if !once.value { once.set(true); gate.leave() } }, onMain)
    }

    @Test func aStalledSetupNeverHoldsTheMainThread() async throws {
        defer { cleanup() }
        try warmFake()
        let (release, onMain) = stalledStart()
        defer { release(); ClaudeChat.startProbe = nil }
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm() }
        // A setup on the main thread would wait here until the release, 2 s later (or deadlock).
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release() }
        let t = Date()
        chat.send("Hi", title: "T", onStage: nil)
        #expect(Date().timeIntervalSince(t) < 1, "send waited for the stalled file")
        #expect(chat.running)
        await until { runs == 1 && !chat.running }
        #expect(!onMain.value)
        #expect(!chat.messages.contains { $0.role == .error })
        #expect(chat.warmPID != nil)
    }

    /// A stop while the process is still starting stops the run as soon as it starts.
    @Test func aStopWhileStartingStopsTheRun() async throws {
        defer { cleanup() }
        try fake("if [ $n = 1 ]; then \(gate); fi")
        let (release, _) = stalledStart()
        defer { release(); ClaudeChat.startProbe = nil; openGate() }
        let chat = ClaudeChat(session: session)
        chat.send("Find posts", title: "T", onStage: nil)
        chat.heal(force: true)  // the phone asks: a starting run is not dead
        #expect(chat.running)
        chat.stop()
        #expect(chat.running, "it ends with its process")
        release()
        await until { !chat.running }
        #expect(chat.messages.last?.text == "Stopped.")
        #expect(chat.queued.isEmpty)
    }

    /// A steer while the process starts: the run ends at its start and the steer goes next.
    @Test func aSteerWhileStartingGoesNext() async throws {
        defer { cleanup() }
        // The first run waits; it may end before it even read its ask, so it is told by its words.
        try fake(#"if grep -q "Cut the intro" "$(dirname "$0")/ask-$n.txt" && ! grep -q interrupted "$(dirname "$0")/ask-$n.txt"; then \#(gate); fi"#)
        let (release, _) = stalledStart()
        defer { release(); ClaudeChat.startProbe = nil; openGate() }
        let chat = ClaudeChat(session: session)
        chat.send("Cut the intro", title: "T", onStage: nil)
        chat.send("Only the first 3 s", title: "T", onStage: nil, now: true)
        release()
        await until { !chat.running && (ask(runs)?.contains("Only the first 3 s") ?? false) }
        #expect(ask(runs)?.contains("I interrupted you.\nOnly the first 3 s") == true)
        #expect(!chat.messages.contains { $0.role == .error })
    }

    /// A reset while the process starts: the old run never reaches the new conversation.
    @Test func aResetWhileStartingDropsTheOldRun() async throws {
        defer { cleanup() }
        try fake(#"echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'; echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer '$n'"}}}'"#, concurrent: true)
        let (release, _) = stalledStart()
        defer { release(); ClaudeChat.startProbe = nil }
        let chat = ClaudeChat(session: session)
        chat.send("Old run", title: "T", onStage: nil)
        chat.reset()
        #expect(!chat.running)
        release()
        chat.send("New run", title: "T", onStage: nil)
        await until { !chat.running && chat.messages.contains { $0.text.hasPrefix("answer") } }
        #expect(chat.messages.first?.text == "New run")
        let answers = chat.messages.filter { $0.text.hasPrefix("answer") }
        #expect(answers.count == 1)
        let n = Int(answers.first?.text.split(separator: " ").last ?? "") ?? 0
        #expect(ask(n)?.contains("New run") == true, "the answer is the new run's")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func set(_ new: T) { lock.withLock { v = new } }
}
