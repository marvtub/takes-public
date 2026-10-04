import AVFoundation
import Foundation
import Testing
@testable import Takes

// 2026-09-28: music from the Epidemic Sound folder, in the Takes library, played under a video.

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

    @Test func songStartLinesUpWithTheVideo() {
        #expect(MusicBed.position(videoTime: 0, start: 12) == 12)
        #expect(MusicBed.position(videoTime: 3.5, start: 12) == 15.5)
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

    @Test func mcpSongPickReads() throws {
        let json = #"{"createdAt":"2026-09-01T10:00:00Z","named":true,"takes":[],"title":"T","music":{"file":"Music/1_A.mp3","start":12.5,"volume":0.35}}"#
        let m = try Store.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(m.music == SongPick(file: "Music/1_A.mp3", start: 12.5, volume: 0.35))
    }

    /// The song follows the video: play, pause, and a seek move it. Both silent.
    @MainActor @Test(.enabled(if: ffmpeg != nil)) func bedFollowsTheVideo() async throws {
        let dir = try Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appending(path: "v.mp4"), song = dir.appending(path: "s.mp3")
        try Self.make(["-f", "lavfi", "-i", "color=c=black:s=64x64:d=20", "-f", "lavfi", "-i", "anullsrc", "-t", "20", video.path])
        try Self.make(["-f", "lavfi", "-i", "sine=d=60", song.path])
        let player = AVPlayer(url: video)
        player.isMuted = true
        let bed = MusicBed()
        bed.load(song, start: 10, volume: 0)
        bed.attach(player)
        #expect(bed.withVideo && !bed.playing)

        player.play()
        for _ in 0..<30 where !bed.playing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(bed.playing)

        player.pause()
        for _ in 0..<30 where bed.playing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!bed.playing)

        await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        for _ in 0..<30 where !bed.playing { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(bed.playing)
        #expect(abs(bed.songTime - (10 + player.currentTime().seconds)) < 0.3)

        bed.on = false
        #expect(!bed.playing)
        player.pause()
        bed.attach(nil)
        #expect(!bed.withVideo)
    }

    @Test func effectsAreNotSongs() {
        let u = URL(fileURLWithPath: "/x")
        #expect(!SoundsPane.isEffect(Sound(url: u, group: "Music", rel: "Music/a.mp3")))
        #expect(SoundsPane.isEffect(Sound(url: u, group: "SFX", rel: "SFX/whoosh.mp3")))
    }

    @Test func mcpEffectCuesRead() throws {
        let json = #"{"createdAt":"2026-09-01T10:00:00Z","named":true,"takes":[],"title":"T","sfx":[{"file":"SFX/1_W.mp3","video":"edits/a-v1.mp4","at":12.4,"volume":0.8}]}"#
        let m = try Store.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(m.sfx == [EffectCue(file: "SFX/1_W.mp3", video: "edits/a-v1.mp4", at: 12.4, volume: 0.8)])
        let s = URL(fileURLWithPath: "/L/P/s")
        #expect(EffectCue.rel(URL(fileURLWithPath: "/L/P/s/edits/a-v1.mp4"), in: s) == "edits/a-v1.mp4")
        #expect(EffectCue.rel(URL(fileURLWithPath: "/x/b.mp4"), in: s) == "/x/b.mp4")
    }

    /// An effect placed at 0:01 plays when the video passes 0:01, and only on its own video.
    @MainActor @Test(.enabled(if: ffmpeg != nil)) func effectPlaysAtItsSecond() async throws {
        let d = try Self.temp()
        defer { try? FileManager.default.removeItem(at: d) }
        let video = d.appending(path: "take-01-camera.mov")
        try Self.make(["-f", "lavfi", "-i", "color=c=black:s=64x64:d=3", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
                       "-t", "3", "-shortest", video.path])
        try FileManager.default.createDirectory(at: d.appending(path: "SFX"), withIntermediateDirectories: true)
        try Self.make(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "0.5", d.appending(path: "SFX/1_W.wav").path])
        let track = EffectTrack()
        track.dir = d
        track.session = d
        track.cues = [EffectCue(file: "SFX/1_W.wav", video: "take-01-camera.mov", at: 1.0, volume: 0),
                      EffectCue(file: "SFX/1_W.wav", video: "other.mov", at: 0.5, volume: 0)]
        track.video = video
        #expect(track.here.count == 1)
        let player = AVPlayer(url: video)
        player.isMuted = true
        track.attach(player)
        player.play()
        // Wait for the playhead to pass 0:01. A fixed sleep failed when the whole suite ran at once.
        for _ in 0..<50 where track.fired == 0 { try await Task.sleep(for: .milliseconds(100)) }
        player.pause()
        #expect(track.fired == 1)
        track.attach(nil)
    }
}
