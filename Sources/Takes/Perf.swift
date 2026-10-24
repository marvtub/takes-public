import Foundation
import AppKit
import QuartzCore

// Measures what makes the app feel slow, while the user uses it, at almost no cost:
//
// - how often each view builds its body (`Perf.body("TakeRow")`),
// - how long a click takes until its new screen is drawn (`Perf.mark("tab assets")`),
// - every stall of the main thread of 100 ms or more, with the last click before it.
//
// Every 10 s with something to tell, it writes a line block to ~/Library/Logs/Takes/perf.txt
// (2026-10-02). Read it to find the next thing to fix.
@MainActor
enum Perf {
    private static var bodies: [String: Int] = [:]
    private static var lines: [String] = []
    private static var lastMark = ""
    private static var started = false

    static var file: URL { HangWatch.folder.appending(path: "perf.txt") }

    /// Call at the top of a body: `let _ = Perf.body("Name")`.
    @discardableResult
    static func body(_ name: String) -> Bool {
        bodies[name, default: 0] += 1
        return true
    }

    /// How often a view built its body since the last flush. For tests.
    static func count(_ name: String) -> Int { bodies[name, default: 0] }

    /// A click that changes the screen. Logs the time until SwiftUI drew the change.
    static func mark(_ what: String) {
        let t0 = CACurrentMediaTime()
        // The session the launch opens is no click: "launch session", so the switch numbers stay
        // clean and a launch fix has its own before and after (2026-10-18).
        var what = what, age: Double?
        if what == "session", !launchSeen, let up = processAge(), up < launchWindow {
            launchSeen = true
            what = "launch session"
            age = up
        }
        lastMark = what
        Stall.note(what)
        // Runs after the current turn of the run loop, when SwiftUI committed the new views.
        DispatchQueue.main.async { [what] in
            let ms = (CACurrentMediaTime() - t0) * 1000
            let after = age.map { String(format: " (drawn %.2f s after the start)", $0 + ms / 1000) } ?? ""
            lines.append(String(format: "%@ %@: %.0f ms", stamp(), what, ms) + after)
        }
    }

    private static var launchSeen = false
    /// A session opened later than this after the start is a click.
    static let launchWindow = 10.0

    /// Seconds since this process started (the kernel's start time).
    nonisolated static func processAge() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        let start = Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - start
    }

    /// The parts of a click, timed on the spot: "session open: doc 2 ms, chat 1 ms, view 0 ms".
    /// Shows which part of the time `mark` logs is the app's own work, and which is SwiftUI drawing.
    static func spans(_ what: String, _ parts: [(String, () -> Void)]) {
        var out: [String] = []
        for (name, run) in parts {
            let t = CACurrentMediaTime()
            run()
            out.append(String(format: "%@ %.0f ms", name, (CACurrentMediaTime() - t) * 1000))
        }
        guard started else { return }
        lines.append("\(stamp()) \(what): " + out.joined(separator: ", "))
    }

    static func start() {
        guard !started else { return }
        started = true
        LaunchProbe.start()
        Stall.start()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }

    /// A line of its own in perf.txt (LaunchProbe's result, a chat turn).
    static func note(_ text: String) { lines.append("\(stamp()) \(text)") }

    static func stall(_ ms: Double, after: String) {
        lines.append(String(format: "%@ STALL %.0f ms (after: %@)", stamp(), ms, after))
    }

    private static func flush() {
        guard !bodies.isEmpty || !lines.isEmpty else { return }
        var out = lines
        let total = bodies.values.reduce(0, +)
        if total > 0 {
            let top = bodies.sorted { $0.value > $1.value }.prefix(14).map { "\($0.key) \($0.value)" }
            out.append("\(stamp()) bodies/10s \(total): " + top.joined(separator: ", "))
        }
        bodies = [:]
        lines = []
        let text = out.joined(separator: "\n") + "\n"
        Task.detached(priority: .utility) { append(text) }
    }

    nonisolated private static func append(_ text: String) {
        let fm = FileManager.default
        let url = HangWatch.folder.appending(path: "perf.txt")
        try? fm.createDirectory(at: HangWatch.folder, withIntermediateDirectories: true)
        // Keep it small: past 2 MB the old half goes.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000,
           let old = try? String(contentsOf: url, encoding: .utf8) {
            try? String(old.suffix(old.count / 2)).write(to: url, atomically: true, encoding: .utf8)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

/// A thread asks the main thread to answer every 100 ms. An answer that comes 100 ms or more late
/// is a stall the user felt.
enum Stall {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = ""
    nonisolated(unsafe) private static var lastAt = CACurrentMediaTime()
    nonisolated(unsafe) private static var active = true

    static func note(_ what: String) { lock.withLock { last = what; lastAt = CACurrentMediaTime() } }

    static func start() {
        // While Takes is in the back, ask once every 2 s: 10 wakeups a second kept an idle app
        // from napping (2026-10-03).
        for (name, on) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in lock.withLock { active = on } }
        }
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: lock.withLock { active } ? 0.1 : 2)
                let sent = CACurrentMediaTime()
                let front = lock.withLock { active }
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                // Late by 1.5 s: save a sample while it is still frozen, so a 2–5 s freeze names
                // its own cause (HangWatch only starts at 6 s; 2026-10-03).
                var file: String?
                if done.wait(timeout: .now() + 1.5) == .timedOut {
                    file = HangWatch.sample(prefix: "stall")
                    // Still frozen at 6 s: a hang, sampled once per freeze.
                    if done.wait(timeout: .now() + Double(HangWatch.limit) - 1.5) == .timedOut {
                        HangWatch.sample()
                        done.wait()
                    }
                }
                let ms = (CACurrentMediaTime() - sent) * 1000
                LaunchProbe.felt(ms)
                guard ms >= 100 else { continue }
                let (after, since) = lock.withLock { (last, CACurrentMediaTime() - lastAt) }
                // How long after the click: a freeze a minute later was not caused by drawing it.
                var label = since < 1 ? after : String(format: "%@, %.0f s before", after, since)
                if let file { label += ", " + file }
                // In the back, a late answer is mostly App Nap or a sleeping Mac, not a felt freeze.
                if !front { label += ", in background" }
                DispatchQueue.main.async { MainActor.assumeIsolated { Perf.stall(ms, after: label) } }
            }
        }
        t.qualityOfService = .utility
        t.name = "takes.stall"
        t.start()
    }
}

/// After each launch Takes freezes once more for 0.2–0.9 s, about 1 s after the session shows
/// (perf.txt, 8 launches 13–18 Oct). Stall samples only from 1.5 s, so nothing names its cause.
/// For the first 8 s after a launch, `sample` runs on Takes the whole time. The file stays only when
/// a freeze of 300 ms or more came in that time: ~/Library/Logs/Takes/launch-<time>.txt, the newest
/// ten (2026-10-18).
enum LaunchProbe {
    static let seconds = 8
    static let keepFrom = 300.0  // ms
    private static let lock = NSLock()
    nonisolated(unsafe) private static var until = 0.0
    nonisolated(unsafe) private static var stalls: [Double] = []

    static func start() {
        lock.withLock { until = CACurrentMediaTime() + Double(seconds); stalls = [] }
        HangWatch.sample(prefix: "launch", seconds: seconds) { file in
            let felt = lock.withLock { until = 0; return stalls }
            guard keep(felt) else { try? FileManager.default.removeItem(at: file); return }
            let list = felt.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Perf.note("launch probe: \(file.lastPathComponent) (freezes \(list) ms)") }
            }
        }
    }

    /// From Stall's thread: how late the main thread answered.
    nonisolated static func felt(_ ms: Double) {
        guard ms >= 100 else { return }
        lock.withLock { if CACurrentMediaTime() < until { stalls.append(ms) } }
    }

    /// Keep the sample only when the launch had a freeze worth a look.
    nonisolated static func keep(_ stalls: [Double]) -> Bool { stalls.contains { $0 >= keepFrom } }
}

/// One chat turn, as a line in perf.txt (2026-10-18): which process took it (open: the chat's open
/// process, new: a new one that stays open, once: one that ends with the turn), the seconds to the
/// agent's first line, to its first answer and to the end, and the share of input from the prompt
/// cache. It shows if the open process (ChatWarm) makes follow-ups start faster in a real day.
struct TurnClock {
    let agent: String
    var process = "once"
    let t0: Double
    var first: Double?
    var answer: Double?
    var input = 0, cacheRead = 0, cacheWrite = 0

    init(agent: String, now: Double = CACurrentMediaTime()) {
        self.agent = agent
        t0 = now
    }

    mutating func saw(_ lines: [String], now: Double = CACurrentMediaTime()) {
        for line in lines where !line.isEmpty {
            if first == nil { first = now - t0 }
            if answer == nil, line.contains(#""type":"assistant""#) || line.contains(#""type":"item."#) { answer = now - t0 }
            guard line.contains(#""type":"result""#) || line.contains(#""type":"turn.completed""#),
                  let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let u = o["usage"] as? [String: Any] else { continue }
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            input += n("input_tokens")
            cacheRead += n("cache_read_input_tokens") + n("cached_input_tokens")
            cacheWrite += n("cache_creation_input_tokens")
        }
    }

    func line(outcome: String, now: Double = CACurrentMediaTime()) -> String {
        func s(_ t: Double?) -> String { t.map { String(format: "%.2f s", $0) } ?? "–" }
        var out = "chat turn \(agent) \(process): first line \(s(first)), answer \(s(answer)), done \(s(now - t0)), \(outcome)"
        // Codex counts cached tokens inside input_tokens; Claude Code counts them apart.
        let all = agent == "claude" ? input + cacheRead + cacheWrite : input
        if all > 0 { out += String(format: ", cache %.0f%% of %dk", Double(cacheRead) / Double(all) * 100, all / 1000) }
        return out
    }
}
