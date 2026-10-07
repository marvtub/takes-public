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

    @Test func chipsSortHitsByWhereTheFileIs() {
        let root = URL(fileURLWithPath: "/T")
        func hit(_ p: String, _ kind: String = "video") -> MediaSearch.Hit { .init(path: root.appending(path: p), kind: kind, start: 0) }
        let take = hit("Proj/2026-10-06-idea/take-1.mov")
        let edit = hit("Proj/2026-10-06-idea/edits/cut-v2.mp4", "speech")
        let broll = hit("Proj/2026-10-06-idea/broll/desk.mp4")
        let lib = hit("_library/broll/01 Desk/typing.mov")
        let still = hit("Proj/2026-10-06-idea/stills/frame.png", "image")
        let script = hit("Proj/2026-10-06-idea/script.md", "script")
        #expect([take, edit, broll, lib, still, script].map(MediaSearch.filter(of:)) == [.takes, .edits, .broll, .broll, .stills, .scripts])
        let session = MediaSearch.Hit(path: root.appending(path: "Proj/2026-10-06-idea"), kind: "session", start: 0, title: "Idea")
        #expect(MediaSearch.keeps(session, .all, project: nil))
        #expect(!MediaSearch.keeps(session, .edits, project: nil))
        // The project menu keeps only that project's files; library b-roll is in no project.
        let proj = root.appending(path: "Proj")
        #expect(MediaSearch.keeps(edit, .edits, project: proj))
        #expect(!MediaSearch.keeps(lib, .broll, project: proj))
        #expect(!MediaSearch.keeps(hit("Project Two/x/take-1.mov"), .all, project: proj))
        #expect(MediaSearch.keeps(session, .all, project: proj))
    }

    /// "headphones" on the real b-roll: 9 clips stood out, then a gap. Only those show.
    @Test func onlyHitsThatStandOutShow() {
        let root = URL(fileURLWithPath: "/T")
        func hit(_ name: String, _ z: Double, _ kind: String = "video", text: String? = nil) -> MediaSearch.Hit {
            .init(path: root.appending(path: name), kind: kind, start: 0, text: text, rank: z)
        }
        let zs = [2.76, 2.51, 2.48, 2.41, 2.39, 2.33, 2.24, 2.16, 2.13, 1.52, 1.39, 0.93, 0.87]
        let kept = MediaSearch.relevant(zs.enumerated().map { hit("b/\($0.offset).mov", $0.element) })
        #expect(kept.count == 9)
        // A strong hit raises the bar: within 2 of the best.
        #expect(MediaSearch.relevant([hit("a.mov", 4.5), hit("b.mov", 3.0), hit("c.mov", 2.2)]).count == 2)
        // Nothing stands out: the best 3, so the list is never empty for a real query.
        #expect(MediaSearch.relevant([1.2, 1.1, 0.9, 0.5].map { hit("x\($0).mov", $0) }).count == 3)
        // The same sentence in eight versions of an edit shows once.
        let versions = (1...8).map { hit("P/s/edits/cut-v\($0).mp4", 2.5, "speech", text: "I pay for it") }
        #expect(MediaSearch.relevant(versions).count == 1)
        // Name matches (no score) always stay.
        #expect(MediaSearch.relevant([.init(path: root.appending(path: "n.mov"), kind: "video", start: 0)]).count == 1)
    }

    @Test func theModelIsPinnedAndAbout510MB() {
        #expect(MediaSearch.files.allSatisfy { $0.sha.count == 64 })
        #expect(MediaSearch.revision.count == 40)
        #expect((480_000_000...540_000_000).contains(MediaSearch.totalBytes))
    }
}
