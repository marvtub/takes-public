import AppKit
import SwiftUI
import Testing
@testable import Takes

// The first take (2026-10-08). The rules for when the card shows, and its pictures:
// TAKES_FIRSTTAKE=/tmp/shots TAKES_FIRSTTAKE_MEDIA=<dir with wide.mov, tall.mov, screen.mov>
// ./test.sh --filter FirstTakeShots
let firstTakeDir = ProcessInfo.processInfo.environment["TAKES_FIRSTTAKE"]
let firstTakeMedia = ProcessInfo.processInfo.environment["TAKES_FIRSTTAKE_MEDIA"]

@MainActor @Suite(.serialized) struct FirstTakeShots {
    let size = CGSize(width: 1360, height: 860)

    private func library() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "takes-firsttake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel()
        app.library.setRoot(root)
        return (app, root)
    }

    private func take(_ doc: SessionDoc, _ n: Int, _ kind: TakeKind = .camera, from: URL? = nil) {
        let file = "take-\(String(format: "%02d", n))-\(kind.rawValue).mov"
        if let from { try? FileManager.default.copyItem(at: from, to: doc.url.appending(path: file)) }
        doc.addTakes([Take(number: n, kind: kind, file: file, startedAt: Date(), duration: 42, script: nil, hook: nil, shot: nil)])
    }

    @Test func showsAfterTheFirstTakeOnly() throws {
        let d = UserDefaults.standard
        d.set(false, forKey: FirstTake.doneKey)
        defer { d.set(true, forKey: FirstTake.doneKey); FirstTake.shared.shown = false; FirstTake.shared.guide = nil }
        let (app, _) = try library()
        let flow = FirstTake.shared
        let doc = try #require(app.library.createSession())
        take(doc, 1)
        app.library.loadSessions()
        flow.afterTake(doc, number: 1, library: app.library)
        #expect(flow.shown)
        #expect(flow.moment?.number == 1)
        #expect(d.bool(forKey: FirstTake.doneKey))
        flow.shown = false
        // Never twice.
        take(doc, 2)
        flow.afterTake(doc, number: 2, library: app.library)
        #expect(!flow.shown)
    }

    @Test func aLibraryWithTakesIsPastItsFirst() throws {
        let d = UserDefaults.standard
        d.set(false, forKey: FirstTake.doneKey)
        defer { d.set(true, forKey: FirstTake.doneKey) }
        let (app, _) = try library()
        let doc = try #require(app.library.createSession())
        take(doc, 1)
        app.library.reload()
        FirstTake.shared.settle(app.library)
        #expect(d.bool(forKey: FirstTake.doneKey))
    }

    @Test func laterKeepsTheGuide() throws {
        defer { FirstTake.shared.guide = nil }
        let (app, _) = try library()
        let doc = try #require(app.library.createSession())
        take(doc, 1)
        FirstTake.shared.show(doc)
        FirstTake.shared.later()
        #expect(!FirstTake.shared.shown)
        #expect(FirstTake.shared.guide.map(Store.dir) == Store.dir(doc.url))
    }

    @Test func editingWaitsForSetup() {
        let s = Setup.shared
        let was = (s.claude, s.signedIn, s.ffmpeg)
        defer { (s.claude, s.signedIn, s.ffmpeg) = was }
        (s.claude, s.signedIn, s.ffmpeg) = (.ok, .missing, .ok)
        #expect(!FirstTake.shared.canEdit)
        s.signedIn = .ok
        #expect(FirstTake.shared.canEdit)
    }

    @Test func theConfettiFallsOnce() throws {
        defer { FirstTake.shared.shown = false }
        let (app, _) = try library()
        let doc = try #require(app.library.createSession())
        take(doc, 1)
        let flow = FirstTake.shared
        flow.show(doc)
        #expect(flow.confetti)
        flow.go(1)
        flow.go(0)
        #expect(!flow.confetti)
    }

    @Test func theGuideSeesAnEdit() throws {
        let (app, _) = try library()
        let doc = try #require(app.library.createSession())
        #expect(!FirstVideoGuide.hasEdit(doc.url))
        let edits = doc.url.appending(path: "edits")
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        try Data().write(to: edits.appending(path: "first-edit-v1.mp4"))
        #expect(FirstVideoGuide.hasEdit(doc.url))
    }

    func shoot(_ name: String, _ view: some View, wait: Double, dark: Bool) async {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(wait)
        while Date() < end { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: firstTakeDir!).appending(path: "\(name).png"))
    }

    @Test(.enabled(if: firstTakeDir != nil && firstTakeMedia != nil)) func pictures() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        NSApp.applicationIconImage = NSImage(contentsOf: repo.appending(path: "assets/Takes.icns"))
        MascotView.bodyImage = NSImage(contentsOf: repo.appending(path: "assets/brand/mascot-body-512.png"))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        let setup = Setup.shared
        let was = (setup.claude, setup.signedIn, setup.ffmpeg)
        defer { (setup.claude, setup.signedIn, setup.ffmpeg) = was }
        (setup.claude, setup.signedIn, setup.ffmpeg) = (.ok, .ok, .ok)
        Look.shared.palette = .graphite
        defer { Look.shared.reset() }
        UserDefaults.standard.set(false, forKey: "chatOpen")
        let media = URL(fileURLWithPath: firstTakeMedia!)
        let (app, root) = try library()
        let flow = FirstTake.shared
        defer { flow.shown = false; flow.guide = nil }
        func window() -> some View {
            ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body).foregroundStyle(Theme.ink)
                .overlay { FirstTakeLayer().environment(app) }
        }
        for fmt in ["wide", "tall", "screen"] {
            let doc = try #require(app.library.createSession())
            app.rename(doc, to: "How I plan my week", named: true)
            let now = try #require(app.library.current)
            now.script = String(repeating: "word ", count: 118)
            take(now, 1, from: media.appending(path: fmt == "tall" ? "tall.mov" : "wide.mov"))
            if fmt == "screen" { take(now, 1, .screen, from: media.appending(path: "screen.mov")) }
            flow.show(now)
            flow.scene = 0
            await shoot("1-celebrate-\(fmt)", window(), wait: 3.2, dark: true)
            flow.scene = 1
            await shoot("2-next-\(fmt)", window(), wait: 4.6, dark: true)
            if fmt == "wide" {
                setup.signedIn = .missing
                await shoot("2-next-setup", window(), wait: 1.5, dark: true)
                setup.signedIn = .ok
                flow.scene = 0
                await shoot("1-celebrate-wide-light", window(), wait: 3.2, dark: false)
            }
        }

        // "Ask Takes to edit": a fake claude makes the edit, as the real one does with ffmpeg.
        let fake = root.appending(path: "claude")
        let session = try #require(app.library.current).url
        try #"""
        #!/bin/bash
        cat > /dev/null
        d="\#(session.path)"
        mkdir -p "$d/edits" && cp "\#(media.appending(path: "wide.mov").path)" "$d/edits/first-edit-v1.mp4"
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Done. I cut 6 seconds of pauses and added captions: edits/first-edit-v1.mp4. Want me to write the LinkedIn post next?"}]}}'
        echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        ClaudeChat.claudeOverride = fake.path
        defer { ClaudeChat.claudeOverride = nil }
        flow.askForEdit(app: app)
        await shoot("3-asked", window(), wait: 0.8, dark: true)
        let chat = app.chats.chat(try #require(app.library.current).url)
        let end = Date().addingTimeInterval(10)
        while chat.running && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        NotificationCenter.default.post(name: .takesFilesChanged, object: [try #require(app.library.current).url.appending(path: "edits").path])
        app.library.reload()
        await shoot("4-edited", window(), wait: 2, dark: true)
        await shoot("4-edited-light", window(), wait: 1.5, dark: false)
    }
}
