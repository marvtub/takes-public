import AppKit
import SwiftUI
import Testing
@testable import Takes

// The chat on pi (2026-10-12). The lines are what `pi -p --mode json` 0.84.4 printed on this Mac,
// cut to the fields the chat reads.
struct PiParseTests {
    static let table = """
    provider  model  context  max-out  thinking  images
    openai  gpt-x  200K  32K  yes  yes
    proxy  vendor/model-x  1M  64K  no  yes
    openai  gpt-x  200K  32K  yes  yes
    """

    @Test func availableModelsKeepTheirProviderAndSearchByBoth() throws {
        let models = try #require(PiModels.parse(Self.table))
        #expect(models.map(\.id) == ["openai/gpt-x", "proxy/vendor/model-x"])
        #expect(PiModels.matching(models, query: " PROXY model-X ").map(\.id) == ["proxy/vendor/model-x"])
        #expect(PiModels.matching(models, query: "missing").isEmpty)
        #expect(PiModels.matching(models, query: "").count == 2)
        #expect(PiModels.parse("Could not load models") == nil)
        #expect(PiModels.parse("No models available") == nil)
        #expect(PiModels.next(in: models, from: nil, by: 1) == models.first?.id)
        #expect(PiModels.next(in: models, from: models.last?.id, by: 1) == models.first?.id)
        #expect(PiModels.next(in: models, from: models.first?.id, by: -1) == models.last?.id)
        #expect(PiModels.next(in: [], from: models.first?.id, by: 1) == nil)
    }

    @MainActor @Test func piModelPickerShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let models = [ChatModel(id: "", name: "pi's default", hint: "Your pi settings stay unchanged.")] + (PiModels.parse(Self.table) ?? [])
        let root = FileManager.default.temporaryDirectory.appending(path: "pi-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ClaudeChat(session: root)
        chat.switchAgent(to: .pi, remember: false)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            // AppKit-backed fields and scroll views cannot render through ImageRenderer.
            let host = NSHostingView(rootView: AgentCard(chat: chat, previewModels: models) {}
                .background(Theme.paper).environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let win = NSWindow(contentRect: NSRect(origin: CGPoint(x: -3000, y: -3000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "pi-models-\(name).png"))
        }
    }

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

private final class PiPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
struct PiPickerKeyboardTests {
    @Test func typingArrowsAndReturnPickTheHighlightedModel() throws {
        var selected = "provider/model-0"
        let models = (0..<16).map { ChatModel(id: "provider/model-\($0)", name: "model-\($0)", hint: "provider") }
        let host = NSHostingView(rootView: PiModelPicker(selection: Binding(get: { selected }, set: { selected = $0 }), previewModels: models)
            .padding(12).frame(width: 320).background(Theme.paper))
        let win = PiPickerWindow(contentRect: NSRect(x: -3000, y: -3000, width: 320, height: 260),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        defer { win.orderOut(nil) }
        win.makeKeyAndOrderFront(nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: win.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            win.sendEvent(event); settle()
        }
        settle()
        let editor = try #require(win.firstResponder as? NSTextView, "Opening the picker focuses search")
        editor.insertText("provider model-1", replacementRange: editor.selectedRange())
        settle()
        try key(125, "\u{f701}")
        #expect(selected == "provider/model-0", "Arrows preview; they must not select")
        try key(36, "\r")
        #expect(selected == "provider/model-10", "Return picks the second match, not the first")
        #expect(editor.string == "provider model-1", "Picking keeps the search text")
        try key(125, "\u{f701}"); try key(36, "\r")
        #expect(selected == "provider/model-11", "Picking never moves a result to the top")
        try key(126, "\u{f700}"); try key(36, "\r")
        #expect(selected == "provider/model-10")
        for _ in 0..<5 { try key(125, "\u{f701}") }
        try key(36, "\r")
        #expect(selected == "provider/model-15", "Navigation reaches models below the visible rows")
        if let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] {
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "pi-keyboard-scrolled.png"))
        }
        editor.selectAll(nil); editor.insertText("nothing-matches", replacementRange: editor.selectedRange())
        settle(); try key(125, "\u{f701}"); try key(36, "\r")
        #expect(selected == "provider/model-15", "Empty results never change the pick")
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
        if [ "$1" = --list-models ]; then
        cat <<'MODELS'
        \(PiParseTests.table)
        MODELS
        exit 0
        fi
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
            let end = Date().addingTimeInterval(60)
            while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }

        let defaults = UserDefaults.standard
        let oldModels = defaults.object(forKey: "piModels"), oldPick = defaults.object(forKey: "chatModel.pi")
        defer { defaults.set(oldModels, forKey: "piModels"); defaults.set(oldPick, forKey: "chatModel.pi") }
        #expect(await PiModels.refresh())
        defaults.set("openai/gpt-x", forKey: "chatModel.pi")
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .pi, remember: false)
        chat.send("Cut it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 2 }
        #expect(chat.messages.map(\.text) == ["Cut it", "Hi from pi"])
        defaults.set("proxy/vendor/model-x", forKey: "chatModel.pi")
        chat.send("Again", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 4 }
        let first = read("args-1.txt").components(separatedBy: "\n"), second = read("args-2.txt").components(separatedBy: "\n")
        #expect(first[first.firstIndex(of: "--model")! + 1] == "openai/gpt-x")
        #expect(second[second.firstIndex(of: "--model")! + 1] == "proxy/vendor/model-x")
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
        // Only a failing test waits this long: in the full run the main thread is busy and the end
        // came after 15 s (2026-10-30).
        let end = Date().addingTimeInterval(60)
        while !(chat.messages.count >= 2 && !chat.running) && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(chat.messages.last?.role == .error)
        #expect(chat.messages.last?.text == "The chat ended without an answer. Send your message again.")
    }
}
