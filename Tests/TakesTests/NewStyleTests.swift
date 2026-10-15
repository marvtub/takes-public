import Foundation
import SwiftUI
import Testing
@testable import Takes

extension Snap {
    /// The New style sheet the first time: the drop area, the field, ideas and what happens next.
    @Test(.enabled(if: snapDir != nil)) func newStyleSheet() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        app.library.setRoot(root)
        UserDefaults.standard.removeObject(forKey: "styleSheetSeen")
        let view = NewStyleSheet(example: .constant(""), files: .constant([]), busy: false,
                                 steps: StylesBoard.steps, make: {}, cancel: {}).environment(app)
        shoot("new-style-sheet", view, size: CGSize(width: 500, height: 640))
    }

    /// 2026-10-13: dropped files pop in as cards on the stage, and a link shows as a card too.
    @Test(.enabled(if: snapDir != nil)) func newStyleSheetWithFiles() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "style-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let video = tmp.appending(path: "reel.mp4"), image = tmp.appending(path: "look.png")
        for (args, out) in [(["-f", "lavfi", "-i", "testsrc2=size=360x640:rate=30:duration=24", "-c:v", "libx264", "-pix_fmt", "yuv420p"], video),
                            (["-f", "lavfi", "-i", "mandelbrot=size=480x640", "-frames:v", "1"], image)] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-v", "error", "-y"] + args + [out.path]
            try p.run()
            p.waitUntilExit()
        }
        for url in [video, image] { _ = await Thumbs.shared.image(Asset.at(url)) }
        _ = await Thumbs.shared.duration(Asset.at(video))
        UserDefaults.standard.set(true, forKey: "styleSheetSeen")
        for (name, text, files) in [("new-style-sheet-files", "The yellow captions", [video, image]),
                                    ("new-style-sheet-link", "https://www.tiktok.com/@someone/video/7412", [video])] {
            for dark in [false, true] {
                let view = NewStyleSheet(example: .constant(text), files: .constant(files), busy: false,
                                         steps: StylesBoard.steps, make: {}, cancel: {})
                shoot(name + (dark ? "-dark" : ""), view, size: CGSize(width: 500, height: 600), dark: dark)
            }
        }
    }
}

@MainActor
struct StyleLinkTests {
    @Test func aLinkIsNamedAfterItsSite() {
        #expect(StyleLink(in: "like this https://www.tiktok.com/@a/video/1 please")?.site == "TikTok")
        #expect(StyleLink(in: "https://www.instagram.com/reel/abc/")?.site == "Instagram reel")
        #expect(StyleLink(in: "https://youtu.be/xyz")?.site == "YouTube")
        #expect(StyleLink(in: "https://example.com/a")?.address == "example.com/a")
        #expect(StyleLink(in: "Yellow captions, black cards") == nil)
    }
}

@MainActor
struct StyleProgressTests {
    /// The Making card: step 1 before the folder, 2 with it, 3 once a motion part is kept.
    @Test func styleProgress() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "styleprog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = StyleLib.style("Old", root: root)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(5)
        #expect(StylesBoard.progress(root: root, since: since).name == nil)
        #expect(StylesBoard.progress(root: root, since: since).step == 1)
        let fresh = StyleLib.style("Fresh", root: root)
        try FileManager.default.createDirectory(at: fresh.appending(path: "assets/Motion"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: since.addingTimeInterval(1)], ofItemAtPath: fresh.path)
        try Data("{}".utf8).write(to: fresh.appending(path: "tokens.json"))
        #expect(StylesBoard.progress(root: root, since: since).name == "Fresh")
        #expect(StylesBoard.progress(root: root, since: since).step == 2)
        try Data().write(to: fresh.appending(path: "assets/Motion/title-v1.mp4"))
        #expect(StylesBoard.progress(root: root, since: since).step == 3)
    }
}
