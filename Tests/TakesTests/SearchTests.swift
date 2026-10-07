import Foundation
import Testing
@testable import Takes

// ⌘K search (2026-10-06). Before the model is downloaded, search matches file names and transcripts.

struct SearchTests {
    @Test func beforeTheModelFileNamesAndTranscriptsMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "search-\(UUID().uuidString)")
        let s = root.appending(path: "Proj/2026-10-06-idea")
        try FileManager.default.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        try Data().write(to: s.appending(path: "Hands Typing at Desk.mov"))
        try Data().write(to: s.appending(path: "edits/cut-v1.mp4"))
        try Data(#"[{"word":"pricing","start":3.0,"end":3.4}]"#.utf8).write(to: s.appending(path: "edits/cut-v1.words.json"))
        try Data("We talk about the launch.".utf8).write(to: s.appending(path: "script.md"))
        defer { try? FileManager.default.removeItem(at: root) }

        let names = await MediaSearch.byName("hands typing", root: root, limit: 10)
        #expect(names.map(\.path.lastPathComponent) == ["Hands Typing at Desk.mov"])
        let said = await MediaSearch.byName("Pricing", root: root, limit: 10)
        #expect(said.map(\.path.lastPathComponent) == ["cut-v1.mp4"])
        #expect(said.first?.kind == "speech")
        let script = await MediaSearch.byName("launch", root: root, limit: 10)
        #expect(script.map(\.kind) == ["script"])
        #expect(await MediaSearch.byName("nothing like this", root: root, limit: 10).isEmpty)
    }

    @MainActor @Test func boardsAndSessionsAreFoundByName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "search-\(UUID().uuidString)")
        let url = root.appending(path: "Weekly Challenge/2026-10-06-takes-launch-video")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = SessionDoc(url: url)
        doc.meta = SessionMeta(title: "Takes launch video", createdAt: Date(), named: true)
        doc.save()
        let app = AppModel()
        app.library.setRoot(root)
        let launch = MediaSearch.places("launch", app: app)
        #expect(launch.map(\.kind) == ["session"])
        #expect(launch.first?.title == "Takes launch video")
        #expect(launch.first?.text == "Weekly Challenge")
        #expect(MediaSearch.places("weekly", app: app).first?.kind == "project")
        // The public build has no social boards (Features.socialBoards), so no Performance there.
        let perf = MediaSearch.places("perf", app: app)
        if Features.socialBoards {
            #expect(perf.first?.board == .performance)
            #expect(perf.first?.title == "Performance")
        } else {
            #expect(!perf.contains { $0.board == .performance })
        }
        #expect(MediaSearch.places("styles", app: app).contains { $0.board == .styles })
        #expect(MediaSearch.places("zzqx nothing like this", app: app).isEmpty)
        #expect(MediaSearch.places("  ", app: app).isEmpty)
    }

    @Test func theModelIsPinnedAndAbout510MB() {
        #expect(MediaSearch.files.allSatisfy { $0.sha.count == 64 })
        #expect(MediaSearch.revision.count == 40)
        #expect((480_000_000...540_000_000).contains(MediaSearch.totalBytes))
    }
}
