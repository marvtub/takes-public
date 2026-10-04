import AVFoundation
import Foundation
import Testing
@testable import Takes

// 2026-09-29: clean voice. The server cleans a take into voice/<take>.clean.wav and .dry.wav; the
// player blends them live at the take's strength and loudness.

@MainActor
struct VoiceTests {
    let session: URL

    init() throws {
        session = FileManager.default.temporaryDirectory.appending(path: "takes-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    }

    @Test func volumesBlendCleanAndDry() {
        #expect(Voice.volumes(clean: false, strength: 0.7, quiet: false) == (1, 0, 0))
        let full = Voice.volumes(clean: true, strength: 1, quiet: false)
        #expect(full == (0, 1, 0))
        let mixed = Voice.volumes(clean: true, strength: 0.7, quiet: false)
        #expect(abs(mixed.clean - 0.7) < 0.001 && abs(mixed.dry - 0.3) < 0.001 && mixed.orig == 0)
        let quiet = Voice.volumes(clean: true, strength: 1, quiet: true)
        #expect(abs(20 * log10(Double(quiet.clean)) + 4) < 0.01)  // -18 LUFS: 4 dB under -14
    }

    @Test func keyIsStableWhenTheTakeIsRenamed() {
        let t = Take(number: 3, kind: .camera, file: "take-03-intro-camera.mov", startedAt: .now)
        #expect(Voice.key(t) == "take-03-camera")
        #expect(Voice.clean(session, "take-03-camera").lastPathComponent == "take-03-camera.clean.wav")
    }

    @Test func onlyTakeFilesHaveAVoice() throws {
        let t = Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .now)
        let meta = SessionMeta(title: "V", createdAt: .now, takes: [t])
        try Store.encoder.encode(meta).write(to: session.appending(path: "session.json"))
        #expect(Voice.take(for: session.appending(path: "take-01-camera.mov"), in: session)?.number == 1)
        #expect(Voice.take(for: session.appending(path: "edits/cut-v1.mp4"), in: session) == nil)
    }

    @Test func stateAndSummaryFromTheServerFile() {
        Voice.write(session, "take-01-camera", ["state": "done", "steps": ["clearvoice"], "echo_before_db": -16.9,
                                                 "echo_after_db": -27.0, "strength": 0.8, "loudness": "quiet", "on": true])
        let t = Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .now)
        let v = VoiceMix(take: t, session: session)
        v.reload()
        #expect(v.ready && v.on && v.quiet && v.strength == 0.8)
        #expect(v.summary == "echo -17 → -27 dB · noise removed · -18 LUFS")
    }

    @Test func aDeadRunnerShowsAsFailed() {
        Voice.write(session, "take-01-camera", ["state": "running", "pid": 999_999])
        #expect(Voice.read(session, "take-01-camera")?["state"] as? String == "failed")
    }

    /// The player plays the take with three voices and the settings set their volumes.
    @Test func playerBlendsTheVoicesLive() async throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }
        guard let ffmpeg else { return }
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: ffmpeg)
            p.arguments = ["-v", "error", "-y"] + args
            try p.run()
            p.waitUntilExit()
        }
        let take = session.appending(path: "take-01-camera.mov")
        try run(["-f", "lavfi", "-i", "sine=f=220:d=2", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=2",
                 "-shortest", "-c:v", "h264", "-c:a", "aac", take.path])
        try FileManager.default.createDirectory(at: Voice.dir(session), withIntermediateDirectories: true)
        for f in [Voice.clean(session, "take-01-camera"), Voice.dry(session, "take-01-camera")] {
            try run(["-f", "lavfi", "-i", "sine=f=330:d=2", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", f.path])
        }
        Voice.write(session, "take-01-camera", ["state": "done", "steps": ["clearvoice"], "strength": 0.6, "on": true])
        let t = Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .now)
        let clock = PlayerClock(url: take)
        let voice = VoiceMix(take: t, session: session)
        voice.attach(clock)
        for _ in 0..<100 where !(clock.player.currentItem?.asset is AVComposition) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let item = try #require(clock.player.currentItem)
        #expect(item.asset is AVComposition)
        func volumes() -> [Float] {
            (item.audioMix?.inputParameters ?? []).map {
                var v: Float = -1, e: Float = -1
                var r = CMTimeRange()
                _ = $0.getVolumeRamp(for: .zero, startVolume: &v, endVolume: &e, timeRange: &r)
                return (v * 100).rounded() / 100
            }
        }
        #expect(volumes() == [0, 0.6, 0.4])
        voice.comparing = true
        #expect(volumes() == [1, 0, 0])
        voice.comparing = false
        voice.on = false
        voice.hear()
        #expect(volumes() == [1, 0, 0])
        clock.stop()
    }
}
