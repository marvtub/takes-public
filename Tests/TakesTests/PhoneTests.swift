import Foundation
import ImageIO
import Testing
@testable import Takes

struct PhoneHTTPTests {
    @Test func parsesTheHead() throws {
        let r = try #require(PhoneRequest.parse(head: "GET /api/session?id=P%2F2026-a&x= HTTP/1.1\r\nHost: m\r\nTailscale-User-Login: me@x.com"))
        #expect(r.method == "GET")
        #expect(r.path == "/api/session")
        #expect(r.query["id"] == "P/2026-a")
        #expect(r.header("tailscale-user-login") == "me@x.com")
        #expect(PhoneRequest.parse(head: "nonsense") == nil)
    }

    @Test func decodesChunkedBodiesSplitAnywhere() {
        let wire = Data("4\r\nWiki\r\n6\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n".utf8)
        for cut in [1, 3, 7, 50] {
            var d = ChunkedDecoder()
            var out = Data()
            var i = 0
            while i < wire.count {
                out.append(d.feed(wire.subdata(in: i..<min(i + cut, wire.count))))
                i += cut
            }
            #expect(String(decoding: out, as: UTF8.self) == "Wikipedia in \r\n\r\nchunks.")
            #expect(d.done)
        }
    }

    @Test func readsRanges() {
        #expect(PhoneConnection.range(nil, size: 100) == .some(nil))
        #expect(PhoneConnection.range("bytes=0-1", size: 100) == .some(0...1))
        #expect(PhoneConnection.range("bytes=90-", size: 100) == .some(90...99))
        #expect(PhoneConnection.range("bytes=-10", size: 100) == .some(90...99))
        #expect(PhoneConnection.range("bytes=50-500", size: 100) == .some(50...99))
        #expect(PhoneConnection.range("bytes=100-", size: 100) == nil)  // 416
    }

    @Test func cleansFileNames() {
        #expect(PhoneServer.clean("../../etc/passwd") == "passwd")
        #expect(PhoneServer.clean(".hidden.mov") == "hidden.mov")
        #expect(PhoneServer.clean("IMG 1:2.HEIC") == "IMG 1-2.HEIC")
    }

    @Test func tokensHashTheSameWay() {
        let t = PhoneServer.newToken()
        #expect(t.count >= 40)
        #expect(!t.contains("/") && !t.contains("+"))
        #expect(PhoneServer.hash(t) == PhoneServer.hash(t))
        #expect(PhoneServer.hash(t) != PhoneServer.hash(t + "x"))
    }

    /// A real listener on a free port: JSON, a ranged file, an upload with Content-Length and one
    /// with chunks, and an event stream.
    @Test func servesOverTheWire() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appending(path: "a.bin")
        try Data((0..<200).map { UInt8($0) }).write(to: media)
        let h = Echo(dir: dir, media: media)
        let l = PhoneListener(handler: h)
        try l.start(port: 0)
        defer { l.stop() }
        var port: UInt16 = 0
        for _ in 0..<100 where port == 0 { try await Task.sleep(for: .milliseconds(20)); port = l.port ?? 0 }
        let base = "http://127.0.0.1:\(port)"

        let (json, r1) = try await URLSession.shared.data(from: URL(string: base + "/hello?x=1")!)
        #expect((r1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: json, as: UTF8.self).contains("\"path\":\"/hello\""))

        var ranged = URLRequest(url: URL(string: base + "/file")!)
        ranged.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (part, r2) = try await URLSession.shared.data(for: ranged)
        #expect((r2 as? HTTPURLResponse)?.statusCode == 206)
        #expect(part == Data((10..<20).map { UInt8($0) }))

        var put = URLRequest(url: URL(string: base + "/up")!)
        put.httpMethod = "PUT"
        let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let (_, r3) = try await URLSession.shared.upload(for: put, from: big)
        #expect((r3 as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: h.lastUpload!) == big)

        // No length known: URLSession sends chunks.
        var stream = URLRequest(url: URL(string: base + "/up")!)
        stream.httpMethod = "PUT"
        stream.httpBodyStream = InputStream(data: big)
        let (_, r4) = try await URLSession.shared.data(for: stream)
        #expect((r4 as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: h.lastUpload!) == big)

        let (bytes, r5) = try await URLSession.shared.bytes(from: URL(string: base + "/events")!)
        #expect((r5 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        Task { try? await Task.sleep(for: .milliseconds(100)); h.say("{\"n\":1}") }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            #expect(line == "data: {\"n\":1}")
            break
        }
    }
}

private final class Echo: PhoneHandler, @unchecked Sendable {
    let dir: URL
    let media: URL
    var lastUpload: URL?
    var streams: [PhoneConnection] = []

    init(dir: URL, media: URL) { self.dir = dir; self.media = media }

    func uploadTarget(_ req: PhoneRequest) -> Result<URL, PhoneError> {
        .success(dir.appending(path: "\(UUID().uuidString).part"))
    }

    func respond(_ req: PhoneRequest) async -> PhoneResponse {
        switch req.path {
        case "/file": return .file(media, type: "application/octet-stream")
        case "/up": lastUpload = req.file; return .encode(["ok": true])
        case "/events": return .events
        default: return .encode(["path": req.path, "x": req.query["x"] ?? ""])
        }
    }

    func eventsOpened(_ c: PhoneConnection) { streams.append(c) }
    func eventsClosed(_ c: PhoneConnection) {}
    func say(_ s: String) { streams.forEach { $0.event(Data(s.utf8)) } }
}

struct PhoneCommentTests {
    @Test func onlyScriptsAndPostsTakeComments() {
        #expect(PhoneServer.commentable("script.md"))
        #expect(PhoneServer.commentable("variants/short.md"))
        #expect(PhoneServer.commentable("posts/linkedin.md"))
        #expect(PhoneServer.commentable("posts/x.md"))
        #expect(PhoneServer.commentable("posts/variants/short.md"))
        #expect(!PhoneServer.commentable("edits/a.mp4"))
        #expect(!PhoneServer.commentable("variants/../../x.md"))
    }

    @Test func addsAndKeepsComments() throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "phone-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s) }
        let a = CommentStore.addText(s, file: "script.md", quote: "the hook", text: "Shorter")
        let b = CommentStore.addText(s, file: "posts/linkedin.md", quote: nil, text: "Less salesy")
        #expect(a.id == "c1" && b.id == "c2")
        CommentStore.change(s) { $0.comments[0].status = "resolved" }
        let all = CommentStore.read(s).comments
        #expect(all.count == 2)
        #expect(all[0].quote == "the hook" && !all[0].open)
        #expect(all[1].quote == nil && all[1].open && all[1].by == "user")
    }

    /// A comment from the phone on an area of a picture: kept with its area, and a frame PNG for Claude.
    @Test func addsMediaCommentsWithAFrame() async throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "phone-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s.appending(path: "stills"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s) }
        let ctx = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let png = s.appending(path: "stills/a.png")
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))

        #expect(PhoneServer.commentableMedia("stills/a.png", in: s))
        #expect(!PhoneServer.commentableMedia("stills/missing.png", in: s))
        #expect(!PhoneServer.commentableMedia("../a.png", in: s))
        #expect(!PhoneServer.commentableMedia("script.md", in: s))

        let c = CommentStore.addMedia(s, file: "stills/a.png", start: nil, end: nil,
                                      rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), text: "Logo too small")
        #expect(c.id == "c1" && c.rect == [0.1, 0.2, 0.3, 0.4] && c.frame == "comments/c1.png")
        let frame = s.appending(path: "comments/c1.png")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: frame.path) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: frame.path))
    }

    @Test func newSessionsGoInASafeProject() {
        #expect(PhoneServer.projectName(nil) == "Inbox")
        #expect(PhoneServer.projectName("  ") == "Inbox")
        #expect(PhoneServer.projectName("Weekly Challenge") == "Weekly Challenge")
        #expect(PhoneServer.projectName("../x") == "-x")
        #expect(PhoneServer.projectName("_library") == "library")
        #expect(PhoneServer.firstAsk("AI for dentists", titled: false).hasSuffix("give the session a short title.)"))
        #expect(PhoneServer.firstAsk("AI for dentists", titled: true).hasSuffix("script.md.)"))
    }

    @Test func boardChatsHaveTheirOwnIDs() {
        #expect(PhoneServer.lane("board:comments") == "find")
        #expect(PhoneServer.lane("board:comments-post") == "post")
        #expect(PhoneServer.lane("Inbox/2026-10-02-x") == nil)
    }

    @MainActor @Test func postVariantsAndHooksFromThePhone() throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "phone-post-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s.appending(path: "posts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s) }
        PostFile.write(PostFile.Content(text: "Old hook\n\nThe body."), to: s)
        PostFile.writeVariant(Variant(slug: "short", name: "Short", author: "claude", note: "", created: "2026-10-02", text: "Short one\n\nLess."), in: s)
        let hooks = HooksFile(hooks: [Hook(id: "h1", text: "New hook", note: nil)])
        try JSONEncoder().encode(hooks).write(to: PostFile.hooksURL(s))

        #expect(PhoneServer.postDraft(["action": "hook", "hook": "h1", "draft": "main"], in: s) == nil)
        #expect(PostFile.read(s)?.text.hasPrefix("New hook") == true)
        #expect(HookStore.read(file: PostFile.hooksURL(s)).chosen == "h1")

        #expect(PhoneServer.postDraft(["action": "save", "slug": "short", "text": "Edited", "base": "Not it"], in: s) != nil)
        #expect(PhoneServer.postDraft(["action": "save", "slug": "short", "text": "Edited", "base": "Short one\n\nLess."], in: s) == nil)

        #expect(PhoneServer.postDraft(["action": "promote", "slug": "short"], in: s) == nil)
        #expect(PostFile.read(s)?.text == "Edited")
        #expect(PostFile.variants(s).isEmpty)
        #expect(PostFile.versions(s).contains { $0.text().hasPrefix("New hook") })
        #expect(PhoneServer.postDraft(["action": "promote", "slug": "gone"], in: s) == "No such variant")
    }

    @MainActor @Test func everyPlatformsPostGoesToThePhone() throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "phone-posts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s.appending(path: "posts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s) }
        #expect(PhoneServer.platformPosts(s) == nil)
        PostFile.write(PostFile.Content(text: "On LinkedIn"), to: s)
        var yt = PostFile.Content(text: "The description")
        yt.title = "The title"
        PostFile.write(yt, to: s, .youtube)
        let posts = try #require(PhoneServer.platformPosts(s))
        #expect(posts.map(\.platform) == ["linkedin", "youtube"])
        #expect(posts[1].title == "The title" && posts[1].limit == 5000 && posts[1].status == "draft")
    }
}

struct PhoneOriginTests {
    @Test func tellsClaudeTheScreenAndThatItWasDictated() {
        let note = PhoneServer.origin(["text": "make this shorter", "from": "Board", "voice": "1"])
        #expect(note.contains("iPhone"))
        #expect(note.contains("looking at the storyboard"))
        #expect(note.contains("dictated"))
        let typed = PhoneServer.origin(["text": "hi", "from": "Script"])
        #expect(typed.contains("Script tab"))
        #expect(!typed.contains("dictated"))
    }

    @Test func anOlderPhoneStillCountsAsThePhone() {
        let note = PhoneServer.origin(["text": "hi"])
        #expect(note.contains("iPhone"))
        #expect(!note.contains("while"))
    }
}
