import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The Storyboard tab with variants (2026-10-09), rendered to PNGs to look at.
/// Off by default: `TAKES_SNAPSHOT=/some/dir TAKES_SNAPSHOT_SESSION=<session folder> ./test.sh --filter StoryboardSnapshot`.
/// The session is copied first; its storyboard.json is left as it is.
@MainActor
struct StoryboardSnapshotTests {
    @Test func variants() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TAKES_SNAPSHOT"], let src = env["TAKES_SNAPSHOT_SESSION"] else { return }
        let s = FileManager.default.temporaryDirectory.appending(path: "sbsnap-\(UUID().uuidString)/P/session")
        try FileManager.default.createDirectory(at: s.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: s)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let app = AppModel()
        let board = try #require(Storyboard.read(s))
        var images: [String: NSImage] = [:]
        for n in board.shots.compactMap(\.image) { images[n] = StoryboardPane.sketch(Storyboard.folder(s).appending(path: n)) }
        // The pictures a window loads on appear: an offscreen window never appears.
        for x in board.shots {
            for f in Set(x.options + [x.video].compactMap { $0 }) {
                let u = s.appending(path: f)
                if StoryShot.isStill(f) { _ = StoryboardPane.sketch(u) } else { _ = await BrollLib.poster(u) }
            }
        }
        for (name, dark) in [("dark", true), ("light", false)] {
            let size = CGSize(width: 1200, height: 760)
            let host = NSHostingView(rootView: AnyView(StoryboardPane(doc: SessionDoc(url: s), board: board, images: images)
                .frame(width: size.width, height: size.height).background(Theme.canvas)
                .environment(app).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                               styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appending(path: "storyboard-variants-\(name).png"))
        }
    }

    /// The card a storyboard with no image key shows (2026-10-09). `TAKES_SNAPSHOT=/some/dir`.
    @Test func noKey() async throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let s = FileManager.default.temporaryDirectory.appending(path: "sbsnap-\(UUID().uuidString)/P/session")
        try FileManager.default.createDirectory(at: Storyboard.folder(s), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let json = #"{"nokey": true, "format": "16:9", "shots": [{"id": "s1", "section": "hook", "say": "I film every idea.", "sketch": "A man."}, {"id": "s2", "say": "Then Takes cuts it.", "sketch": "A desk."}]}"#
        try Data(json.utf8).write(to: Storyboard.file(s))
        let board = try #require(Storyboard.read(s))
        for (name, dark) in [("dark", true), ("light", false)] {
            let size = CGSize(width: 1200, height: 760)
            let host = NSHostingView(rootView: AnyView(StoryboardPane(doc: SessionDoc(url: s), board: board, images: [:])
                .frame(width: size.width, height: size.height).background(Theme.canvas)
                .environment(AppModel()).environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                               styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appending(path: "storyboard-nokey-\(name).png"))
        }
    }
}
