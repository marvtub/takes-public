import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

struct ReleaseTests {
    @Test func commandQuotesTheRepoAndRunsMainsScript() {
        let c = Releaser.command("/Users/a b/it's")
        #expect(c.contains("git -C '/Users/a b/it'\\''s' fetch -q origin"))
        #expect(c.contains("TAKES_REPO='/Users/a b/it'\\''s' bash <(git -C '/Users/a b/it'\\''s' show origin/main:scripts/public/release.sh)"))
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    func feed(_ lines: [String], media: Bool = false) -> ReleaseRun {
        var r = ReleaseRun(media: media, started: Self.t0)
        for (i, l) in lines.enumerated() { r.read(l, at: Self.t0.addingTimeInterval(Double(i) * 10)) }
        return r
    }

    @Test func readsTheStepsTheTestCountAndTheRelease() {
        var r = feed(["@log /tmp/release.log", "▸ Getting the latest main", "▸ Removing personal data",
                      "· Clean: 76 files rewritten, no personal values left.", "▸ Testing the copy", "· Python tests",
                      "· Building the app", "· tests 1", "· tests 2"])
        #expect(r.steps.map(\.title) == ["Getting the latest main", "Removing personal data", "Testing the copy",
                                         "Pushing the public repo", "Building the download", "Publishing the GitHub release"])
        #expect(r.current?.title == "Testing the copy")
        #expect(r.detail == "Building the app")
        #expect(r.tests == 2)
        #expect(r.log == "/tmp/release.log")
        #expect(r.steps[0].ended != nil && r.steps[3].started == nil)
        for l in ["▸ Pushing the public repo", "▸ Building the download", "▸ Publishing the GitHub release",
                  "@tag v2026.10.6", "@url https://github.com/marvtub/takes-public/releases/tag/v2026.10.6",
                  "Released: v2026.10.6 (abc Release)"] { r.read(l, at: Self.t0.addingTimeInterval(200)) }
        r.end(ok: true, at: Self.t0.addingTimeInterval(300))
        #expect(r.outcome == .released)
        #expect(r.tag == "v2026.10.6")
        #expect(r.url?.lastPathComponent == "v2026.10.6")
        #expect(r.errors.isEmpty)
        #expect(r.steps.allSatisfy { $0.ended != nil })
    }

    @Test func nothingNewIsNotAFailure() {
        var r = feed(["▸ Pushing the public repo", "Nothing new since the last release."])
        r.end(ok: true, at: Self.t0.addingTimeInterval(60))
        #expect(r.outcome == .nothingNew)
    }

    @Test func aStepTheAppDoesNotKnowGoesAfterTheLastStartedOne() {
        let r = feed(["▸ Getting the latest main", "▸ Signing the app"])
        #expect(r.steps[1].title == "Signing the app")
        #expect(r.current?.title == "Signing the app")
    }

    /// The release that stopped on 2026-10-06, as the sheet showed it.
    @Test func aStoppedReleaseNamesTheFailedTestsInPlainWords() {
        var r = feed(["▸ Getting the latest main", "▸ Removing personal data", "· Clean: 77 files", "▸ Testing the copy",
                      "FAIL: test_a_voice_is_found_by_the_start_of_its_name_and_becomes_the_default (test_elevenlabs.ElevenLabs.test_a_voice_is_found_by_the_start_of_its_name_and_becomes_the_default)",
                      "ValueError: No voice 'Zed' in the ElevenLabs account.",
                      "FAIL: test_voiceover_reads_the_script_into_a_versioned_wav_with_the_voice_noted (test_elevenlabs.ElevenLabs.test_voiceover_reads_the_script_into_a_versioned_wav_with_the_voice_noted)",
                      "FAILED (failures=2, skipped=4)", "…", "MCP tests failed", "Tests failed in the public copy."])
        r.end(ok: false, at: Self.t0.addingTimeInterval(120))
        #expect(r.outcome == .failed)
        #expect(r.failedStep?.title == "Testing the copy")
        let why = r.failure
        #expect(why.title == "2 tests failed in the public copy")
        #expect(why.items == ["A voice is found by the start of its name and becomes the default",
                              "Voiceover reads the script into a versioned wav with the voice noted"])
    }

    @Test func swiftTestFailuresAndBuildErrorsReadPlainly() {
        var r = feed(["▸ Testing the copy", "✘ Test theNextArticleUsesALoadedPage() failed after 3.2 seconds with 1 issue.",
                      "✘ Test theNextArticleUsesALoadedPage() recorded an issue at A.swift:3:1"])
        r.end(ok: false, at: Self.t0)
        #expect(r.failure.items == ["The next article uses a loaded page"])
        var b = feed(["▸ Testing the copy", "/x/Sources/Takes/Foo.swift:3:9: error: cannot find 'Bar' in scope"])
        b.end(ok: false, at: Self.t0)
        #expect(b.failure.title == "It stopped with an error")
        #expect(b.failure.items == ["cannot find 'Bar' in scope"])
    }

    @Test func theBarFollowsTimeAndFinishedTests() {
        let e = ReleaseEstimates(times: [:], tests: 100)
        var r = ReleaseRun(media: false, started: Self.t0)
        r.read("▸ Getting the latest main", at: Self.t0)
        r.read("▸ Removing personal data", at: Self.t0.addingTimeInterval(6))
        r.read("▸ Testing the copy", at: Self.t0.addingTimeInterval(21))
        let a = r.fraction(now: Self.t0.addingTimeInterval(30), estimates: e)
        r.read("· tests 50", at: Self.t0.addingTimeInterval(200))
        let b = r.fraction(now: Self.t0.addingTimeInterval(200), estimates: e)
        #expect(a > 0.03 && a < b && b < 0.99)
        let left = r.remaining(now: Self.t0.addingTimeInterval(200), estimates: e) ?? 0
        #expect(left > 150 && left < 400)
    }

    /// The row and its popover in each state, as PNGs. TAKES_RELEASE_SHOTS=/tmp/shots ./test.sh --filter ReleaseTests
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_RELEASE_SHOTS"] != nil))
    func shots() async throws {
        _ = NSApplication.shared
        let dir = ProcessInfo.processInfo.environment["TAKES_RELEASE_SHOTS"]!
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let now = Date()
        func at(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        var running = ReleaseRun(media: false, started: at(160))
        running.read("@log /Users/you/Library/Logs/Takes/release.log", at: at(160))
        running.read("▸ Getting the latest main", at: at(160))
        running.read("▸ Removing personal data", at: at(154))
        running.read("▸ Testing the copy", at: at(140))
        running.read("· tests 126", at: at(1))
        var failed = feed(["@log /Users/you/Library/Logs/Takes/release.log", "▸ Getting the latest main", "▸ Removing personal data", "▸ Testing the copy",
                           "FAIL: test_a_voice_is_found_by_the_start_of_its_name_and_becomes_the_default (x)",
                           "ValueError: No voice 'Zed' in the ElevenLabs account.",
                           "FAIL: test_voiceover_reads_the_script_into_a_versioned_wav_with_the_voice_noted (x)",
                           "FAILED (failures=2, skipped=4)", "MCP tests failed", "Tests failed in the public copy."])
        failed.end(ok: false, at: Self.t0.addingTimeInterval(170))
        var done = feed(["▸ Getting the latest main", "▸ Removing personal data", "▸ Testing the copy", "▸ Pushing the public repo",
                         "▸ Building the download", "▸ Publishing the GitHub release", "@tag v2026.10.6",
                         "@url https://github.com/marvtub/takes-public/releases/tag/v2026.10.6"])
        done.end(ok: true, at: Self.t0.addingTimeInterval(80))
        let r = Releaser.shared
        defer { r.run = nil }
        for (name, run) in [("running", running), ("failed", failed), ("released", done)] {
            r.run = run
            for dark in [true, false] {
                let view = HStack(alignment: .top, spacing: 24) {
                    ReleaseRow().frame(width: 240)
                    ReleaseDetail(releaser: r).background(Theme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(20).frame(width: 680, height: 520, alignment: .topLeading)
                .background(Theme.surface).foregroundStyle(Theme.ink)
                let host = NSHostingView(rootView: AnyView(view))
                host.frame = NSRect(x: 0, y: 0, width: 680, height: 520)
                let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 680, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.contentView = host
                w.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                w.orderOut(nil)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "release-\(name)\(dark ? "" : "-light").png"))
            }
        }
    }
}
