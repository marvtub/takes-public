import AppKit
import SwiftUI
import Testing
@testable import Takes

// Pictures for the release notes (2026-10-24): each change people can see gets a still or a short
// film, drawn from the real views on the public copy, with made-up data (never the user's library).
// They go on the GitHub release and are kept for marketing in scripts/public/docs/releases/<tag>/.
//   scripts/public/release-media.sh        # exports the public copy, runs this suite, makes the files
// Each release, replace `thisRelease` with the scenes of its changes: `still` for a view, `film`
// for motion (a page that changes, a list that fills). release-media.sh turns every film into an
// .mp4 (marketing) and an animated .webp (the notes).
let releaseMediaDir = ProcessInfo.processInfo.environment["TAKES_RELEASE_MEDIA"]

@MainActor @Suite(.serialized) struct ReleaseShots {
    var out: URL { URL(fileURLWithPath: releaseMediaDir!) }
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")

    /// The app's look in every picture: its fonts, its icon, Graphite.
    static func setUp() {
        _ = NSApplication.shared
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        NSApp.applicationIconImage = NSImage(contentsOf: repo.appending(path: "assets/Takes.icns"))
        Look.shared.palette = .graphite
    }

    /// One picture of a view, as `<name>.png`. Use it for a change that does not move.
    func still(_ name: String, _ view: some View, size: CGSize, dark: Bool = true, wait: Double = 1.5) async {
        await ReadmeShots().shoot(name, view.foregroundStyle(Theme.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas), dark: dark, wait: wait, size: size, dir: out.path)
    }

    /// A short film of a view at the app's real speed, as numbered frames in `<name>.film/` with
    /// their times (ffconcat). `beats` change the state at a second of the film: a click, a page.
    /// Drawing a frame off screen takes about 130 ms, so the motion runs `slow` times slower while
    /// it films, and each frame keeps its time in the app.
    func film(_ name: String, _ view: some View, size: CGSize, seconds: Double, dark: Bool = true,
              beats: [(at: Double, run: () -> Void)] = [], slow: Double = 6) async throws {
        let dir = out.appending(path: "\(name).film")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Theme.pace = slow
        Onboarding.pace = slow
        defer { Theme.pace = 1; Onboarding.pace = 1 }
        // Top-aligned: a view that grows or shrinks (a page with more rows) stays in place.
        let host = NSHostingView(rootView: AnyView(view.foregroundStyle(Theme.ink)
            .frame(width: size.width, height: size.height, alignment: .top).background(Theme.canvas)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var todo = beats.sorted { $0.at < $1.at }
        var times = "ffconcat version 1.0\n"
        var last: (String, Double)?
        var i = 0
        let start = Date()
        while true {
            let t = Date().timeIntervalSince(start) / slow
            if t > seconds { break }
            while let b = todo.first, b.at <= t { todo.removeFirst(); b.run() }
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = String(format: "%04d.png", i)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: file))
            let now = Date().timeIntervalSince(start) / slow
            if let last { times += "file \(last.0)\nduration \(String(format: "%.3f", now - last.1))\n" }
            last = (file, now)
            i += 1
        }
        if let last { times += "file \(last.0)\nduration 0.5\nfile \(last.0)\n" }
        try times.write(to: dir.appending(path: "times.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: This release

    @Test(.enabled(if: releaseMediaDir != nil)) func thisRelease() async throws {
        Self.setUp()
        defer { Look.shared.reset() }
        let setup = Setup.shared
        setup.agent = .ok; setup.signedIn = .ok; setup.ffmpeg = .ok; setup.devTools = .ok
        Onboarding.creator = NSImage(contentsOf: Self.repo.appending(path: "assets/onboarding/creator.jpg"))
        Onboarding.tiles = Self.repo.appending(path: "assets/onboarding/styles")
        let app = AppModel()

        // Welcome: the four pages, one after the other.
        let flow = Onboarding.shared
        flow.show()
        flow.idea = "How I plan my week"
        let card = OnboardingCard(flow: flow).environment(app).tint(Theme.accent).font(Theme.body)
            .padding(40)
        try await film("welcome", card, size: CGSize(width: 840, height: 636), seconds: 15,
                       beats: [(3.5, { flow.go(1) }), (7.5, { flow.go(2) }), (11, { flow.go(3) })])
        flow.shown = false

        // Help: the guide, then the shortcuts.
        let help = HelpCenter.shared
        help.page = .guide
        let helpView = HelpView().environment(app).tint(Theme.accent).font(Theme.body)
            .frame(maxHeight: .infinity, alignment: .top).background(Theme.paper)
        try await film("help", helpView, size: CGSize(width: 600, height: 600), seconds: 6,
                       beats: [(3, { withAnimation(Theme.motion) { help.page = .shortcuts } })])
        help.page = .guide

        // Chat: the commands the agent left running come up one by one; Stop ends one.
        let running = RunningDemo()
        try await film("chat-commands", RunningDemoView(demo: running), size: CGSize(width: 560, height: 300), seconds: 7,
                       beats: [(0.8, { withAnimation(Theme.motion) { running.shown = 1 } }),
                               (2.0, { withAnimation(Theme.motion) { running.shown = 2 } }),
                               (4.5, { withAnimation(Theme.motion) { running.stopped = true } })])
    }
}

/// The chat's foot as it looks while the agent runs commands: its last words, the commands, the box.
@MainActor @Observable final class RunningDemo {
    var shown = 0
    var stopped = false
}

struct RunningDemoView: View {
    let demo: RunningDemo
    let commands = [AgentCommand(pid: 1, command: "npm run dev", seconds: 74, port: 5173),
                    AgentCommand(pid: 2, command: "python3 watch_renders.py --folder edits", seconds: 312)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The preview runs at localhost:5173, and I'm watching edits/ for new renders. Stop either one below.")
                .font(Theme.sans(13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                ForEach(Array(commands.prefix(demo.shown).enumerated()), id: \.element.id) { i, c in
                    if !(demo.stopped && i == 1) { AgentCommandChip(command: c) {} }
                }
            }
            HStack {
                Text("Ask Takes…").font(Theme.sans(13)).foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
