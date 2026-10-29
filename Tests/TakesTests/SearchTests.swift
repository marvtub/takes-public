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
        let launch = MediaSearch.places("takes launch", app: app)
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
        // A sentence with the word scores high, but it does not hide the clips that show the thing.
        let laptop = MediaSearch.relevant([hit("e/cut.mp4", 4.9, "speech", text: "my laptop"), hit("s/script.md", 3.7, "script"),
                                           hit("b/typing.mov", 2.55), hit("b/table.mov", 2.43), hit("b/walk.mov", 1.1)])
        #expect(laptop.map(\.path.lastPathComponent) == ["cut.mp4", "script.md", "typing.mov", "table.mov"])
        // Nothing stands out: the best 3, so the list is never empty for a real query.
        #expect(MediaSearch.relevant([1.2, 1.1, 0.9, 0.5].map { hit("x\($0).mov", $0) }).count == 3)
        // The same sentence in eight versions of an edit shows once.
        let versions = (1...8).map { hit("P/s/edits/cut-v\($0).mp4", 2.5, "speech", text: "I pay for it") }
        #expect(MediaSearch.relevant(versions).count == 1)
        // Name matches (no score) always stay.
        #expect(MediaSearch.relevant([.init(path: root.appending(path: "n.mov"), kind: "video", start: 0)]).count == 1)
    }

    /// Best match keeps the panel's order, so no row moves when the results page opens.
    @Test func bestMatchKeepsTheOrderInOneGroup() {
        let hits = ["b", "a", "c"].map { MediaSearch.Hit(path: URL(fileURLWithPath: "/l/p/\($0).mov"), kind: "video", start: 0) }
        let s = MediaSearch.sections(hits, sort: .best)
        #expect(s.count == 1 && s[0].title == nil && s[0].hits == hits)
        #expect(MediaSearch.sections([], sort: .newest).isEmpty)
    }

    /// A date sort groups by Today, This week, This month, then by month, undated last.
    @Test func dateSortGroupsByWhenItWasMade() throws {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let now = try #require(f.date(from: "2026-10-27"))
        let path = { (s: String) in URL(fileURLWithPath: "/l/Weekly Challenge/\(s)/edits/a.mp4") }
        let hits = ["2026-09-30-old", "2026-10-27-today", "2026-10-22-week", "2026-10-03-month", "no-date"]
            .map { MediaSearch.Hit(path: path($0), kind: "video", start: 0) }
        let day = { (h: MediaSearch.Hit) -> Date? in
            let c = h.path.pathComponents[3]
            return c.first == "2" ? f.date(from: String(c.prefix(10))) : nil
        }
        let newest = MediaSearch.sections(hits, sort: .newest, now: now, date: day)
        #expect(newest.map(\.title) == ["Today", "This week", "This month", "September 2026", "Undated"])
        let oldest = MediaSearch.sections(hits, sort: .oldest, now: now, date: day)
        #expect(oldest.first?.title == "September 2026" && oldest.last?.title == "Undated")
        #expect(MediaSearch.day(of: path("2026-10-06-bookkeeping-agent")) == f.date(from: "2026-10-06"))
    }

    @Test func theCountSaysWhere() {
        #expect(MediaSearch.countLine(23, project: nil) == "23 results in all projects")
        #expect(MediaSearch.countLine(1, project: "Weekly Challenge") == "1 result in Weekly Challenge")
    }

    @Test func theShapeIsSaidInWords() {
        #expect(MediaSearch.shapeLine(width: 1080, height: 1920) == "Vertical 9:16 · 1080×1920")
        #expect(MediaSearch.shapeLine(width: 3840, height: 2160) == "Wide 16:9 · 3840×2160")
        #expect(MediaSearch.shapeLine(width: 1080, height: 1350) == "Portrait 4:5 · 1080×1350")
        #expect(MediaSearch.shapeLine(width: 1000, height: 1000) == "Square 1:1 · 1000×1000")
        #expect(MediaSearch.shapeLine(width: 2000, height: 900) == "Wide · 2000×900")
        #expect(MediaSearch.shapeLine(width: 0, height: 10) == "")
    }

    @Test func theModelIsPinnedAndAbout510MB() {
        #expect(MediaSearch.files.allSatisfy { $0.sha.count == 64 })
        #expect(MediaSearch.revision.count == 40)
        #expect((480_000_000...540_000_000).contains(MediaSearch.totalBytes))
    }
}
