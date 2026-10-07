import Foundation
import Testing
@testable import Takes

/// Closing a session (every switch) writes the script only when it was edited in Takes (2026-10-06).
@MainActor
@Suite struct ScriptCloseTests {
    func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func anUntouchedSessionGetsNoScriptFile() throws {
        let dir = try session()
        SessionDoc(url: dir).close()
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "script.md").path))
    }

    @Test func closingKeepsAnEditMadeOutside() throws {
        let dir = try session()
        let file = dir.appending(path: "script.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let doc = SessionDoc(url: dir)
        try "from the chat".write(to: file, atomically: true, encoding: .utf8)
        doc.close()
        #expect(try String(contentsOf: file, encoding: .utf8) == "from the chat")
    }

    @Test func closingWritesAnEditMadeHere() throws {
        let dir = try session()
        let doc = SessionDoc(url: dir)
        doc.script = "typed in Takes"
        doc.close()
        #expect(try String(contentsOf: dir.appending(path: "script.md"), encoding: .utf8) == "typed in Takes")
    }
}
