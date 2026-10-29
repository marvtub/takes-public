import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

struct SetupTests {
    @Test func readsSignInFromAuthStatus() {
        #expect(AgentKind.claudeSignedIn("{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"))
        #expect(!AgentKind.claudeSignedIn("{\"loggedIn\": false}"))
        #expect(AgentKind.claudeSignedIn("Warning: something\n{\"loggedIn\": true}"))
        #expect(!AgentKind.claudeSignedIn("error: not found"))
        #expect(!AgentKind.claudeSignedIn(""))
        // The status lines the agents board shows.
        #expect(AgentsStatus.codexLine("Logged in using ChatGPT\n") == "Signed in · uses your ChatGPT plan")
        #expect(AgentsStatus.codexLine(nil).hasPrefix("Not signed in"))
        #expect(AgentsStatus.claudeLine(#"{"loggedIn": true, "authMethod": "claude.ai"}"#) == "Signed in · uses your Claude plan")
        #expect(AgentsStatus.claudeLine(#"{"loggedIn": false}"#).hasPrefix("Not signed in"))
    }

    @Test func readsSignInOfCodexAndPi() throws {
        #expect(AgentKind.codexSignedIn("Logged in using ChatGPT\n"))
        #expect(AgentKind.codexSignedIn("Logged in using an API key - sk-***"))
        #expect(!AgentKind.codexSignedIn("Not logged in"))
        #expect(!AgentKind.codexSignedIn(nil))
        let dir = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AgentKind.piSignedIn(dir: dir))
        try Data("{}".utf8).write(to: dir.appending(path: "auth.json"))
        #expect(!AgentKind.piSignedIn(dir: dir))
        try Data(#"{"providers":{"ollama":{}}}"#.utf8).write(to: dir.appending(path: "models.json"))
        #expect(AgentKind.piSignedIn(dir: dir))
        try Data(#"{"providers":{}}"#.utf8).write(to: dir.appending(path: "models.json"))
        try Data(#"{"openai-codex":{"type":"oauth"}}"#.utf8).write(to: dir.appending(path: "auth.json"))
        #expect(AgentKind.piSignedIn(dir: dir))
    }

    /// A Codex-only Mac: new conversations start on Codex, unless an agent was picked.
    @Test @MainActor func startsOnTheSignedInAgent() throws {
        let d = try #require(UserDefaults(suiteName: "takes-setup-\(UUID().uuidString)"))
        Setup.useSignedIn([.codex], defaults: d)
        #expect(d.string(forKey: "chatAgent") == "codex")
        d.set("pi", forKey: "chatAgent")
        Setup.useSignedIn([.codex], defaults: d)
        #expect(d.string(forKey: "chatAgent") == "pi")
        let none = try #require(UserDefaults(suiteName: "takes-setup-\(UUID().uuidString)"))
        Setup.useSignedIn([], defaults: none)
        #expect(none.string(forKey: "chatAgent") == nil)
    }

    /// Setup is done only when the agent the chat uses is signed in (review of 2026-10-12).
    @Test @MainActor func setupFollowsTheAgentTheChatUses() {
        #expect(Setup.readiness(here: [.claude, .pi], ready: [.claude], preferred: .pi) == (.pi, false))
        #expect(Setup.readiness(here: [.claude, .pi], ready: [.claude], preferred: .claude) == (.claude, true))
        #expect(Setup.readiness(here: [.codex], ready: [.codex], preferred: .claude) == (.codex, true))
        #expect(Setup.readiness(here: [], ready: [], preferred: .claude) == (.claude, false))
    }

    @Test @MainActor func nothingShowsBeforeTheFirstCheck() {
        let s = Setup()
        #expect(!s.needed)
        s.agent = .ok; s.signedIn = .missing; s.ffmpeg = .ok; s.devTools = .ok
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
    s.agent = .ok; s.signedIn = .missing; s.ffmpeg = .working; s.devTools = .missing
    let failed = Setup()
    failed.agent = .missing; failed.signedIn = .missing; failed.ffmpeg = .failed("The ffmpeg download did not match its checksum."); failed.devTools = .ok
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
