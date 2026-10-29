import AVFoundation
import Foundation
import Testing
@testable import Takes

// Edit-ready takes (2026-10-11): a session id that stays on a rename, old paths in .moves.json, word
// times prepared when a take is saved, and the voice WAV on the video clock. mcp/takes_mcp.py writes
// the same files (mcp/tests/test_edit_ready.py).

@MainActor
@Suite(.serialized)
struct EditReadyTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "editready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "P"), withIntermediateDirectories: true)
    }

    func session(_ name: String, created: String = "2026-10-11T18:00:00Z") throws -> URL {
        let s = root.appending(path: "P/\(name)", directoryHint: .isDirectory)
        try fm.createDirectory(at: s, withIntermediateDirectories: true)
        try #"{"title": "\#(name)", "createdAt": "\#(created)", "named": true, "takes": []}"#
            .write(to: s.appending(path: "session.json"), atomically: true, encoding: .utf8)
        return s
    }

    func cleanup() { try? fm.removeItem(at: root) }

    @Test func derivedIDMatchesServer() throws {
        defer { cleanup() }
        let s = try session("2026-10-11-demo")
        let server = AgentDocsTests.repo.appending(path: "mcp/takes_mcp.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [server.path, "--session-id", s.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let id = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(id.count == 12)
        #expect(Store.derivedID(s) == id)
        // Two sessions made in the same second still get two ids.
        #expect(Store.derivedID(try session("2026-10-11-twin")) != id)
    }

    @Test func derivedIDSurvivesRename() throws {
        defer { cleanup() }
        let s = try session("2026-10-11-demo")
        let id = Store.derivedID(s)
        let doc = SessionDoc(url: s)
        #expect(doc.meta.id == id)
        doc.rename(to: "Better name")
        #expect(doc.url.lastPathComponent == "2026-10-11-better-name")
        #expect(Store.readMeta(doc.url)?.id == id, "the first save stores it")
        #expect(Store.derivedID(doc.url) == id)
    }

    @Test func renameWritesMoveAndRenameBackGetsTheOriginalName() throws {
        defer { cleanup() }
        let a = try session("2026-10-11-demo")
        let doc = SessionDoc(url: a)
        doc.rename(to: "B")
        #expect(Store.readMoves(root)?["P/2026-10-11-demo"] == "P/2026-10-11-b")
        #expect(Store.followMoves(a)?.lastPathComponent == "2026-10-11-b")
        doc.rename(to: "demo")  // Undo Rename does the same
        #expect(doc.url.lastPathComponent == "2026-10-11-demo", "no -2: the old name leads to this session")
        let moves = Store.readMoves(root) ?? [:]
        #expect(moves["P/2026-10-11-demo"] == nil, "no loop")
        #expect(moves["P/2026-10-11-b"] == "P/2026-10-11-demo")
    }

    @Test func createSessionSkipsNameOfOtherMovedSession() throws {
        defer { cleanup() }
        let lib = Library()
        lib.setRoot(root)
        guard let first = lib.createSession(in: lib.projects.first { $0.name == "P" }?.url) else { Issue.record("no session"); return }
        let untitled = first.url.lastPathComponent
        #expect(untitled.hasSuffix("-untitled"))
        #expect(first.meta.id == Store.derivedID(first.url))
        first.rename(to: "Real")
        let second = lib.createSession()
        #expect(second?.url.lastPathComponent == untitled + "-2", "the old path still means the renamed session")
        // Trashed: the name is free again.
        try fm.removeItem(at: first.url)
        try fm.removeItem(at: second!.url)
        #expect(lib.createSession()?.url.lastPathComponent == untitled)
    }

    @Test func moveSessionsWritesMoves() throws {
        defer { cleanup() }
        let s = try session("2026-10-11-demo")
        let q = root.appending(path: "Q", directoryHint: .isDirectory)
        try fm.createDirectory(at: q, withIntermediateDirectories: true)
        let lib = Library()
        lib.setRoot(root)
        lib.moveSessions([Store.dir(s)], to: Store.dir(q))
        #expect(Store.readMoves(root)?["P/2026-10-11-demo"] == "Q/2026-10-11-demo")
    }

    @Test func addTakesStartsPrepare() throws {
        defer { cleanup(); Voice.launcher = { Voice.launch($0) } }
        var calls: [[String]] = []
        Voice.launcher = { calls.append($0); return true }
        let doc = SessionDoc(url: try session("2026-10-11-demo"))
        let at = Date()
        doc.addTakes([Take(number: 3, kind: .camera, file: "take-03-camera.mov", startedAt: at),
                      Take(number: 3, kind: .screen, file: "take-03-screen.mov", startedAt: at)])
        #expect(calls == [["--prepare", doc.url.path, "3"]], "one call per take number")
    }

    @Test func appleWordsNeverReplacePreparedWords() throws {
        defer { cleanup() }
        let s = try session("2026-10-11-demo")
        let video = s.appending(path: "take-01-camera.mov")
        #expect(Transcript.shouldWrite(video))
        try #"{"words": [], "source": "apple en_US"}"#.write(to: Transcript.file(for: video), atomically: true, encoding: .utf8)
        #expect(Transcript.shouldWrite(video))
        try #"{"v": 2, "clock": "video", "words": [{"word": "Hi", "start": 0.4, "end": 0.6}]}"#
            .write(to: Transcript.file(for: video), atomically: true, encoding: .utf8)
        #expect(!Transcript.shouldWrite(video))
        #expect(Transcript.words(for: video)?.map(\.word) == ["Hi"], "the app still reads the words")
    }

    @Test func voicePlayerInsertTime() {
        let start = CMTime(seconds: 0.177, preferredTimescale: 48000)
        #expect(Voice.insertTime(clock: "video", audioStart: start) == .zero)
        #expect(Voice.insertTime(clock: nil, audioStart: start) == start)
    }

    @Test func recordingMarker() throws {
        defer { cleanup() }
        Store.markRecording(root, true)
        let pid = try String(contentsOf: root.appending(path: ".recording"), encoding: .utf8)
        #expect(pid == String(ProcessInfo.processInfo.processIdentifier))
        Store.markRecording(root, false)
        #expect(!fm.fileExists(atPath: root.appending(path: ".recording").path))
    }
}
