import Foundation
import Testing
@testable import Takes

// The agent layer (Agents/, 2026-10-12): each adapter's arguments, its answer from a real run's output
// (Claude Code 2.x, codex 0.156 and pi on this Mac, trimmed), a fake CLI end to end, and the guard that
// keeps every CLI inside Agents/.
struct AgentsTests {
    let name = AgentRequest(prompt: "Reply with ONLY a short title.", input: "Script: the notch prompter", speed: .fast)

    @Test func theRequestGoesOnStdin() {
        #expect(name.stdin == "Reply with ONLY a short title.\n\nScript: the notch prompter")
        #expect(AgentRequest(prompt: "Hi").stdin == "Hi")
    }

    @Test func claudeArguments() {
        let a = ClaudeAdapter().arguments(name)
        #expect(a.starts(with: ["-p", "--output-format", "json", "--no-session-persistence", "--safe-mode"]))
        #expect(a.contains("--tools") && a[a.firstIndex(of: "--tools")! + 1] == "", "no tools to name a session")
        #expect(Array(a.suffix(2)) == ["--model", "haiku"])
        var read = name; read.tools = .read
        #expect(ClaudeAdapter().arguments(read)[ClaudeAdapter().arguments(read).firstIndex(of: "--tools")! + 1] == "Read")
    }

    @Test func codexArguments() {
        let a = CodexAdapter().arguments(name)
        #expect(a.starts(with: ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only"]))
        #expect(a.last == "-")
        #expect(a.contains("-m"))
    }

    @Test func piArguments() {
        #expect(PiAdapter().arguments(name) == ["-p", "--mode", "json", "--no-session", "--no-tools"])
        var read = name; read.tools = .read
        #expect(PiAdapter().arguments(read) == ["-p", "--mode", "json", "--no-session", "--tools", "read"])
    }

    @Test func claudeAnswer() {
        let ok = #"{"type": "result", "subtype": "success", "is_error": false, "result": "Teleprompter Script in MacBook Notch", "session_id": "186138df"}"#
        #expect(ClaudeAdapter().reply(out: ok, err: "", status: 0) == AgentReply(text: "Teleprompter Script in MacBook Notch"))
        let bad = #"{"type": "result", "is_error": true, "result": "Not logged in · Please run /login"}"#
        #expect(ClaudeAdapter().reply(out: bad, err: "", status: 1) == .failed("Not logged in · Please run /login"))
        #expect(ClaudeAdapter().reply(out: "", err: "[claude-code:unrecognized_model]\n", status: 1) == .failed("[claude-code:unrecognized_model]"))
    }

    @Test func codexAnswer() {
        let out = """
        {"type":"thread.started","thread_id":"01a131b8-540c-7031-a4dc-1c2b8c4be286"}
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"`--dangerously-bypass-hook-trust` is enabled."}}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Faster Videos with a Notch Teleprompter"}}
        {"type":"turn.completed","usage":{"input_tokens":25030,"output_tokens":127}}
        """
        #expect(CodexAdapter().reply(out: out, err: "", status: 0) == AgentReply(text: "Faster Videos with a Notch Teleprompter"),
                "a warning item is not a failure")
        let failed = #"{"type":"turn.failed","error":{"message":"The 'gpt-6.1-sol' model is not supported."}}"#
        #expect(CodexAdapter().reply(out: failed, err: "", status: 1) == .failed("The 'gpt-6.1-sol' model is not supported."))
        #expect(CodexAdapter().reply(out: "", err: "Not logged in\n", status: 1) == .failed("Not logged in"))
    }

    @Test func piAnswer() {
        let out = #"{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"Reply…"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"**Titling**"},{"type":"text","text":"Record Videos Faster With a Teleprompter"}],"stopReason":"stop","model":"gpt-5.6-luna"}]}"#
            + "\n" + #"{"type":"agent_settled"}"#
        #expect(PiAdapter().reply(out: out, err: "", status: 0) == AgentReply(text: "Record Videos Faster With a Teleprompter"))
        let error = #"{"type":"agent_end","messages":[{"role":"assistant","content":[],"stopReason":"error","errorMessage":"No API key for provider"}]}"#
        #expect(PiAdapter().reply(out: error, err: "", status: 1) == .failed("No API key for provider"))
        #expect(PiAdapter().reply(out: "", err: "Error: Model \"x\" not found.\n", status: 1) == .failed("Error: Model \"x\" not found."))
    }

    @Test func thePickedAgentWinsWhenItIsHere() {
        #expect(Agents.pick(preferred: .codex, here: [.claude, .codex]) == .codex)
        #expect(Agents.pick(preferred: .codex, here: [.pi]) == .pi, "only pi on this Mac: pi")
        #expect(Agents.pick(preferred: .claude, here: [.codex, .pi]) == .codex)
        #expect(Agents.pick(preferred: nil, here: []) == nil)
    }

    /// A fake CLI that answers like the real one and writes what it got to a file.
    func fake(_ answer: String, status: Int = 0, sleep: Double = 0) throws -> (exe: String, seen: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seen = dir.appending(path: "seen.txt"), exe = dir.appending(path: "agent")
        let body = "#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(seen.path)'\necho --- >> '\(seen.path)'\ncat >> '\(seen.path)'\n"
            + (sleep > 0 ? "sleep \(sleep)\n" : "") + "cat <<'EOF'\n\(answer)\nEOF\nexit \(status)\n"
        try body.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return (exe.path, seen)
    }

    @Test func aFakeAgentRunsEndToEnd() throws {
        let f = try fake(#"{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"Notch Prompter"}],"stopReason":"stop"}]}"#)
        #expect(Agents.execute(f.exe, PiAdapter(), name) == AgentReply(text: "Notch Prompter"))
        let seen = try String(contentsOf: f.seen, encoding: .utf8)
        #expect(seen.hasPrefix("-p\n--mode\njson\n--no-session\n--no-tools\n---\n"))
        #expect(seen.hasSuffix("Reply with ONLY a short title.\n\nScript: the notch prompter"))
    }

    @Test func aSlowAgentStopsAtItsTime() throws {
        let f = try fake("{}", sleep: 5)
        var r = name; r.seconds = 1
        let t0 = Date()
        #expect(Agents.execute(f.exe, ClaudeAdapter(), r) == .failed("Claude Code took longer than 1 s."))
        #expect(Date().timeIntervalSince(t0) < 3)
    }

    @Test func noAgentSaysFinishSetup() async {
        let r = await Agents.run(name, on: nil)
        // Under test no real CLI is found, and no other suite sets a fake pi.
        if Agents.installed.isEmpty { #expect(r == .failed("No agent is set up. Click Finish setup in the sidebar.")) }
    }

    /// The real CLIs on this Mac, each once: `TAKES_REAL_AGENTS=1 swift test --filter realAgents`.
    /// Off in test.sh: it needs the network and a signed-in agent.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_REAL_AGENTS"] == "1"))
    func realAgentsNameASession() async {
        for k in AgentKind.allCases {
            guard let exe = Agents.find(k) else { print("\(k.name): not on this Mac"); continue }
            let r = await Task.detached { Agents.execute(exe, k.adapter, name) }.value
            print("\(k.name): \(r)")
            #expect(r.text.map { !$0.isEmpty && $0.count < 80 } == true, "\(k.name): \(r)")
        }
    }

    // MARK: The guard

    /// Only Agents/ names an agent CLI, finds one or builds its arguments. Setup.swift was the last file
    /// to move onto Agents (2026-10-12).
    /// Admin tools, never in the public copy: they stay on Claude Code (the user, 2026-10-12). Site AI
    /// asks Claude, ChatGPT (Codex) and Gemini on purpose: it checks whether each names Takes.
    static let adminOnly: Set<String> = ["Copilot.swift", "Plugins/Private/SiteAI.swift", "Plugins/Private/SiteAskCLI.swift"]

    @Test func onlyAgentsNamesAnAgentCLI() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/Takes")
        let pattern = try Regex(#"claudePath|Agents\.path\(\.claude\)|(tool|find)\("(claude|codex|pi)"\)|/bin/(claude|codex|pi)\b|claude\.ai/install|"--output-format"|\["exec"\]"#)
        var found: Set<String> = []
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)!
        for case let f as URL in files where f.pathExtension == "swift" {
            let rel = String(f.path.dropFirst(src.path.count + 1))
            if rel.hasPrefix("Agents/") { continue }
            if try String(contentsOf: f, encoding: .utf8).contains(pattern) { found.insert(rel) }
        }
        let new = found.subtracting(Self.adminOnly)
        #expect(new.isEmpty, "Run agents through Agents.run, or a ChatAdapter for the chat (Sources/Takes/Agents): \(new.sorted())")
    }
}
