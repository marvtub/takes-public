import Foundation
import Testing
@testable import Takes

// The chat on Codex, and the model pick (2026-10-11). The lines are what `codex exec --json` 0.156
// printed on this Mac.
struct CodexParseTests {
    @Test func aCodexTurnBecomesMessagesAndSteps() {
        var p = ChatParser([])
        for line in [
            #"{"type":"thread.started","thread_id":"01a12be9-f784-7a80-892d-bcdf0970a9bd"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found."}}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I'll look.\n"}}"#,
            #"{"type":"item.started","item":{"id":"item_3","type":"mcp_tool_call","server":"takes","tool":"get_session","arguments":{},"status":"in_progress"}}"#,
            #"{"type":"item.started","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc 'ffmpeg -i a.mov'","status":"in_progress"}}"#,
        ] { p.consume(line) }
        #expect(p.started)
        #expect(p.thread == "01a12be9-f784-7a80-892d-bcdf0970a9bd")
        #expect(p.messages.map(\.text) == ["I'll look.", "get session", "Bash · ffmpeg -i a.mov"], "warnings stay out")
        #expect(p.messages.filter { !$0.done }.count == 2)
        p.consume(#"{"type":"item.completed","item":{"id":"item_3","type":"mcp_tool_call","server":"takes","tool":"get_session","arguments":{},"status":"completed"}}"#)
        #expect(p.messages[1].done && !p.messages[2].done)
        p.consume(#"{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"Done."}}"#)
        p.consume(#"{"type":"turn.completed","usage":{"input_tokens":107988,"cached_input_tokens":92928,"output_tokens":135}}"#)
        #expect(p.finished)
        #expect(p.messages.allSatisfy { $0.done })
        #expect(p.messages.last?.text == "Done.")
        #expect(p.context == ChatContext(used: 108_123, window: 272_000))
    }

    @Test func aFailedTurnShowsTheServersOwnWords() {
        var p = ChatParser([])
        p.consume(#"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.\"}}"}}"#)
        #expect(p.finished)
        #expect(p.messages.last?.role == .error)
        #expect(p.messages.last?.text == "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.")
    }

    @Test func codexModelsComeFromItsOwnList() {
        let json = #"{"models":[{"slug":"gpt-reserve","visibility":"hide","priority":1},{"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","priority":3,"description":"Workhorse."},{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","priority":2,"description":"Best."},{"slug":"gpt-6-luna","visibility":"list","priority":4},{"slug":"gpt-5.6-sol","visibility":"list","priority":5}]}"#
        let m = CodexModels.parse(json) ?? []
        #expect(m.map(\.id) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"])
        #expect(m.map(\.name) == ["GPT-6 Astra", "GPT-6 Sol", "gpt-6-luna"])
    }

    @Test func tomlStringsSurviveQuotesAndNewlines() {
        #expect(CodexAdapter.toml("a \"b\"\n\\c\t") == #""a \"b\"\n\\c\t""#)
        #expect(CodexAdapter.toml("\u{1}é") == #""\u0001é""#)
    }

    @MainActor @Test func codexArgumentsForANewAndAResumedThread() {
        let new = CodexAdapter.chatArguments(context: "Be short.", model: "gpt-6-astra", thread: nil, chat: "c-1", board: nil,
                                            access: "bypassPermissions", takesInCodex: true)
        #expect(new.first == "exec" && !new.contains("resume") && new.last == "-")
        #expect(new.contains("sandbox_mode=\"danger-full-access\""))
        #expect(new.contains("developer_instructions=\"Be short.\""))
        #expect(new.contains("mcp_servers.takes.env.TAKES_CHAT_ID=\"c-1\""))
        #expect(new[new.firstIndex(of: "-m")! + 1] == "gpt-6-astra")
        let resumed = CodexAdapter.chatArguments(context: "x", model: "gpt-6-luna", thread: "t-9", chat: "c-1", board: "board",
                                                access: "acceptEdits", takesInCodex: false)
        #expect(Array(resumed.prefix(2)) == ["exec", "resume"])
        #expect(Array(resumed.suffix(2)) == ["t-9", "-"])
        #expect(resumed.contains("sandbox_mode=\"workspace-write\""))
        #expect(!resumed.contains { $0.hasPrefix("mcp_servers.takes") }, "no takes server in Codex: no -c for it")
    }
}

/// A fake codex: saves its arguments and the ask, starts a thread, answers.
@MainActor
@Suite(.serialized)
struct CodexRunTests {
    let dir: URL
    let session: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fakecodex-\(UUID().uuidString)")
        session = dir.appending(path: "P/2026-10-11-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        // Only codex: claudeOverride belongs to the other chat suites, which run side by side.
        for (name, body) in [
            ("codex", #"echo '{"type":"thread.started","thread_id":"thread-77"}'; echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Hi from Codex"}}'; echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'"#),
        ] {
            let script = dir.appending(path: name)
            try """
            #!/bin/bash
            # Only chat turns count: a sign-in or model check another test starts may call this too.
            [ "$1" = exec ] || exit 0
            n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 )); echo $n > "\(dir.path)/n"
            printf '%s\\n' "\(name)" "$@" > "\(dir.path)/args-$n.txt"
            cat > "\(dir.path)/ask-$n.txt"
            \(body)
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        ClaudeChat.codexOverride = dir.appending(path: "codex").path
    }

    func args(_ n: Int) -> [String] {
        ((try? String(contentsOf: dir.appending(path: "args-\(n).txt"), encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    /// The deadline only matters when the test fails: the fake answers at once, but a busy Mac
    /// started it late.
    func until(_ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(30)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cleanup() {
        ClaudeChat.codexOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aCodexConversationStartsAThreadAndResumesIt() async throws {
        defer { cleanup() }
        // Other chat tests run side by side: the global pick stays as it is.
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .codex, remember: false)
        #expect(chat.agent == .codex)
        chat.send("Cut it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 2 }
        #expect(chat.messages.map(\.text) == ["Cut it", "Hi from Codex"])
        #expect(args(1).first == "codex" && !args(1).contains("resume"))
        chat.send("Again", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 4 }
        #expect(args(2).contains("resume") && args(2).contains("thread-77"))
        // A started conversation stays on Codex.
        #expect(!chat.switchAgent(to: .codex, remember: false))
        #expect(chat.agent == .codex)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let log = try dec.decode(ChatLog.self, from: Data(contentsOf: ClaudeChat.file(session)))
        #expect(log.agent == "codex" && log.thread == "thread-77")
    }

    @Test func switchingAgentStartsANewConversationAndKeepsTheOld() async throws {
        defer { cleanup() }
        // A Claude Code conversation that has started.
        let log = ChatLog(conversation: "c-claude", started: true, messages: [ChatMessage(role: .user, text: "Hello")], agent: "claude")
        try JSONEncoder().encode(log).write(to: ClaudeChat.file(session))
        let chat = ClaudeChat(session: session)
        #expect(chat.agent == .claude)
        #expect(chat.switchAgent(to: .codex, remember: false), "a started Claude conversation cannot go on in Codex")
        #expect(chat.messages.isEmpty && chat.agent == .codex)
        #expect(chat.past().count == 1)
        // Before its first reply a conversation just follows the pick.
        #expect(!chat.switchAgent(to: .claude, remember: false))
        #expect(chat.agent == .claude)
    }
}
