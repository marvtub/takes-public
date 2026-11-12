import AppKit
import SwiftUI
import Testing
@testable import Takes

// What the docked chat costs to draw, on a copy of a real conversation. Off by default:
//   TAKES_BENCH=1 TAKES_BENCH_CHAT=/path/to/a-copy-of-chat.json swift test --filter chatRenderBench
// Never point it at a file in the library: the test copies the file into its own temp folder.
// It prints first layout, each keystroke in the box and each streamed word: median and p95,
// main-thread time and how often each chat view built its body.
private let benchChat = ProcessInfo.processInfo.environment["TAKES_BENCH_CHAT"]

@MainActor
enum ChatBench {
    static func ms(_ f: () -> Void) -> Double {
        let t = CACurrentMediaTime(); f(); return (CACurrentMediaTime() - t) * 1000
    }
    /// Main-thread CPU in ms (the bench runs on the main thread).
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    static func stats(_ xs: [Double]) -> String {
        let s = xs.sorted()
        guard !s.isEmpty else { return "none" }
        let p = { (q: Double) in s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))] }
        return String(format: "median %.2f ms, p95 %.2f ms (n=%d)", p(0.5), p(0.95), s.count)
    }
    static let views = ["ChatPanel", "ChatComposer", "ChatRows", "ChatCornerBody"]
    static func counts() -> [Int] { views.map(Perf.count) }
    static func perStep(_ a: [Int], _ b: [Int], _ n: Int) -> String {
        zip(views, zip(a, b)).map { String(format: "%@ %.2f", $0.0, Double($0.1.1 - $0.1.0) / Double(n)) }.joined(separator: ", ")
    }
    static func frame(_ v: NSView) {
        RunLoop.main.run(until: Date())
        v.layoutSubtreeIfNeeded()
        v.display()
    }
}

extension ChatRunTests {
    @Test(.enabled(if: bench && benchChat != nil)) func chatRenderBench() async throws {
        defer { cleanup() }
        let src = URL(fileURLWithPath: benchChat!)
        try FileManager.default.copyItem(at: src, to: ClaudeChat.file(session))
        let runs = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_N"] ?? "20") ?? 20

        // Loading the conversation file (ChatHub.chat on a session switch).
        var load: [Double] = []
        for _ in 0..<runs { load.append(ChatBench.ms { _ = ClaudeChat(session: session) }) }

        // First frame of the docked chat in a new window, and the frame after its page fills in.
        var first: [Double] = [], filled: [Double] = []
        for _ in 0..<runs {
            let slot = SlotHarness.Slot()
            let (view, window, _, _) = SlotHarness.host(slot, session: session)
            first.append(ChatBench.ms { view.layoutSubtreeIfNeeded(); view.display() })
            try? await Task.sleep(for: .milliseconds(80))
            filled.append(ChatBench.ms { ChatBench.frame(view) })
            window.orderOut(nil)
        }

        let slot = SlotHarness.Slot()
        let (view, window, chat, _) = SlotHarness.host(slot, session: session)
        defer { window.orderOut(nil) }
        SlotHarness.settle(view)
        try? await Task.sleep(for: .milliseconds(100))
        SlotHarness.settle(view)

        // Keystrokes in the box.
        var keys: [Double] = []
        let k0 = ChatBench.counts()
        let keyN = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_KEYS"] ?? "") ?? max(40, runs)
        print("BENCH typing starts")
        for i in 0..<keyN {
            keys.append(ChatBench.ms {
                chat.draft += i % 6 == 5 ? " " : "a"
                ChatBench.frame(view)
            })
        }
        let k1 = ChatBench.counts()
        // The draft goes to disk 2 s after the last key: the whole conversation file.
        var drafts: [Double] = []
        for i in 0..<runs { chat.draft += "\(i)"; drafts.append(ChatBench.ms { chat.saveDraft() }) }
        chat.draft = ""
        chat.saveDraft()
        SlotHarness.settle(view)

        // Board actions (ClaudeChat.action), as the Site board's buttons write them: a running
        // line, then its result. The call itself (it saves the log) and the frame after it.
        var actCall: [Double] = [], actFrame: [Double] = []
        let a0 = ChatBench.counts()
        let actN = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_ACTIONS"] ?? "") ?? max(40, runs)
        for i in 0..<actN {
            var id = UUID()
            actCall.append(ChatBench.ms { id = chat.action("Refreshing page \(i)", running: true) })
            actFrame.append(ChatBench.ms { ChatBench.frame(view) })
            actCall.append(ChatBench.ms { chat.action("Refreshed page \(i)", agent: "Page \(i): 3 changes", update: id) })
            actFrame.append(ChatBench.ms { ChatBench.frame(view) })
        }
        let a1 = ChatBench.counts()
        SlotHarness.settle(view)

        // Run 1 streams words, each waiting for the test, so every word is its own change. A new
        // paragraph every 8 words, as replies have: one paragraph of 600 words is all text layout.
        // Run 2 is tool steps, as most of a Takes turn is: each call starts (with its usage line),
        // then ends, each when the test says.
        let words = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_WORDS"] ?? "") ?? max(40, runs)
        let steps = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_STEPS"] ?? "") ?? max(30, runs)
        func wait(_ name: String) -> String {
            #"while [ -d "\#(dir.path)" ] && [ ! -e "\#(dir.path)/\#(name)" ]; do sleep 0.005; done"#
        }
        try fake(#"""
        if [ "$n" = 1 ]; then
          echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'
          for i in $(seq 1 \#(words)); do
            \#(wait("word-$i"))
            if [ $((i % 8)) = 0 ]; then sep='\n\n'; else sep=' '; fi
            echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"word '$i' and **a few** more words,'"$sep"'"}}}'
          done
        else
          for i in $(seq 1 \#(steps)); do
            \#(wait("step-$i-a"))
            echo '{"type":"assistant","message":{"usage":{"input_tokens":'$((1000 + i * 37))'},"content":[{"type":"tool_use","id":"t'$i'","name":"Bash","input":{"command":"ffprobe take-'$i'.mov"}}]}}'
            \#(wait("step-$i-b"))
            echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t'$i'"}]}}'
          done
        fi
        """#)
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: nil) }

        chat.send("Bench", title: "Bench", onStage: nil)
        await until { chat.running }
        SlotHarness.settle(view)
        print("BENCH streaming starts")
        var stream: [Double] = []
        let s0 = ChatBench.counts()
        var cpu0 = ChatBench.cpu()
        for i in 1...words {
            touch("word-\(i)")
            await until { chat.messages.last?.text.contains("word \(i) and") == true }
            stream.append(ChatBench.ms { ChatBench.frame(view) })
        }
        let s1 = ChatBench.counts()
        let cpuPerWord = (ChatBench.cpu() - cpu0) / Double(words)
        await until { !chat.running }
        SlotHarness.settle(view)

        chat.send("Bench steps", title: "Bench", onStage: nil)
        await until { chat.running }
        SlotHarness.settle(view)
        var step: [Double] = []
        let t0 = ChatBench.counts()
        cpu0 = ChatBench.cpu()
        for i in 1...steps {
            touch("step-\(i)-a")
            await until { chat.messages.last?.toolID == "t\(i)" }
            step.append(ChatBench.ms { ChatBench.frame(view) })
            touch("step-\(i)-b")
            await until { chat.messages.last?.done == true }
            step.append(ChatBench.ms { ChatBench.frame(view) })
        }
        let t1 = ChatBench.counts()
        let cpuPerStep = (ChatBench.cpu() - cpu0) / Double(steps)
        await until { !chat.running }

        let shown = chat.messages.count
        print("BENCH chat \(src.lastPathComponent): \(shown) messages")
        print("BENCH chat load: " + ChatBench.stats(load))
        print("BENCH chat first frame: " + ChatBench.stats(first))
        print("BENCH chat page filled frame: " + ChatBench.stats(filled))
        print("BENCH chat keystroke frame: " + ChatBench.stats(keys))
        print("BENCH chat keystroke bodies/key: " + ChatBench.perStep(k0, k1, keyN))
        print("BENCH chat draft save: " + ChatBench.stats(drafts))
        print("BENCH chat board action call: " + ChatBench.stats(actCall))
        print("BENCH chat board action frame: " + ChatBench.stats(actFrame))
        print("BENCH chat board action bodies/line: " + ChatBench.perStep(a0, a1, actN * 2))
        print("BENCH chat streamed word frame: " + ChatBench.stats(stream))
        print(String(format: "BENCH chat streamed word main-thread CPU: %.2f ms/word", cpuPerWord))
        print("BENCH chat streamed word bodies/word: " + ChatBench.perStep(s0, s1, words))
        print("BENCH chat tool step frame (start and end): " + ChatBench.stats(step))
        print(String(format: "BENCH chat tool step main-thread CPU: %.2f ms/step", cpuPerStep))
        print("BENCH chat tool step bodies/step: " + ChatBench.perStep(t0, t1, steps))
    }
}
