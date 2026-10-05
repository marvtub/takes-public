import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

struct SetupTests {
    @Test func readsSignInFromAuthStatus() {
        #expect(Setup.signedIn(status: "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"))
        #expect(!Setup.signedIn(status: "{\"loggedIn\": false}"))
        #expect(Setup.signedIn(status: "Warning: something\n{\"loggedIn\": true}"))
        #expect(!Setup.signedIn(status: "error: not found"))
        #expect(!Setup.signedIn(status: ""))
    }

    @Test @MainActor func nothingShowsBeforeTheFirstCheck() {
        let s = Setup()
        #expect(!s.needed)
        s.claude = .ok; s.signedIn = .missing; s.ffmpeg = .ok
        #expect(s.needed && s.left == 1)
        s.signedIn = .ok
        #expect(!s.needed && s.left == 0)
    }

    @Test func pathGetsTheLocalBinOnce() {
        #expect(ClaudeChat.withLocalBin("/usr/bin:/bin", bin: "/h/.local/bin") == "/usr/bin:/bin:/h/.local/bin")
        #expect(ClaudeChat.withLocalBin("/h/.local/bin:/usr/bin", bin: "/h/.local/bin") == "/h/.local/bin:/usr/bin")
    }
}

/// Downloads about 60 MB, so it runs only with TAKES_NET=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_NET"] == "1"))
func ffmpegDownloadsAndRuns() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "takes-ffmpeg-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await Setup.downloadFFmpeg(to: dir)
    for name in ["ffmpeg", "ffprobe"] {
        let (ok, out) = Setup.run(dir + "/" + name, ["-version"])
        #expect(ok && out.contains("\(name) version"))
    }
}

/// TAKES_SNAPSHOT=1 draws the sidebar row and the panel, light and dark, to $TMPDIR.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] != nil)) @MainActor
func setupSnapshot() throws {
    let s = Setup.shared
    s.claude = .ok; s.signedIn = .missing; s.ffmpeg = .working
    let failed = Setup()
    failed.claude = .missing; failed.signedIn = .missing; failed.ffmpeg = .failed("The ffmpeg download did not match its checksum.")
    for dark in [false, true] {
        NSAppearance.current = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = HStack(alignment: .top, spacing: 24) {
            SetupButton().frame(width: 240)
            SetupPanel(setup: s)
            SetupPanel(setup: failed)
        }
        .padding(24).background(Theme.paper)
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        print("SNAPSHOT \(url.path)")
    }
}
