import Foundation
import Testing
@testable import Takes

// The chat on pi (2026-10-12). The lines are what `pi -p --mode json` 0.84.4 printed on this Mac,
// cut to the fields the chat reads.
struct PiParseTests {
    @Test func aPiTurnBecomesMessagesAndSteps() {
        var p = ChatParser([], adapter: PiAdapter())
        for line in [
            #"{"type":"session","version":3,"id":"baf25476-7398-4564-90be-6b112ae9fce4","cwd":"/tmp"}"#,
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Read a.txt"}]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"**Planning**"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_1","toolName":"read"}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking"},{"type":"toolCall"}],"usage":{"input":33074,"output":35,"cacheRead":0,"cacheWrite":0},"stopReason":"toolUse"}}"#,
            #"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"read","args":{"path":"a.txt"}}"#,
        ] { p.consume(line) }
        #expect(p.started)
        #expect(p.messages.map(\.text) == ["Read · a.txt"], "thinking and tool-call deltas stay out")
        #expect(p.messages[0].done == false)
        #expect(p.context?.used == 33_109)
        p.consume(#"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"read","result":{"content":[{"type":"text","text":"hello\n"}]},"isError":false}"#)
        #expect(p.messages[0].done && p.messages[0].failed == nil)
        for line in [
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"It says "}}"#,
        ] { p.consume(line) }
        #expect(p.messages.last?.text == "It says " && p.messages.last?.done == false)
        for line in [
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"It says hello."}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"It says hello."}],"usage":{"input":865,"output":8,"cacheRead":32256,"cacheWrite":0},"stopReason":"stop"}}"#,
            #"{"type":"agent_end","messages":[]}"#,
        ] { p.consume(line) }
        #expect(p.finished)
        #expect(p.messages.map(\.text) == ["Read · a.txt", "It says hello."], "the answer shows once")
        #expect(p.messages.allSatisfy { $0.done })
        #expect(p.context?.used == 33_129)
    }

    @Test func anErrorStopShowsItsMessage() {
        var p = ChatParser([], adapter: PiAdapter())
        p.consume(#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"Rate limit reached."}}"#)
        p.consume(#"{"type":"agent_end","messages":[]}"#)
        #expect(p.messages.last?.role == .error && p.messages.last?.text == "Rate limit reached.")
    }

    @Test func compactionAndFailedStepsShow() {
        var p = ChatParser([], adapter: PiAdapter())
        p.consume(#"{"type":"tool_execution_start","toolCallId":"t","toolName":"bash","args":{"command":"ffmpeg -i a.mov"}}"#)
        p.consume(#"{"type":"tool_execution_end","toolCallId":"t","toolName":"bash","result":{},"isError":true}"#)
        p.consume(#"{"type":"compaction_end","reason":"threshold","result":{"tokensBefore":150000,"estimatedTokensAfter":32000}}"#)
        #expect(p.messages.map(\.text) == ["Bash · ffmpeg -i a.mov", "Compacted the conversation · 150k → 32k tokens"])
        #expect(p.messages[0].failed == true)
        #expect(p.compacted)
    }

    @Test func takesToolsThroughTheMcpProxyKeepTheirNames() {
        #expect(PiAdapter.describe("mcp", ["tool": "takes_get_session", "args": ["session": "x"]]) == "get session")
        #expect(PiAdapter.describe("mcp", ["tool": "takes_next_path", "args": ["path": "/a/edits/cut-v2.mp4"]]) == "next_path · cut-v2.mp4")
        #expect(PiAdapter.describe("mcp", ["search": "storyboard"]) == "Find tools · storyboard")
        #expect(PiAdapter.describe("mcp__takes", ["tool": "takes_list_projects", "args": [:]]) == "list projects")
        #expect(PiAdapter.describe("write", ["path": "/a/script.md"]) == "Write · script.md")
    }

    @Test func piArgumentsResumeTakesOwnID() {
        let t = ChatTurn(context: "Be short.", model: "", conversation: "c-1", thread: nil, started: true,
                         access: "bypassPermissions", board: nil)
        let a = PiAdapter().chatArguments(t)
        #expect(Array(a.prefix(5)) == ["-p", "--mode", "json", "--session-id", "c-1"])
        #expect(a.contains("Be short.") && !a.contains("--model") && !a.contains("--exclude-tools"))
        var e = t
        e.access = "acceptEdits"; e.model = "openai/gpt-x"
        let b = PiAdapter().chatArguments(e)
        #expect(b.suffix(4) == ["--model", "openai/gpt-x", "--exclude-tools", "bash"])
    }
}

/// A fake pi: saves its arguments, the ask and TAKES_CHAT_ID, answers.
@MainActor
@Suite(.serialized)
struct PiRunTests {
    @Test func aPiConversationKeepsItsIDAndTellsTheTakesServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fakepi-\(UUID().uuidString)")
        let session = dir.appending(path: "P/2026-10-12-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { Agents.overrides[.pi] = nil; try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "pi")
        try """
        #!/bin/bash
        n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 )); echo $n > "\(dir.path)/n"
        printf '%s\\n' "$@" > "\(dir.path)/args-$n.txt"
        printf '%s' "$TAKES_CHAT_ID" > "\(dir.path)/chat-$n.txt"
        cat > /dev/null
        echo '{"type":"session","version":3,"id":"x"}'
        echo '{"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"Hi from pi"}}'
        echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi from pi"}],"stopReason":"stop"}}'
        echo '{"type":"agent_end","messages":[]}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        Agents.overrides[.pi] = script.path

        func read(_ f: String) -> String { (try? String(contentsOf: dir.appending(path: f), encoding: .utf8)) ?? "" }
        func until(_ ok: () -> Bool) async {  // only a failing test waits this long
            let end = Date().addingTimeInterval(30)
            while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }

        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .pi, remember: false)
        chat.send("Cut it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 2 }
        #expect(chat.messages.map(\.text) == ["Cut it", "Hi from pi"])
        chat.send("Again", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 4 }
        let first = read("args-1.txt").components(separatedBy: "\n"), second = read("args-2.txt").components(separatedBy: "\n")
        let id = first[first.firstIndex(of: "--session-id")! + 1]
        #expect(second[second.firstIndex(of: "--session-id")! + 1] == id, "the second message goes on in the same pi session")
        #expect(read("chat-1.txt") == id && read("chat-2.txt") == id)
        #expect(chat.agent == .pi)
        chat.send("/compact", title: "Test", onStage: nil)
        #expect(chat.messages.last?.text == "pi compacts the conversation by itself.")
    }

    /// A clean end with no text must not leave the question unanswered (review of 2026-10-12).
    @Test func aSilentTurnSaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fakepi-\(UUID().uuidString)")
        let session = dir.appending(path: "P/2026-10-12-quiet")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { Agents.overrides[.pi] = nil; try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "pi")
        try """
        #!/bin/bash
        cat > /dev/null
        echo '{"type":"session","version":3,"id":"x"}'
        echo '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}'
        echo '{"type":"agent_end","messages":[]}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        Agents.overrides[.pi] = script.path
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .pi, remember: false)
        chat.send("Hello", title: "Test", onStage: nil)
        let end = Date().addingTimeInterval(15)
        while !(chat.messages.count >= 2 && !chat.running) && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(chat.messages.last?.role == .error)
        #expect(chat.messages.last?.text == "The chat ended without an answer. Send your message again.")
    }
}
