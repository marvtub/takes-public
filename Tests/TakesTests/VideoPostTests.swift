import Foundation
import Testing
@testable import Takes

// 2026-10-03: YouTube (posts/youtube.md, title + description) and one vertical post for TikTok,
// Reels and Shorts (posts/vertical.md, front matter on + title). Same files as the MCP server.

@MainActor
struct VideoPostTests {
    let session: URL

    init() throws {
        session = FileManager.default.temporaryDirectory.appending(path: "takes-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session.appending(path: "edits"), withIntermediateDirectories: true)
    }

    @Test func filesAndPlatformOfPath() {
        #expect(PostPlatform.youtube.rel == "posts/youtube.md")
        #expect(PostFile.rel(of: "short", .vertical) == "posts/vertical/variants/short.md")
        #expect(PostPlatform.of(rel: "posts/vertical.md") == .vertical)
        #expect(PostPlatform.of(rel: "posts/youtube/variants/a.md") == .youtube)
        #expect(PostPlatform.of(rel: "posts/variants/a.md") == .linkedin)
    }

    @Test func placesRoundTrip() {
        var c = PostFile.Content(text: "Hook\n")
        #expect(c.places == VerticalPlace.allCases)
        c.places = [.shorts, .tiktok]
        #expect(c.meta["on"] == "tiktok, shorts")
        #expect(c.places == [.tiktok, .shorts])
        c.places = []
        #expect(c.places.isEmpty)
        c.places = VerticalPlace.allCases
        #expect(c.meta["on"] == nil)
    }

    @Test func titleWritesFirstInTheFrontMatter() {
        var c = PostFile.Content(text: "Description\n", media: "edits/a.mp4")
        c.title = "Why I record"
        PostFile.write(c, to: session, .youtube)
        let raw = try? String(contentsOf: PostFile.url(session, .youtube), encoding: .utf8)
        #expect(raw?.hasPrefix("---\ntitle: Why I record\nmedia: edits/a.mp4\n") == true)
        #expect(PostFile.read(session, .youtube)?.title == "Why I record")
    }

    @Test func videoPostsDoNotBorrowTheLinkedInMedia() throws {
        for f in ["wide-v1.mp4", "tall-v1.mp4"] {
            try Data().write(to: session.appending(path: "edits/\(f)"))
        }
        PostFile.write(PostFile.Content(text: "LinkedIn", media: "edits/wide-v1.mp4"), to: session)
        #expect(PostFile.media(nil, in: session, .x)?.lastPathComponent == "wide-v1.mp4")
        let v = PostFile.Content(text: "Caption", media: "edits/tall-v1.mp4")
        #expect(PostFile.media(v, in: session, .vertical)?.lastPathComponent == "tall-v1.mp4")
    }

    @Test func hashtagsCount() {
        #expect(YouTube.hashtags("Hook #ai #video and @acme https://x.com/#a") == 2)
    }
}
