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
        lastMark = what
        Stall.note(what)
        // Runs after the current turn of the run loop, when SwiftUI committed the new views.
        DispatchQueue.main.async {
            let ms = (CACurrentMediaTime() - t0) * 1000
            lines.append(String(format: "%@ %@: %.0f ms", stamp(), what, ms))
        }
    }

    static func start() {
        guard !started else { return }
        started = true
        Stall.start()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
    }

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
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                // Late by 1.5 s: save a sample while it is still frozen, so a 2–5 s freeze names
                // its own cause (HangWatch only starts at 6 s; 2026-10-03).
                var file: String?
                if done.wait(timeout: .now() + 1.5) == .timedOut {
                    file = HangWatch.sample(prefix: "stall")
                    done.wait()
                }
                let ms = (CACurrentMediaTime() - sent) * 1000
                guard ms >= 100 else { continue }
                let (after, since) = lock.withLock { (last, CACurrentMediaTime() - lastAt) }
                // How long after the click: a freeze a minute later was not caused by drawing it.
                var label = since < 1 ? after : String(format: "%@, %.0f s before", after, since)
                if let file { label += ", " + file }
                DispatchQueue.main.async { MainActor.assumeIsolated { Perf.stall(ms, after: label) } }
            }
        }
        t.qualityOfService = .utility
        t.name = "takes.stall"
        t.start()
    }
}
