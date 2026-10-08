import Foundation
import Testing
@testable import Takes

@MainActor @Suite struct TranscriptTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Runs glue into words when a run starts with no space; one run with two words shares its time.
    @Test func runsBecomeWords() {
        let w = Transcript.words(from: [(" Hel", 0, 0.2), ("lo", 0.2, 0.4), (" big world", 0.5, 1.5), (" ", 1.5, 1.6), ("again", 2, 2.4)])
        #expect(w.map(\.word) == ["Hello", "big", "world", "again"])
        #expect(w[0].start == 0 && w[0].end == 0.4)
        #expect(w[1].end == 1.0 && w[2].start == 1.0)
    }

    /// Ours, Whisper's segments and the compact list all read back.
    @Test func readsEveryFormat() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let v = d.appending(path: "take-01-camera.mov")
        try Transcript.write([Word(word: "Hi", start: 0.1234, end: 0.5)], source: "test", for: v)
        #expect(Transcript.words(for: v) == [Word(word: "Hi", start: 0.123, end: 0.5)])
        try #"{"segments": [{"words": [{"word": " So", "start": 1, "end": 1.2}]}]}"#.write(to: Transcript.file(for: v), atomically: true, encoding: .utf8)
        #expect(Transcript.text(for: v) == "So")
        try #"[["one", 0, 0.3], ["two", 0.3]]"#.write(to: Transcript.file(for: v), atomically: true, encoding: .utf8)
        #expect(Transcript.words(for: v)?.last == Word(word: "two", start: 0.3, end: 0.3))
        #expect(Transcript.file(for: v).lastPathComponent == "take-01-camera.words.json")
    }

    /// The sweep finds camera files without a transcript, newest session first, and skips the
    /// screen file of a take that has a camera file.
    @Test func sweepFindsMissing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        func session(_ name: String, _ day: Double, _ takes: [Take]) throws -> URL {
            let s = root.appending(path: "P/\(name)")
            try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
            var m = SessionMeta(title: name, createdAt: Date(timeIntervalSince1970: day * 86400))
            m.takes = takes
            try Store.encoder.encode(m).write(to: s.appending(path: "session.json"))
            for t in takes { try Data().write(to: s.appending(path: t.file)) }
            return s
        }
        let t = Date()
        let old = try session("old", 1, [Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: t)])
        let new = try session("new", 2, [Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: t),
                                         Take(number: 1, kind: .screen, file: "take-01-screen.mov", startedAt: t),
                                         Take(number: 2, kind: .screen, file: "take-02-screen.mov", startedAt: t)])
        try Transcript.write([], source: "test", for: new.appending(path: "take-01-camera.mov"))
        let found = Transcripts.missing(in: root).map(\.lastPathComponent)
        #expect(found == ["take-02-screen.mov", "take-01-camera.mov"])
        #expect(Transcripts.missing(in: root).last?.deletingLastPathComponent().lastPathComponent == old.lastPathComponent)
    }

    /// A take renamed in the app keeps its transcript; trashed, the transcript goes too.
    @Test func renameMovesTheTranscript() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = root.appending(path: "P/2026-10-08-x")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        var m = SessionMeta(title: "x", createdAt: Date())
        m.takes = [Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: Date())]
        try Store.encoder.encode(m).write(to: s.appending(path: "session.json"))
        try Data().write(to: s.appending(path: "take-01-camera.mov"))
        try Transcript.write([Word(word: "Hi", start: 0, end: 1)], source: "test", for: s.appending(path: "take-01-camera.mov"))
        let doc = SessionDoc(url: s)
        doc.renameTake(1, to: "Hook")
        #expect(Transcript.text(for: s.appending(path: "take-01-hook-camera.mov")) == "Hi")
        #expect(!FileManager.default.fileExists(atPath: s.appending(path: "take-01-camera.words.json").path))
    }

    /// Real speech through Apple's model: the words and their times come out in order.
    @Test func transcribesSpeech() async throws {
        guard #available(macOS 26, *) else { return }
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let audio = d.appending(path: "take-01-camera.m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["--file-format=m4af", "-o", audio.path, "Hello there. Today I show you my video app."]
        try say.run()
        say.waitUntilExit()
        let words = try await SpeechFile.words(of: audio, locale: Locale(identifier: "en-US"))
        let text = words.map(\.word).joined(separator: " ").lowercased()
        #expect(text.contains("hello") && text.contains("video"))
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect((words.last?.end ?? 0) > 1.5)
    }
}
