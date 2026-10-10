import Foundation
import Testing
@testable import Takes

/// The phone's Board and Assets routes (PhoneBoard.swift, 2026-10-09), each checked on disk.
@MainActor
struct PhoneBoardTests {
    let root: URL
    let server: PhoneServer
    let s: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "phone-board-\(UUID().uuidString)")
        s = root.appending(path: "Inbox/2026-10-09-hook").standardizedFileURL
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let d = SessionDoc(url: s)
        var meta = SessionMeta(title: "Hook", createdAt: Date(), named: true)
        try Data("take".utf8).write(to: s.appending(path: "take-01-camera.mov"))
        meta.takes.append(Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: Date(), duration: 3, keeper: false, shot: "s1"))
        d.meta = meta
        d.save()
        server = PhoneServer(root: root, demo: true)
    }

    var id: String { "Inbox/2026-10-09-hook" }

    func call(_ path: String, _ body: [String: String] = [:], method: String = "POST", query: [String: String]? = nil) async -> (Int, Data?) {
        var r = PhoneRequest(method: method, path: path, query: query ?? ["id": id])
        r.body = (try? JSONEncoder().encode(body)) ?? Data()
        switch await server.respond(r) {
        case .json(let data, let status): return (status, data)
        case .status(let n, _): return (n, nil)
        default: return (0, nil)
        }
    }

    @Test func picksAVariantStarsAndUnlinksATake() async throws {
        let dir = Storyboard.folder(s)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"shots": [{"id": "s1", "say": "Hi", "variants": ["generated/a.png", "generated/b.png"], "video": "generated/a.png"}]}"#.utf8)
            .write(to: Storyboard.file(s))
        var (status, _) = await call("/api/shot", ["action": "pick", "shot": "s1", "path": s.appending(path: "generated/b.png").path])
        #expect(status == 200)
        #expect(Storyboard.read(s)?.shots.first?.video == "generated/b.png")
        (status, _) = await call("/api/shot", ["action": "pick", "shot": "s1", "path": "generated/c.png"])
        #expect(status == 404)
        (status, _) = await call("/api/shot", ["action": "star", "take": "1"])
        #expect(status == 200)
        #expect(Store.readMeta(s)?.takes.first?.keeper == true)
        (status, _) = await call("/api/shot", ["action": "unlink", "take": "1"])
        #expect(status == 200)
        #expect(Store.readMeta(s)?.takes.first?.shot == nil)
    }

    @Test func addsAndRemovesABrollClip() async throws {
        let folder = BrollLib.dir(root: root).appending(path: "1 Desk work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appending(path: "2023-11 Typing (V).mov")
        try Data("clip".utf8).write(to: clip)
        var (status, data) = await call("/api/broll", method: "GET")
        #expect(status == 200)
        var lib = try JSONDecoder().decode([PhoneBrollFolder].self, from: try #require(data))
        #expect(lib.first?.name == "Desk work" && lib.first?.clips.first?.title == "Typing" && lib.first?.clips.first?.added == false)
        (status, _) = await call("/api/broll", ["action": "add", "path": clip.standardizedFileURL.path])
        #expect(status == 200)
        #expect(FileManager.default.fileExists(atPath: s.appending(path: "broll/2023-11 Typing (V).mov").path))
        (_, data) = await call("/api/broll", method: "GET")
        lib = try JSONDecoder().decode([PhoneBrollFolder].self, from: try #require(data))
        #expect(lib.first?.clips.first?.added == true)
        (status, _) = await call("/api/broll", ["action": "remove", "path": clip.standardizedFileURL.path])
        #expect(status == 200)
        #expect(!FileManager.default.fileExists(atPath: s.appending(path: "broll/2023-11 Typing (V).mov").path))
        (status, _) = await call("/api/broll", ["action": "add", "path": "/etc/hosts"])
        #expect(status == 404)
    }

    /// The phone lists the sounds and Use asks the chat; the old song and effect picks are gone
    /// (2026-10-09). The test server has no chat, so a good Use is not sent here.
    @Test func listsSoundsAndRefusesTheOldPicks() async throws {
        let audio = SoundLib.dir(root: root)
        try FileManager.default.createDirectory(at: audio.appending(path: "Music"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audio.appending(path: "SFX"), withIntermediateDirectories: true)
        try Data("mp3".utf8).write(to: audio.appending(path: "Music/26428_Chasing.mp3"))
        try Data("mp3".utf8).write(to: audio.appending(path: "SFX/1_Whoosh.mp3"))
        var (status, data) = await call("/api/sounds", method: "GET")
        #expect(status == 200)
        #expect(try JSONDecoder().decode(PhoneSounds.self, from: try #require(data)).sounds.map(\.title) == ["Chasing", "Whoosh"])
        (status, _) = await call("/api/sounds", ["action": "music", "file": "Music/26428_Chasing.mp3"])
        #expect(status == 400)
        (status, _) = await call("/api/sounds", ["action": "use", "file": "../secret.mp3"])
        #expect(status == 404)
        (status, _) = await call("/api/sounds", ["action": "use", "file": "SFX/1_Whoosh.mp3", "video": "edits/none.mp4", "at": "2"])
        #expect(status == 404)
        #expect(Store.readMeta(s)?.title == "Hook")
    }

    /// New conversation, Past conversations and resume (2026-10-09), as the Mac's chat menu.
    @Test func startsANewChatAndResumesTheOldOne() async throws {
        var log = ChatLog(conversation: "c1")
        log.messages = [ChatMessage(role: .user, text: "Cut the intro\nplease"), ChatMessage(role: .claude, text: "Done.")]
        log.updated = Date()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(log).write(to: ClaudeChat.file(s))
        var (status, _) = await call("/api/chat/new")
        #expect(status == 200)
        let (_, data) = await call("/api/chat/history", method: "GET")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let past = try dec.decode([PhonePastChat].self, from: try #require(data))
        #expect(past.map(\.title) == ["Cut the intro"])
        #expect(past.first?.count == 1)
        (status, _) = await call("/api/chat/history", ["action": "resume", "file": try #require(past.first?.file)])
        #expect(status == 200)
        #expect(ClaudeChat(session: s).messages.first?.text == "Cut the intro\nplease")
        (status, _) = await call("/api/chat/history", ["action": "forget", "file": "nope.json"])
        #expect(status == 404)
    }

    /// ⌘K from the phone (2026-10-09): a session by its name, then a take by its file name, under the Takes chip.
    @Test func searchesByNameAndKind() async throws {
        var (status, data) = await call("/api/search", method: "GET", query: ["q": "hook"])
        #expect(status == 200)
        var r = try JSONDecoder().decode(PhoneSearch.self, from: try #require(data))
        #expect(r.hits.first?.kind == "session" && r.hits.first?.title == "Hook" && r.hits.first?.session == id)
        (_, data) = await call("/api/search", method: "GET", query: ["q": "take-01", "filter": "takes"])
        r = try JSONDecoder().decode(PhoneSearch.self, from: try #require(data))
        #expect(r.hits.map(\.kind) == ["video"])
        #expect(r.hits.first?.session == id)
        (_, data) = await call("/api/search", method: "GET", query: ["q": "take-01", "filter": "stills"])
        r = try JSONDecoder().decode(PhoneSearch.self, from: try #require(data))
        #expect(r.hits.isEmpty)
    }
}
