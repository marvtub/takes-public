import AppKit
import MachO
import SwiftUI
import Testing
@testable import Takes

// What a launch costs the main thread, in a fresh process: AppModel, the first window's content
// (offscreen), and the first seconds after it, timed by a thread that asks the main thread to
// answer every 20 ms (as Stall does). One run per process: run it N times, old and new builds in
// alternating turns. Off by default; it needs a copied library (never ~/Movies/Takes):
//   TAKES_BENCH=1 TAKES_BENCH_LIB=/path/to/copy swift test --filter ZBenchLaunch
// TAKES_BENCH_SAMPLE=1 runs `sample` on the process from AppModel's start for 8 s, as
// LaunchProbe did on every launch until 2026-11-06. TAKES_BENCH_TAB (default broll) and
// TAKES_BENCH_PROJECT pick what opens; TAKES_BENCH_TRACE=1 names what ran in each freeze.
@MainActor
@Suite(.serialized) struct ZBenchLaunch {
    nonisolated static let lib = ProcessInfo.processInfo.environment["TAKES_BENCH_LIB"]

    final class Ping: @unchecked Sendable {
        let lock = NSLock()
        var late: [(at: Double, ms: Double)] = []
        var stop = false
        let t0: Double
        init(_ t0: Double) { self.t0 = t0 }
        func start() {
            let t = Thread { [self] in
                while !lock.withLock({ stop }) {
                    Thread.sleep(forTimeInterval: 0.02)
                    let sent = CACurrentMediaTime()
                    let s = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { s.signal() }
                    s.wait()
                    let ms = (CACurrentMediaTime() - sent) * 1000
                    if ms >= 50 { lock.withLock { late.append((sent - t0, ms)) } }
                }
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    @Test(.enabled(if: bench && lib != nil)) func launch() async throws {
        let root = URL(fileURLWithPath: Self.lib!)
        // The argument domain: it wins over saved values and is never written to disk.
        var args: [String: Any] = ["root": root.path, "chatOpen": true, "chatDocked": true,
                                   "rightTab": ProcessInfo.processInfo.environment["TAKES_BENCH_TAB"] ?? "broll"]
        // The project the launch opens (TAKES_BENCH_PROJECT), else the first one.
        args["project"] = ProcessInfo.processInfo.environment["TAKES_BENCH_PROJECT"]
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        try #require(UserDefaults.standard.string(forKey: "root") == root.path)
        let images0 = _dyld_image_count()
        var sampler: Process?
        if ProcessInfo.processInfo.environment["TAKES_BENCH_SAMPLE"] == "1" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            p.arguments = [String(getpid()), "8", "10", "-mayDie", "-file", FileManager.default.temporaryDirectory.appending(path: "launch-bench-\(getpid()).txt").path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            sampler = p
        }
        let t0 = CACurrentMediaTime()
        let ping = Ping(t0)
        ping.start()
        // TAKES_BENCH_TRACE=1: what the main thread ran in each freeze (MainSampler).
        let trace = ProcessInfo.processInfo.environment["TAKES_BENCH_TRACE"] == "1" ? MainSampler(t0: t0) : nil
        trace?.start()
        let app = AppModel()
        let tModel = CACurrentMediaTime()
        let size = NSRect(x: -4000, y: -4000, width: 1728, height: 989)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app)
            .tint(Theme.accent).font(Theme.body).foregroundStyle(Theme.ink).frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let tFirst = CACurrentMediaTime()
        let names = ["AssetTile","AssetsPane","BrollPane","ChatComposer","ChatCornerBody","ChatPanel","ChatRows","ContentView","DetailView","DraftBar","HeaderSchedule","ModeSwitcher","MoreMenu","RecordPill","ScriptPane","SessionHeader","SessionList","Sidebar","TakeRow","TakesList"]
        let bodies0 = names.map { Perf.count($0) }
        let images1 = _dyld_image_count()
        // The seconds after the first frame: the run loop turns as in the app.
        let until = Date().addingTimeInterval(4)
        while Date() < until {
            // Awaits, not RunLoop.run: a nested run loop never drains the main queue, so the
            // ping and the app's main-actor tasks (camera boot) would wait for the test's end.
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        ping.lock.withLock { ping.stop = true }
        print("BODIES first: " + zip(names, bodies0).map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        print("BODIES after: " + zip(names, bodies0).map { "\($0.0) \(Perf.count($0.0) - $0.1)" }.joined(separator: ", "))
        let late = ping.lock.withLock { ping.late }
        sampler?.terminate()
        trace?.finish()
        let only = ProcessInfo.processInfo.environment["TAKES_BENCH_TRACE_LIB"]
        for f in late where f.ms >= 100 {
            print(String(format: "TRACE freeze %.0f ms at %.2f s", f.ms, f.at))
            let lines = trace?.top(from: f.at, to: f.at + f.ms / 1000, limit: 400, skip: ["CFRunLoop", "NSApplication", "start [dyld]"]) ?? []
            for l in lines.prefix(1) + lines.dropFirst().filter({ only == nil || $0.contains(only!) }).prefix(40) { print("TRACE   " + l) }
        }
        let blocked = late.reduce(0) { $0 + $1.ms }
        let freezes = late.filter { $0.ms >= 100 }.map { String(format: "%.0f@%.2f", $0.ms, $0.at) }.joined(separator: " ")
        print(String(format: "BENCHLAUNCH model %.1f first %.1f blocked %.1f max %.1f images %d+%d+%d freezes [%@]",
                     (tModel - t0) * 1000, (tFirst - t0) * 1000, blocked, late.map(\.ms).max() ?? 0,
                     images0, images1 - images0, _dyld_image_count() - images1, freezes))
        withExtendedLifetime(window) {}
    }
}
