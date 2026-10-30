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
        let app = AppModel()

        // Search (v2026.10.29): the results page's preview, one kind after another, each file in its own shape.
        let root = FileManager.default.temporaryDirectory.appending(path: "release-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Phone filming")
        let s = project.appending(path: "2026-10-20-how-i-film")
        try FileManager.default.createDirectory(at: s.appending(path: "stills"), withIntermediateDirectories: true)
        // The demo people (made up); the public copy has no scripts/public, so release-media.sh names the folder.
        let demo = ProcessInfo.processInfo.environment["TAKES_DEMO_MEDIA"].map { URL(fileURLWithPath: $0) }
            ?? Self.repo.appending(path: "scripts/public/demo-media")
        try FileManager.default.copyItem(at: demo.appending(path: "maya/creator-tall.jpg"), to: s.appending(path: "stills/kitchen-vertical.jpg"))
        try FileManager.default.copyItem(at: demo.appending(path: "lin/creator-wide.jpg"), to: s.appending(path: "stills/desk-wide.jpg"))
        try Data("# How I film on my phone\n\nFace the window. The light does most of the work.\n\nLock the exposure on your face, then clip the mic on and look at the lens.\n\nOne take a day, for a month. That is the whole trick.".utf8)
            .write(to: s.appending(path: "script.md"))
        try Store.encoder.encode(SessionMeta(title: "How I film on my phone", createdAt: Date())).write(to: s.appending(path: "session.json"))
        let hits = [MediaSearch.Hit(path: s.appending(path: "stills/kitchen-vertical.jpg"), kind: "image", start: 0),
                    MediaSearch.Hit(path: s.appending(path: "stills/desk-wide.jpg"), kind: "image", start: 0),
                    MediaSearch.Hit(path: s.appending(path: "script.md"), kind: "script", start: 0, text: "Lock the exposure"),
                    MediaSearch.Hit(path: s, kind: "session", start: 0, text: "Phone filming", title: "How I film on my phone")]
        let pick = SearchPick()
        let preview = SearchPickView(pick: pick, hits: hits, root: root).environment(app).tint(Theme.accent).font(Theme.body)
        try await film("search", preview, size: CGSize(width: 900, height: 640), seconds: 10,
                       beats: [(2.5, { pick.at = 1 }), (5, { pick.at = 2 }), (7.5, { pick.at = 3 })])
    }
}

/// The search scene's state: which hit the results page shows.
@MainActor @Observable final class SearchPick {
    var at = 0
}

struct SearchPickView: View {
    let pick: SearchPick
    let hits: [MediaSearch.Hit]
    let root: URL
    var body: some View {
        SearchPreview(hit: hits[pick.at], root: root, moments: [], open: { _ in }).id(pick.at)
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
