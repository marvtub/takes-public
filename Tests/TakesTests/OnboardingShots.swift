import AppKit
import SwiftUI
import Testing
@testable import Takes

// The welcome pages as a new user sees them (2026-10-06): the window on an empty library, the
// modal on top. TAKES_ONBOARDING=/tmp/shots ./test.sh --filter OnboardingShots
let onboardingDir = ProcessInfo.processInfo.environment["TAKES_ONBOARDING"]

@MainActor @Suite(.serialized) struct OnboardingShots {
    let size = CGSize(width: 1360, height: 860)

    func shoot(_ name: String, _ view: some View, dark: Bool) async {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(1.5)
        while Date() < end { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: onboardingDir!).appending(path: "\(name).png"))
    }

    /// The motion: every page filmed for a few seconds at 20 frames a second, as numbered PNGs in
    /// <dir>/motion-<page>/. ffmpeg turns them into a clip.
    @Test(.enabled(if: onboardingDir != nil && ProcessInfo.processInfo.environment["TAKES_MOTION"] != nil))
    func motion() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        NSApp.applicationIconImage = NSImage(contentsOf: repo.appending(path: "assets/Takes.icns"))
        Onboarding.creator = NSImage(contentsOf: repo.appending(path: "assets/onboarding/creator.jpg"))
        Look.shared.palette = .graphite
        defer { Look.shared.reset() }
        let setup = Setup.shared
        setup.claude = .ok; setup.signedIn = .ok; setup.ffmpeg = .ok
        let app = AppModel()
        let flow = Onboarding.shared
        let card = CGSize(width: 800, height: 600)
        let slow = 6.0
        Onboarding.pace = slow
        defer { Onboarding.pace = 1 }
        for p in 0..<Onboarding.pages {
            flow.page = p
            let dir = URL(fileURLWithPath: onboardingDir!).appending(path: "motion-\(p + 1)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let view = OnboardingCard(flow: flow).environment(app).tint(Theme.accent).font(Theme.body)
                .foregroundStyle(Theme.ink).frame(width: card.width, height: card.height).background(Theme.canvas)
            let host = NSHostingView(rootView: AnyView(view))
            host.frame = NSRect(origin: .zero, size: card)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: card.width, height: card.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            // A frame takes ~130 ms to draw here, so the motion runs `slow` times slower and each frame
            // keeps its time in the app: ffmpeg plays them at real speed (times.txt, concat form).
            let start = Date()
            var times = "ffconcat version 1.0\n"
            var last: (String, Double)?
            var i = 0
            while Date().timeIntervalSince(start) < (p == 1 ? 9 : 5) * slow {
                try? await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = String(format: "%04d.jpg", i)
                try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: dir.appending(path: name))
                let t = Date().timeIntervalSince(start) / slow
                if let last { times += "file \(last.0)\nduration \(String(format: "%.3f", t - last.1))\n" }
                last = (name, t)
                i += 1
            }
            if let last { times += "file \(last.0)\nduration 0.1\n" }
            try times.write(to: dir.appending(path: "times.txt"), atomically: true, encoding: .utf8)
            window.orderOut(nil)
        }
    }

    @Test(.enabled(if: onboardingDir != nil)) func pages() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        NSApp.applicationIconImage = NSImage(contentsOf: repo.appending(path: "assets/Takes.icns"))
        Onboarding.creator = NSImage(contentsOf: repo.appending(path: "assets/onboarding/creator.jpg"))
        Look.shared.palette = .graphite
        defer { Look.shared.reset() }
        let d = UserDefaults.standard
        d.set(false, forKey: "chatOpen")

        let empty = FileManager.default.temporaryDirectory.appending(path: "takes-onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let app = AppModel()
        app.library.setRoot(empty)
        let flow = Onboarding.shared
        flow.shown = true
        func window() -> some View {
            ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body).foregroundStyle(Theme.ink)
                .overlay { OnboardingLayer().environment(app) }
        }
        let setup = Setup.shared
        for dark in [true, false] {
            let tag = dark ? "" : "-light"
            for p in 0..<Onboarding.pages {
                flow.page = p
                if p == 2 {
                    // A new Mac: nothing installed yet.
                    setup.claude = .missing; setup.signedIn = .missing; setup.ffmpeg = .missing
                    await shoot("3-start-setup\(tag)", window(), dark: dark)
                    setup.claude = .ok; setup.signedIn = .ok; setup.ffmpeg = .ok
                    await shoot("3-start-ready\(tag)", window(), dark: dark)
                } else {
                    await shoot(p == 0 ? "1-welcome\(tag)" : "2-how\(tag)", window(), dark: dark)
                }
            }
        }
        flow.shown = false

        // What "Write my script" leads to: a new session on Record, the chat open, the script in
        // place. A fake claude writes the script, as the real one does through its tools.
        let fake = empty.appending(path: "claude")
        try #"""
        #!/bin/bash
        cat > /dev/null
        d=$(ls -d "\#(empty.path)"/Inbox/*/ | head -1)
        printf '%s\n' "Most weeks plan themselves. Mine don't." "" "Every Sunday I take ten minutes and pick three things." "Not ten. Three." "" "If the week goes wrong, those three still get done." "Everything else is a bonus." "" "Try it this Sunday." > "${d}script.md"
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"'"${d}"'script.md"}}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Your script is in the session: about 30 seconds, three short parts. Press record when you are ready, or ask me to change a line."}]}}'
        echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        ClaudeChat.claudeOverride = fake.path
        defer { ClaudeChat.claudeOverride = nil }
        flow.write("How I plan my week", app: app)
        let doc = try #require(app.library.current)
        let chat = app.chats.chat(doc.url)
        let end = Date().addingTimeInterval(10)
        while chat.running && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        app.library.reload()
        for dark in [true, false] {
            await shoot("4-after-write\(dark ? "" : "-light")", window(), dark: dark)
        }
    }
}
