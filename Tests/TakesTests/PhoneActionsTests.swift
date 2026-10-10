import Foundation
import Testing
@testable import Takes

/// The phone's everyday actions (PhoneActions.swift) on a library of their own: each one through
/// the route the phone calls, checked on disk.
@MainActor
struct PhoneActionsTests {
    let root: URL
    let server: PhoneServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "phone-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Inbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Later"), withIntermediateDirectories: true)
        server = PhoneServer(root: root, demo: true)
    }

    /// A session with two takes (the first starred) and a script.
    func session(_ name: String = "2026-10-09-hook", project: String = "Inbox") throws -> URL {
        let s = root.appending(path: "\(project)/\(name)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let d = SessionDoc(url: s)
        var meta = SessionMeta(title: "Hook", createdAt: Date(), named: true)
        for n in 1...2 {
            let file = "take-0\(n)-camera.mov"
            try Data("take".utf8).write(to: s.appending(path: file))
            meta.takes.append(Take(number: n, kind: .camera, file: file, startedAt: Date(), duration: 3, keeper: n == 1))
        }
        d.meta = meta
        d.save()
        try "The main script.".write(to: s.appending(path: "script.md"), atomically: true, encoding: .utf8)
        return s.standardizedFileURL
    }

    func call(_ path: String, _ query: [String: String] = [:], _ body: [String: String] = [:], method: String = "POST") async -> (Int, Any?) {
        var r = PhoneRequest(method: method, path: path, query: query)
        r.body = (try? JSONEncoder().encode(body)) ?? Data()
        switch await server.respond(r) {
        case .json(let data, let status): return (status, try? JSONSerialization.jsonObject(with: data))
        case .status(let n, _): return (n, nil)
        default: return (0, nil)
        }
    }

    func id(_ s: URL) -> String { String(s.path.dropFirst(root.standardizedFileURL.path.count + 1)) }

    @Test func trashesUnstarredTakesThenATakeThenTheSession() async throws {
        let s = try session()
        var (status, _) = await call("/api/trash", ["id": id(s)], ["what": "unstarred"])
        #expect(status == 200)
        #expect(Store.readMeta(s)?.takes.map(\.number) == [1])
        #expect(!FileManager.default.fileExists(atPath: s.appending(path: "take-02-camera.mov").path))
        (status, _) = await call("/api/trash", ["id": id(s)], ["what": "take", "take": "1"])
        #expect(status == 200)
        #expect(Store.readMeta(s)?.takes.isEmpty == true)
        (status, _) = await call("/api/trash", ["id": id(s)], ["what": "take", "take": "9"])
        #expect(status == 404)
        (status, _) = await call("/api/trash", ["id": id(s)], ["what": "session"])
        #expect(status == 200)
        #expect(!FileManager.default.fileExists(atPath: s.path))
    }

    @Test func trashesAFileButNotTheSessionsOwnFiles() async throws {
        let s = try session()
        try FileManager.default.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        let edit = s.appending(path: "edits/cut-v1.mp4")
        try Data("x".utf8).write(to: edit)
        var (status, _) = await call("/api/trash", ["id": id(s)], ["what": "file", "path": s.appending(path: "session.json").path])
        #expect(status == 400)
        (status, _) = await call("/api/trash", ["id": id(s)], ["what": "file", "path": s.appending(path: "take-01-camera.mov").path])
        #expect(status == 400)
        (status, _) = await call("/api/trash", ["id": id(s)], ["what": "file", "path": edit.path])
        #expect(status == 200)
        #expect(!FileManager.default.fileExists(atPath: edit.path))
    }

    @Test func renamesATakeTheSessionAndAProject() async throws {
        let s = try session()
        var (status, answer) = await call("/api/rename", ["id": id(s)], ["what": "take", "take": "1", "name": "Best one"])
        #expect(status == 200)
        #expect(Store.readMeta(s)?.takes.first { $0.number == 1 }?.file == "take-01-best-one-camera.mov")
        (status, answer) = await call("/api/rename", ["id": id(s)], ["what": "session", "name": "A new title"])
        #expect(status == 200)
        let newID = try #require((answer as? [String: Any])?["id"] as? String)
        #expect(newID.hasSuffix("-a-new-title"))
        #expect(Store.readMeta(root.appending(path: newID))?.title == "A new title")
        (status, answer) = await call("/api/rename", [:], ["what": "project", "project": "Later", "name": "Someday"])
        #expect(status == 200)
        #expect((answer as? [String: String])?["project"] == "Someday")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Someday").path))
        (status, _) = await call("/api/rename", [:], ["what": "project", "project": "Gone", "name": "X"])
        #expect(status == 404)
    }

    @Test func movesASessionToAnotherProject() async throws {
        let s = try session()
        _ = try session(project: "Later")  // the same folder name is taken there
        let (status, answer) = await call("/api/move", ["id": id(s)], ["project": "Later"])
        #expect(status == 200)
        let newID = try #require((answer as? [String: Any])?["id"] as? String)
        #expect(newID == "Later/2026-10-09-hook-2")
        #expect(!FileManager.default.fileExists(atPath: s.path))
        #expect(await call("/api/move", ["id": newID], ["project": "Nowhere"]).0 == 404)
    }

    @Test func trashesAProject() async throws {
        _ = try session(project: "Later")
        #expect(await call("/api/trash", [:], ["what": "project", "project": "Later"]).0 == 200)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Later").path))
        #expect(await call("/api/trash", [:], ["what": "project", "project": "../x"]).0 == 404)
    }

    @Test func scriptVariantsAndHistory() async throws {
        let s = try session()
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "new"]).0 == 200)
        var d = SessionDoc(url: s)
        let slug = try #require(d.variants.first?.slug)
        #expect(d.variants.first?.text == "The main script.")
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "save", "slug": slug, "text": "A shorter one.", "base": "Not it"]).0 == 409)
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "save", "slug": slug, "text": "A shorter one.", "base": "The main script."]).0 == 200)
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "rename", "slug": slug, "name": "Short"]).0 == 200)
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "favorite", "slug": slug]).0 == 200)
        d = SessionDoc(url: s)
        #expect(d.variants.first?.name == "Short" && d.meta.favorite == slug)
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "promote", "slug": slug]).0 == 200)
        d = SessionDoc(url: s)
        #expect(d.script == "A shorter one." && d.variants.isEmpty && d.meta.favorite == "main")
        let (status, list) = await call("/api/script/history", ["id": id(s)], method: "GET")
        #expect(status == 200)
        let versions = try #require(list as? [[String: Any]])
        let old = try #require(versions.first { ($0["text"] as? String) == "The main script." && ($0["draft"] as? String) == "main" })
        #expect(await call("/api/script/draft", ["id": id(s)], ["action": "restore", "path": old["path"] as! String]).0 == 200)
        #expect(SessionDoc(url: s).script == "The main script.")
    }

    @Test func postHistoryAndVariantsOnAnyPlatform() async throws {
        let s = try session()
        PostFile.write(PostFile.Content(text: "First X post"), to: s, .x)
        PostFile.snapshot(s, draft: "main", text: "First X post", note: "Saved", .x)
        #expect(await call("/api/post/draft", ["id": id(s), "platform": "x"], ["action": "new"]).0 == 200)
        let slug = try #require(PostFile.variants(s, .x).first?.slug)
        #expect(await call("/api/post/draft", ["id": id(s), "platform": "x"], ["action": "save", "slug": slug, "text": "Second", "base": "First X post"]).0 == 200)
        #expect(await call("/api/post/draft", ["id": id(s), "platform": "x"], ["action": "promote", "slug": slug]).0 == 200)
        #expect(PostFile.read(s, .x)?.text == "Second")
        let (_, list) = await call("/api/post/history", ["id": id(s), "platform": "x"], method: "GET")
        let versions = try #require(list as? [[String: Any]])
        let first = try #require(versions.first { ($0["text"] as? String) == "First X post" })
        #expect(await call("/api/post/draft", ["id": id(s), "platform": "x"], ["action": "restore", "path": first["path"] as! String]).0 == 200)
        #expect(PostFile.read(s, .x)?.text == "First X post")
        let posts = try #require(PhoneServer.platformPosts(s))
        #expect(posts.first { $0.platform == "x" }?.history ?? 0 >= 3)
    }

    @Test func voiceOfATakeBeforeItIsCleaned() async throws {
        let s = try session()
        let (status, v) = await call("/api/voice", ["id": id(s), "take": "1", "kind": "camera"], method: "GET")
        #expect(status == 200)
        #expect((v as? [String: Any])?["state"] as? String == "none")
        #expect(await call("/api/voice", ["id": id(s)], ["take": "1", "kind": "camera", "action": "set", "strength": "0.5"]).0 == 409)
        #expect(await call("/api/voice", ["id": id(s), "take": "7"], method: "GET").0 == 404)
    }

    /// The schedule panel's four actions (2026-10-09), for LinkedIn and X, and the plan the list shows.
    @Test func schedulesAPostThenTakesItBack() async throws {
        let s = try session()
        PostFile.write(PostFile.Content(text: "The post."), to: s, .x)
        let at = "2026-10-20T09:00:00-07:00"
        var (status, _) = await call("/api/schedule", ["id": id(s), "platform": "x"], ["action": "set", "at": at, "tz": "America/Los_Angeles"])
        #expect(status == 200)
        var c = try #require(PostFile.read(s, .x))
        #expect(c.status == .ready)
        #expect(c.at == ISO8601DateFormatter().date(from: at))
        #expect(c.tz.identifier == "America/Los_Angeles")
        #expect(PhoneServer.plan(s) == [PhonePlanned(platform: "x", status: "ready", at: c.at)])
        (status, _) = await call("/api/schedule", ["id": id(s), "platform": "x"], ["action": "clear"])
        #expect(status == 200)
        c = try #require(PostFile.read(s, .x))
        #expect(c.at == nil && c.status == .ready)
        (status, _) = await call("/api/schedule", ["id": id(s), "platform": "x"], ["action": "draft"])
        #expect(status == 200)
        #expect(PostFile.read(s, .x)?.status == .draft)
        #expect(PhoneServer.plan(s) == nil)
        (status, _) = await call("/api/schedule", ["id": id(s), "platform": "x"], ["action": "ready"])
        #expect(status == 200)
        #expect(PostFile.read(s, .x)?.status == .ready)
        // No LinkedIn post yet: nothing to schedule.
        (status, _) = await call("/api/schedule", ["id": id(s)], ["action": "ready"])
        #expect(status == 400)
    }
}
