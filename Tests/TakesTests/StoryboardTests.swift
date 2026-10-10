import Foundation
import Testing
@testable import Takes

@Suite struct StoryboardTests {
    @Test func readsTheMCPFormatAndTimesEachShot() throws {
        let json = """
        {"shots": [{"kind": "DESK", "say": "one two three four five six seven eight nine ten eleven twelve thirteen",
                    "do": "To lens.", "sketch": "A man.", "image": "a1.png"},
                   {"kind": "MG", "say": "Hi.", "sketch": "Cards.", "seconds": 4, "error": "quota"},
                   {"sketch": "No words."}], "updated": "2026-10-03T00:00:00Z"}
        """
        let b = try JSONDecoder().decode(Storyboard.self, from: Data(json.utf8))
        #expect(b.shots.map(\.kind) == ["DESK", "MG", "SHOT"])
        #expect(b.shots[0].how == "To lens." && b.shots[0].image == "a1.png" && b.shots[1].error == "quota")
        #expect(b.shots[0].length == 5)       // 13 words at 2.6 a second
        #expect(b.starts == [0, 5, 9])        // the given 4 s, then at least 2 s
        #expect(Storyboard.clock(b.total) == "0:11")
    }

    // 2026-10-09: with no image key the MCP draws nothing and marks the storyboard; each shot without
    // a sketch says so instead of "Drawing…" forever.
    @Test func noImageKeyMarksTheShotsWithoutASketch() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: Storyboard.folder(dir), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"nokey": true, "shots": [{"id": "s1", "sketch": "A man."}, {"id": "s2", "sketch": "B", "image": "b.png"}]}"#
        try Data(json.utf8).write(to: Storyboard.file(dir))
        let b = try #require(Storyboard.read(dir))
        #expect(b.nokey == true)
        #expect(b.shots[0].error == "No sketch: Takes has no image key.")
        #expect(b.shots[1].error == nil)
        let old = try JSONDecoder().decode(Storyboard.self, from: Data(#"{"shots": []}"#.utf8))
        #expect(old.nokey == nil)
    }

    /// The cards take the video's shape. A storyboard from before formats is 4:5, as its sketches are.
    @Test func theFormatGivesTheCardsTheirShape() throws {
        let wide = try JSONDecoder().decode(Storyboard.self, from: Data(#"{"shots": [], "format": "16:9"}"#.utf8))
        #expect(abs(wide.ratio - 16.0 / 9.0) < 0.001)
        let old = try JSONDecoder().decode(Storyboard.self, from: Data(#"{"shots": []}"#.utf8))
        #expect(old.format == nil && old.ratio == 0.8)
        #expect(Storyboard.ratio("9:16") == 0.5625 && Storyboard.ratio("nonsense") == 0.8)
        #expect(abs(Storyboard.ratio("21:9") - 21.0 / 9.0) < 0.001)
    }

    // 2026-10-09: a shot with variants keeps them in a fixed order; the user picks the one in the video.
    @Test func variantsKeepTheirOrderAndAPickChangesOnlyTheVideo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: Storyboard.folder(dir), withIntermediateDirectories: true)
        let json = """
        {"shots": [{"id": "s5", "kind": "SCREEN", "sketch": "x", "video": "generated/c.png",
                    "variants": ["generated/a.png", "generated/b.mp4", "generated/c.png"], "extra": 1},
                   {"id": "s6", "sketch": "y", "video": "generated/d.mp4", "variants": ["generated/e.mp4"]},
                   {"id": "s7", "sketch": "z", "variants": ["generated/f.mp4", "generated/g.mp4"]}],
         "format": "16:9"}
        """
        try Data(json.utf8).write(to: Storyboard.file(dir))
        var b = try #require(Storyboard.read(dir))
        #expect(b.shots[0].options == ["generated/a.png", "generated/b.mp4", "generated/c.png"])
        #expect(b.shots[1].options == ["generated/d.mp4", "generated/e.mp4"])  // the video goes first when missing
        #expect(b.shots[2].options.isEmpty)                                    // nothing in the video yet
        #expect(StoryShot.letter(0) == "A" && StoryShot.letter(2) == "C")
        #expect(StoryShot.isStill("generated/a.png") && !StoryShot.isStill("generated/b.mp4"))

        #expect(Storyboard.pick(dir, shot: "s5", "generated/a.png"))
        b = try #require(Storyboard.read(dir))
        #expect(b.shots[0].video == "generated/a.png")
        #expect(b.shots[0].options == ["generated/a.png", "generated/b.mp4", "generated/c.png"])
        #expect(b.format == "16:9")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Storyboard.file(dir))) as? [String: Any]
        let first = (raw?["shots"] as? [[String: Any]])?.first
        #expect(first?["extra"] as? Int == 1)                                  // keys the app does not know stay
        #expect(!Storyboard.pick(dir, shot: "gone", "generated/a.png"))
    }

    @Test func aMotionGraphicIsNotFilmed() {
        #expect(StoryboardPane.howTitle("MG") == "What it shows")
        #expect(StoryboardPane.howTitle("DESK") == "How to film it")
    }

    @Test func ordersShotsByRowAndNumbersOldOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: Storyboard.folder(dir), withIntermediateDirectories: true)
        let json = """
        {"shots": [{"kind": "DESK", "sketch": "a"}, {"kind": "END", "sketch": "b"},
                   {"section": "hook", "kind": "MG", "sketch": "c"}, {"section": "main", "sketch": "d"}]}
        """
        try Data(json.utf8).write(to: Storyboard.file(dir))
        let b = try #require(Storyboard.read(dir))
        #expect(b.shots.map(\.sketch) == ["c", "a", "d", "b"])
        #expect(b.shots.map(\.id) == ["s3", "s1", "s4", "s2"])  // ids by position in the file, as the MCP gives them
        #expect(b.shots.map(\.section) == [.hook, .main, .main, .end])
    }

    @MainActor @Test func aShotTakeIsNamedAfterItsShot() throws {
        let json = """
        {"shots": [{"id": "a", "section": "hook", "say": "I do my bookkeeping, every month.", "sketch": "x"},
                   {"id": "b", "section": "main", "kind": "MG", "sketch": "y"},
                   {"id": "c", "section": "main", "say": "Then the agent finds it.", "sketch": "z"}]}
        """
        let b = try JSONDecoder().decode(Storyboard.self, from: Data(json.utf8))
        #expect(b.takeName(for: "a") == "Hook 1: I do my bookkeeping")
        #expect(b.takeName(for: "b") == "Main 1: Mg")
        #expect(b.takeName(for: "c") == "Main 2: Then the agent finds")
        #expect(b.takeName(for: "gone") == nil)
        #expect(SessionDoc.takeFile(number: 3, slug: Library.slug("Hook 1: I do my bookkeeping"), kind: .camera)
                == "take-03-hook-1-i-do-my-bookkeeping-camera.mov")
        let cut = try JSONDecoder().decode([String: TakeCut].self, from: Data(#"{"3":{"state":"done","start":2.4,"end":9.8,"clean":true}}"#.utf8))
        #expect(cut["3"]?.range == "2.4–9.8 s")
    }

    @Test func aTakeAndACommentPointAtTheirShot() throws {
        let take = try JSONDecoder().decode(Take.self, from: Data(#"{"number":1,"kind":"camera","file":"t.mov","startedAt":0,"keeper":false,"shot":"s2"}"#.utf8))
        #expect(take.shot == "s2")
        let c = try JSONDecoder().decode(Takes.Comment.self, from: Data(#"{"id":"c1","file":"storyboard/storyboard.json","text":"x","status":"open","by":"user","at":"","shot":"s2"}"#.utf8))
        #expect(c.shot == "s2")
    }
}
