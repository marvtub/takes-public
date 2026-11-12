import Foundation
import QuartzCore
import Testing
@testable import Takes

// How long the main thread is busy starting a chat run: send() itself, plus the step that attaches
// the started process (`startMainMs`, when the build has one). Off by default:
//   TAKES_BENCH=1 swift test -c release --filter chatStartBench
extension ChatRunTests {
    @Test(.enabled(if: bench)) func chatStartBench() async throws {
        defer { cleanup() }
        try warmFake()
        let n = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_N"] ?? "") ?? 20
        func attach(_ c: ClaudeChat) -> Double {
            Mirror(reflecting: c).children.first { $0.label == "startMainMs" }?.value as? Double ?? 0
        }
        func stats(_ xs: [Double]) -> String {
            let s = xs.sorted()
            let p = { (q: Double) in s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))] }
            return String(format: "median %.2f ms, p95 %.2f ms (n=%d)", p(0.5), p(0.95), s.count)
        }
        var fresh: [Double] = [], warm: [Double] = []
        _ = ClaudeChat.shellPath  // once per launch; timed apart below
        for i in 0..<n {
            let chat = ClaudeChat(session: session)
            var t = CACurrentMediaTime()
            chat.send("One \(i)", title: "T", onStage: nil)
            var ms = (CACurrentMediaTime() - t) * 1000
            await until { !chat.running && chat.warmPID != nil }
            fresh.append(ms + attach(chat))
            let before = attach(chat)
            t = CACurrentMediaTime()
            chat.send("Two \(i)", title: "T", onStage: nil)
            ms = (CACurrentMediaTime() - t) * 1000
            await until { !chat.running }
            warm.append(ms + attach(chat) - before)
            chat.dropWarm()
            chat.reset()
        }
        var shell: [Double] = []
        for _ in 0..<n {
            let t = CACurrentMediaTime()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "printf %s \"$PATH\""]
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            shell.append((CACurrentMediaTime() - t) * 1000)
        }
        print("BENCH start new process, main thread: " + stats(fresh))
        print("BENCH start warm process, main thread: " + stats(warm))
        print("BENCH login shell for PATH (first send after launch): " + stats(shell))
    }
}
