import Foundation
import Testing
@testable import Takes

// The launch line in perf.txt and the opt-in launch sample (Perf.swift, 2026-11-06).
@MainActor
struct LaunchProbeTests {
    /// `sample` beside a launch made the freezes it looked for: it runs only when asked.
    @Test func sampleIsOffByDefault() {
        let name = "takes-launchprobe-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(!LaunchProbe.sampling(d))
        d.set(true, forKey: "launchProbe")
        #expect(LaunchProbe.sampling(d))
    }

    /// 2026-11-05: a 9.4 s freeze began 0.3 s after the start and ended after the window, so it
    /// did not count and its sample was thrown away.
    @Test func aFreezeCountsWhenItBeganInTheWindow() {
        let until = 100.0
        #expect(LaunchProbe.counts(sent: 99.7, until: until))
        #expect(!LaunchProbe.counts(sent: 100.5, until: until))
        #expect(LaunchProbe.keep([9425]))
        #expect(!LaunchProbe.keep([120, 250]))
    }

    @Test func lineNamesStepsInOrderAndTheFreezes() {
        let line = LaunchProbe.line(steps: [("window", 0.8), ("library", 0.31), ("camera", 1.02)], freezes: [420, 270])
        #expect(line == "launch: library 0.31 s, window 0.80 s, camera 1.02 s; freezes 2, 690 ms (420, 270)")
        #expect(LaunchProbe.line(steps: [], freezes: []) == "launch: no steps; no freezes")
    }
}
