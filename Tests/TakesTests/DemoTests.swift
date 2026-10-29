import Foundation
import Testing
@testable import Takes

/// The demo session (2026-10-09): the pack unpacks into "Start here", a library gets it once, and
/// without the download it still comes, with the script.
@MainActor @Suite(.serialized) struct DemoTests {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "takes-demo-\(UUID().uuidString)")

    func fresh() throws -> Library {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: Demo.doneKey)
        let lib = Library()
        lib.setRoot(root)
        return lib
    }

    func cleanup(_ pack: URL) {
        Demo.pack = pack
        UserDefaults.standard.removeObject(forKey: Demo.doneKey)
        try? FileManager.default.removeItem(at: root)
    }

    /// A zip like takes-demo.zip: one session folder with its session.json and an edit.
    func zip() throws -> URL {
        let src = root.appending(path: "_src/\(Demo.folder)")  // "_": not a project
        try FileManager.default.createDirectory(at: src.appending(path: "edits"), withIntermediateDirectories: true)
        try #"{"title": "Your first video", "createdAt": "2026-10-09T01:31:04Z", "named": true, "takes": [], "opens": {"tab": "assets", "file": "edits/first-video-v1.mp4"}}"#
            .write(to: src.appending(path: "session.json"), atomically: true, encoding: .utf8)
        try Data("video".utf8).write(to: src.appending(path: "edits/first-video-v1.mp4"))
        let out = root.appending(path: "takes-demo.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, out.path]
        try p.run(); p.waitUntilExit()
        return out
    }

    @Test func installsThePackOnceAndOpensItOnItsEdit() async throws {
        let saved = Demo.pack
        defer { cleanup(saved) }
        let lib = try fresh()
        Demo.pack = try zip()
        let url = try #require(await Demo.shared.add(lib))
        #expect(url.path == root.appending(path: "Start here/\(Demo.folder)").path)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "edits/first-video-v1.mp4").path))
        #expect(lib.current?.meta.title == "Your first video")
        #expect(lib.projects.map(\.name) == ["Start here"])
        let manifest = try String(contentsOf: url.appending(path: "SESSION.md"), encoding: .utf8)
        #expect(manifest.contains(url.path), "SESSION.md names this Mac's folder, not the pack's")
        #expect(SessionView.read(url).mode == .assets, "it opens on its edit")
        // Again: the same session opens, no second copy.
        #expect(await Demo.shared.add(lib) == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { !$0.hasPrefix(".") } == [Demo.folder])
    }

    @Test func withoutTheDownloadTheScriptStillComes() async throws {
        let saved = Demo.pack
        defer { cleanup(saved) }
        let lib = try fresh()
        Demo.pack = root.appending(path: "missing.zip")
        let url = try #require(await Demo.shared.add(lib))
        let script = try String(contentsOf: url.appending(path: "script.md"), encoding: .utf8)
        #expect(script.hasPrefix("This app records the take"))
        #expect(lib.current?.meta.title == "Your first video")
        // A broken pack gives the script too.
        do {
            let saved = Demo.pack
            defer { cleanup(saved) }
            let lib = try fresh()
            let bad = root.appending(path: "bad.zip")
            try Data("not a zip".utf8).write(to: bad)
            Demo.pack = bad
            let url = try #require(await Demo.shared.add(lib))
            #expect(FileManager.default.fileExists(atPath: url.appending(path: "script.md").path))
        }
    }

    @Test func onlyAnEmptyLibraryGetsItOnItsOwn() async throws {
        let saved = Demo.pack
        defer { cleanup(saved) }
        let lib = try fresh()
        Demo.pack = root.appending(path: "missing.zip")
        _ = lib.createProject("Videos")
        Demo.shared.addIfNew(lib)
        #expect(UserDefaults.standard.bool(forKey: Demo.doneKey), "someone with projects is done for good")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Start here").path))
    }

    @Test func installKeepsAFolderThatIsThere() throws {
        let saved = Demo.pack
        defer { cleanup(saved) }
        _ = try fresh()
        let project = root.appending(path: "Start here")
        let z = try zip()
        let a = try Demo.install(zip: z, into: project)
        let b = try Demo.install(zip: z, into: project)
        #expect(a.lastPathComponent == Demo.folder && b.lastPathComponent == "\(Demo.folder)-2")
    }
}
