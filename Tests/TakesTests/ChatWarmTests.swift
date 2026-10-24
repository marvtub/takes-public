import Foundation
import Testing
@testable import Takes

// A Claude Code chat keeps its process open between messages (2026-10-14, ChatWarm.swift).
// The fake reads one stream-json line per message and answers each, as Claude Code does.
extension ChatRunTests {
    /// `body` runs after each ask is saved; $n is the run number. Each start adds a line to pids.
    func warmFake(_ body: String = "") throws {
        let script = dir.appending(path: "claude-warm")
        try """
        #!/bin/bash
        echo $$ >> "\(dir.path)/pids"
        while IFS= read -r line; do
          n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$line" > "\(dir.path)/ask-$n.txt"; echo $n > "\(dir.path)/n"
          echo '{"type":"system","subtype":"init"}'
          \(body)
          echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        ClaudeChat.claudeOverride = script.path
    }

    var starts: Int {
        ((try? String(contentsOf: dir.appending(path: "pids"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func gone(_ pid: pid_t?) -> Bool { pid.map { kill($0, 0) != 0 } ?? true }

    @Test func aWarmChatTakesTheNextMessageOnTheSameProcess() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake()
        chat.send("One", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        let pid = try #require(chat.warmPID, "the process waits for the next message")
        #expect(kill(pid, 0) == 0)
        chat.send("Two", title: "T", onStage: nil, origin: "He sent this from his phone.")
        await until { runs == 2 && !chat.running }
        #expect(starts == 1, "one process took both")
        #expect(chat.warmPID == pid)
        #expect(ask(1)?.contains(#""content":"One""#) == true)
        // What changes per message goes in front of it, not into the instructions.
        #expect(ask(2)?.contains("[Takes note: He sent this from his phone.]") == true)
        #expect(ask(2)?.contains("Two") == true)
        #expect(!chat.messages.contains { $0.role == .error })
    }

    /// 2026-10-19: a parked comment scout held "Updating…" for minutes.
    @Test func anUpdateDoesNotWaitForAWaitingProcessAndEndsIt() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake()
        chat.send("One", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        let pid = try #require(chat.warmPID)
        #expect(WarmPool.idlePIDs.contains(pid), "the update does not wait for it")
        WarmPool.dropIdle()
        await until { gone(pid) }
        #expect(gone(pid))
        #expect(chat.warmPID == nil)
        #expect(!WarmPool.idlePIDs.contains(pid))
    }

    @Test func stopEndsTheWarmProcessAndTheNextMessageStartsANewOne() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake(#"if [ $n = 2 ]; then sleep 20; fi"#)
        chat.send("One", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        let pid = chat.warmPID
        chat.send("Two", title: "T", onStage: nil)
        await until { runs == 2 }
        chat.stop()
        await until { !chat.running && gone(pid) }
        #expect(chat.messages.last?.text == "Stopped.")
        #expect(gone(pid))
        chat.send("Three", title: "T", onStage: nil)
        await until { runs == 3 && !chat.running }
        #expect(starts == 2)
        #expect(chat.messages.last?.role != .error)
    }

    @Test func aSteerOnAWarmRunGoesOnInANewProcess() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake(#"if [ $n = 1 ]; then sleep 20; fi"#)
        chat.send("Make the cut", title: "T", onStage: nil)
        await until { runs == 1 }
        chat.send("Shorter", title: "T", onStage: nil, now: true)
        await until { runs == 2 && !chat.running }
        #expect(starts == 2)
        #expect(ask(2)?.contains("I interrupted you.") == true && ask(2)?.contains("Shorter") == true)
        #expect(!chat.messages.contains { $0.role == .error })
    }

    @Test func aWarmProcessThatDiedFallsBackToANewOne() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake()
        chat.send("One", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        let pid = try #require(chat.warmPID)
        kill(pid, SIGKILL)
        await until { chat.warmPID == nil }
        #expect(chat.messages.last?.role != .error, "a waiting process that ends says nothing")
        chat.send("Two", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        #expect(starts == 2)
        #expect(!chat.messages.contains { $0.role == .error })
    }

    @Test func aFailedTurnIsNotKeptAndTheNextMessageStartsANewProcess() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        try warmFake(#"if [ $n = 1 ]; then echo '{"type":"result","subtype":"error","is_error":true,"result":"API Error","modelUsage":{}}'; fi"#)
        chat.send("One", title: "T", onStage: nil)
        await until { runs == 1 && !chat.running }
        #expect(chat.warmPID == nil, "a failed turn ends its process")
        chat.send("Two", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        #expect(starts == 2)
        #expect(chat.warmPID != nil)
    }

    @Test func aClosedPlayerGetsANoteOnceAfterAnOpenOne() async throws {
        let chat = ClaudeChat(session: session)
        let tab = UserDefaults.standard.string(forKey: "rightTab")
        UserDefaults.standard.removeObject(forKey: "rightTab")
        defer { chat.dropWarm(); cleanup(); UserDefaults.standard.set(tab, forKey: "rightTab") }
        try warmFake()
        let take = session.appending(path: "take-01-camera.mov")
        chat.send("One", title: "T", onStage: take)
        await until { runs == 1 && !chat.running }
        chat.send("Two", title: "T", onStage: nil)
        await until { runs == 2 && !chat.running }
        chat.send("Three", title: "T", onStage: nil)
        await until { runs == 3 && !chat.running }
        #expect(ask(1)?.contains("open in the player") == true)
        #expect(ask(2)?.contains("out of date") == true)
        #expect(ask(3)?.contains("Takes note") == false, "said once")
    }

    @Test func backgroundTasksKeepTheRunUntilTheirTurnAnswers() async throws {
        let chat = ClaudeChat(session: session)
        defer { chat.dropWarm(); cleanup() }
        // As the comment scout: it starts agents, answers, and answers again when they end.
        try warmFake(#"""
        if [ $n = 1 ]; then
          echo '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"}]}'
          echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Started the agents."}]}}'
          echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
          sleep 1
          echo '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
          echo '{"type":"system","subtype":"init"}'
          echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Drafts done."}]}}'
        fi
        """#)
        chat.send("Scout", title: "T", onStage: nil)
        await until { chat.messages.contains { $0.text == "Started the agents." } }
        #expect(chat.running, "the agents still run")
        await until { runs == 1 && !chat.running }
        #expect(chat.messages.contains { $0.text == "Drafts done." })
        #expect(chat.warmPID != nil, "the process waits again")
        #expect(starts == 1)
        #expect(!chat.messages.contains { $0.role == .error })
    }

    @Test func tasksThatEndWithNoNewTurnEndTheRunAfterAWhile() async throws {
        let chat = ClaudeChat(session: session)
        let quiet = Warm.quiet
        Warm.quiet = .milliseconds(300)
        defer { Warm.quiet = quiet; chat.dropWarm(); cleanup() }
        try warmFake(#"""
        if [ $n = 1 ]; then
          echo '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"}]}'
          echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
          sleep 1
          echo '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
          sleep 4
        fi
        """#)
        chat.send("One", title: "T", onStage: nil)
        await until(4) { runs == 1 && !chat.running }
        #expect(!chat.running, "ended before the late answer")
    }

    @Test func atMostThreeWaitAndAnIdleOneEnds() async throws {
        let chats = (1...4).map { i -> ClaudeChat in
            let s = dir.appending(path: "P/2026-10-14-s\(i)")
            try? FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
            return ClaudeChat(session: s)
        }
        let idle = Warm.idle
        defer { Warm.idle = idle; chats.forEach { $0.dropWarm() }; cleanup() }
        try warmFake()
        for (i, c) in chats.enumerated() {
            c.send("Hi", title: "T", onStage: nil)
            await until { runs == i + 1 && !c.running }
        }
        let first = chats[0]
        await until { first.warmPID == nil }
        #expect(first.warmPID == nil, "the oldest ended")
        #expect(chats.dropFirst().allSatisfy { $0.warmPID != nil })
        // No message for Warm.idle: it ends.
        Warm.idle = .milliseconds(200)
        let last = chats[3], pid = last.warmPID
        last.send("Again", title: "T", onStage: nil)
        await until { runs == 5 && !last.running }
        await until(5) { last.warmPID == nil && gone(pid) }
        #expect(last.warmPID == nil)
        #expect(gone(pid))
    }
}
