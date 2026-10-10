import AVFoundation
import Foundation
import Testing
@testable import Takes

// 2026-09-28: music from the Epidemic Sound folder, in the Takes library. Since 2026-10-09 the app
// never plays it over a video: Use asks the chat to mix it into the file.

struct SoundsTests {
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }

    static func make(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg!)
        p.arguments = ["-v", "error", "-y"] + args
        try p.run()
        p.waitUntilExit()
    }

    static func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "takes-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func titlesDropTheCatalogNumber() {
        #expect(Sound.title("26428_Chasing the Truth.mp3") == "Chasing the Truth")
        #expect(Sound.title("150692_Cope (Instrumental Version).mp3") == "Cope (Instrumental Version)")
        #expect(Sound.title("my song.mp3") == "my song")
    }

    @Test func syncCopiesNewAudioOnlyAndKeepsFolders() throws {
        let src = try Self.temp(), lib = try Self.temp()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: lib) }
        for f in ["Music/1_A.mp3", "SFX/2_Whoosh.wav", "Music/readme.txt", "Music/.hidden.mp3"] {
            let u = src.appending(path: f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        #expect(SoundLib.sync(from: src, to: lib) == 2)
        #expect(SoundLib.sync(from: src, to: lib) == 0)
        #expect(FileManager.default.fileExists(atPath: src.appending(path: "Music/1_A.mp3").path))  // originals stay
        let found = SoundLib.scan(lib)
        #expect(found.map(\.rel) == ["Music/1_A.mp3", "SFX/2_Whoosh.wav"])
        #expect(found.map(\.group) == ["Music", "SFX"])
    }

    @Test func effectsAreNotSongs() {
        let u = URL(fileURLWithPath: "/x")
        #expect(!SoundsPane.isEffect(Sound(url: u, group: "Music", rel: "Music/a.mp3")))
        #expect(SoundsPane.isEffect(Sound(url: u, group: "SFX", rel: "SFX/whoosh.mp3")))
    }

    /// A session.json from before 2026-10-09 still opens; its old song and effects are ignored.
    @Test func oldSoundPicksStillDecode() throws {
        let json = #"{"createdAt":"2026-09-01T10:00:00Z","named":true,"takes":[],"title":"T","music":{"file":"Music/1_A.mp3","start":12.5,"volume":0.35},"sfx":[{"file":"SFX/1_W.mp3","video":"edits/a-v1.mp4","at":12.4,"volume":0.8}]}"#
        let m = try Store.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(m.title == "T")
    }

    /// Use asks the chat for a new version with the sound in it: the file, and for an effect the
    /// video and the second.
    @MainActor @Test func useAsksTheChat() {
        let session = URL(fileURLWithPath: "/L/P/s")
        let song = Sound(url: URL(fileURLWithPath: "/L/_library/audio/Music/26428_Chasing.mp3"), group: "Music", rel: "Music/26428_Chasing.mp3")
        let fx = Sound(url: URL(fileURLWithPath: "/L/_library/audio/SFX/1_Whoosh.mp3"), group: "SFX", rel: "SFX/1_Whoosh.mp3")
        let a = SoundsPane.ask(song, video: nil, session: session)
        #expect(a.contains("“Chasing”") && a.contains("_library/audio/Music/26428_Chasing.mp3") && a.contains("new version"))
        let b = SoundsPane.ask(fx, video: .init(url: session.appending(path: "edits/a-v2.mp4"), at: 12.4), session: session)
        #expect(b.contains("edits/a-v2.mp4 at 0:12") && b.contains("12.4 s") && b.contains("_library/audio/SFX/1_Whoosh.mp3"))
        #expect(SoundsPane.ask(fx, video: nil, session: session).contains("where it fits"))
    }
}
