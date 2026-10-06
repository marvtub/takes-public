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

    /// The cards take the video's shape. A storyboard from before formats is 4:5, as its sketches are.
    @Test func theFormatGivesTheCardsTheirShape() throws {
        let wide = try JSONDecoder().decode(Storyboard.self, from: Data(#"{"shots": [], "format": "16:9"}"#.utf8))
        #expect(abs(wide.ratio - 16.0 / 9.0) < 0.001)
        let old = try JSONDecoder().decode(Storyboard.self, from: Data(#"{"shots": []}"#.utf8))
        #expect(old.format == nil && old.ratio == 0.8)
        #expect(Storyboard.ratio("9:16") == 0.5625 && Storyboard.ratio("nonsense") == 0.8)
        #expect(abs(Storyboard.ratio("21:9") - 21.0 / 9.0) < 0.001)
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
