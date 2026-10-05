import AVFoundation
import SwiftUI

// Clean voice: The user's voice-cleanup (room echo, noise, clipping, hum, then EQ, compressor and
// loudness) on a take's raw audio. mcp/takes_mcp.py does the work, for the app and for Claude alike
// (`--voice-run`, `--voice-mix`, tool clean_voice). Files, per take file, in <session>/voice/:
//
//   take-01-camera.json       state and settings (strength, loudness, on)
//   take-01-camera.clean.wav  the cleanup's plan: model + voice chain
//   take-01-camera.dry.wav    the voice chain alone (strength 0 %)
//   take-01-camera.wav        clean and dry blended at the settings: what edits use
//
// The player blends clean and dry live (an audio mix on the take), so the slider needs no new file.

enum Voice {
    /// dB from the cleanup's -14 LUFS. Same values as VOICE_LOUDNESS in the server.
    static let quietGain = -4.0

    static func key(_ t: Take) -> String { String(format: "take-%02d-%@", t.number, t.kind.rawValue) }
    static func dir(_ session: URL) -> URL { session.appending(path: "voice", directoryHint: .isDirectory) }
    static func json(_ s: URL, _ key: String) -> URL { dir(s).appending(path: key + ".json") }
    static func clean(_ s: URL, _ key: String) -> URL { dir(s).appending(path: key + ".clean.wav") }
    static func dry(_ s: URL, _ key: String) -> URL { dir(s).appending(path: key + ".dry.wav") }

    /// The take a file in the session belongs to, when it is a take's own file.
    static func take(for url: URL, in session: URL) -> Take? {
        guard Store.dir(url.deletingLastPathComponent()) == Store.dir(session) else { return nil }
        return Store.readMeta(session)?.takes.first { $0.file == url.lastPathComponent }
    }

    static func read(_ s: URL, _ key: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: json(s, key)),
              var v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // A runner that died (the Mac slept, the app was killed) never writes "failed" itself.
        if v["state"] as? String == "running", let pid = v["pid"] as? Int, kill(pid_t(pid), 0) != 0 {
            v["state"] = "failed"
            v["error"] = "The cleanup stopped before it finished."
        }
        return v
    }

    static func write(_ s: URL, _ key: String, _ v: [String: Any]) {
        try? FileManager.default.createDirectory(at: dir(s), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: json(s, key), options: .atomic)
    }

    /// Runs the server script in the background: `--voice-run session n kind` or `--voice-mix session key`.
    @discardableResult
    static func launch(_ args: [String]) -> Bool {
        guard let script = Bundle.main.url(forResource: "takes_mcp", withExtension: "py") else { return false }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/python3")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Setup.localBin):" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil
    }

    /// The volumes of the three voices in the player: original, clean, dry.
    nonisolated static func volumes(clean: Bool, strength: Double, quiet: Bool) -> (orig: Float, clean: Float, dry: Float) {
        guard clean else { return (1, 0, 0) }
        let g = quiet ? pow(10, quietGain / 20) : 1
        let s = max(0, min(1, strength))
        return (0, Float(s * g), Float((1 - s) * g))
    }

    /// "echo -17 → -27 dB · noise removed · -14 LUFS"
    nonisolated static func summary(_ v: [String: Any], quiet: Bool) -> String {
        var parts: [String] = []
        let steps = v["steps"] as? [String] ?? []
        if let a = v["echo_before_db"] as? Double, let b = v["echo_after_db"] as? Double, steps.contains("clearvoice") {
            parts.append("echo \(Int(a.rounded())) → \(Int(b.rounded())) dB")
        }
        if steps.contains("clearvoice") { parts.append("noise removed") }
        if steps.contains("declip") { parts.append("clipping repaired") }
        if steps.contains("dehum") { parts.append("hum removed") }
        if steps.contains("sr") { parts.append("highs rebuilt") }
        if steps.isEmpty && v["state"] as? String == "done" { parts.append("clean already: EQ and level only") }
        parts.append(quiet ? "-18 LUFS" : "-14 LUFS")
        return parts.joined(separator: " · ")
    }
}

/// The voice of the take in the player: its state, its settings, and the audio mix that plays it.
@MainActor
final class VoiceMix: ObservableObject {
    let session: URL
    let take: Take
    let key: String
    @Published private(set) var state = "none"  // none, running, done, failed
    @Published private(set) var error: String?
    @Published private(set) var summary = ""
    @Published private(set) var started: Date?
    @Published private(set) var seconds: Double = 0
    @Published var on = true
    @Published var strength = 1.0
    @Published var quiet = false
    /// Held down: hear the original.
    @Published var comparing = false { didSet { if comparing != oldValue { apply() } } }
    private weak var clock: PlayerClock?
    private var tracks: (orig: [AVAssetTrack], clean: AVAssetTrack, dry: AVAssetTrack)?
    private var building = false
    private var remix: Task<Void, Never>?

    init(take: Take, session: URL) {
        self.take = take
        self.session = session
        key = Voice.key(take)
        seconds = take.duration ?? 0
    }

    var cleaning: Bool { state == "running" }
    var ready: Bool { state == "done" }
    /// What you hear: the clean voice (true) or the take's own audio.
    var playingClean: Bool { ready && on && !comparing && tracks != nil }
    /// About how long the cleanup takes: measured 6 s for 20 s of audio on this Mac; the first run
    /// also downloads the model.
    var estimate: Double { max(20, seconds * 0.5 + 10) }

    func attach(_ clock: PlayerClock) {
        self.clock = clock
        applied = false  // a new player item needs the mix again
        reload()
    }

    /// Runs on every file change in the session: assigns (and redraws, and rebuilds the mix)
    /// only what changed.
    func reload() {
        guard let v = Voice.read(session, key) else { if state != "none" { state = "none" }; return }
        let s = v["state"] as? String ?? "none"
        let mixBefore = (on, strength, quiet)
        set(\.state, s == "idle" ? "running" : s)
        set(\.error, v["error"] as? String)
        set(\.on, v["on"] as? Bool ?? true)
        set(\.strength, v["strength"] as? Double ?? 1)
        set(\.quiet, v["loudness"] as? String == "quiet")
        if let d = v["seconds"] as? Double, d > 0 { set(\.seconds, d) }
        set(\.started, (v["started"] as? String).flatMap { Self.iso.date(from: $0) })
        set(\.summary, Voice.summary(v, quiet: quiet))
        if ready && tracks == nil { Task { await build() } }
        if mixBefore != (on, strength, quiet) || !applied { apply() }
    }

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<VoiceMix, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    /// The mix went onto the player once.
    private var applied = false

    /// Clean the voice (again) from the raw take.
    func start() {
        var v = Voice.read(session, key) ?? [:]
        v["state"] = "idle"
        v["on"] = true
        v["strength"] = v["strength"] ?? 1.0
        v["loudness"] = v["loudness"] ?? "normal"
        v["started"] = ISO8601DateFormatter().string(from: Date())
        v.removeValue(forKey: "error")
        Voice.write(session, key, v)
        tracks = nil
        state = "running"
        started = Date()
        error = nil
        if !Voice.launch(["--voice-run", session.path, String(take.number), take.kind.rawValue]) {
            state = "failed"
            error = "Could not start the cleanup (takes_mcp.py is missing from the app)."
        }
    }

    /// A setting changed: hear it now, save it, and rebuild the WAV edits use a moment later.
    func changed() {
        summary = Voice.summary(Voice.read(session, key) ?? [:], quiet: quiet)
        apply()
        var v = Voice.read(session, key) ?? [:]
        v["on"] = on
        v["strength"] = (strength * 100).rounded() / 100
        v["loudness"] = quiet ? "quiet" : "normal"
        Voice.write(session, key, v)
        remix?.cancel()
        guard ready else { return }
        remix = Task { [session, key] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Voice.launch(["--voice-mix", session.path, key])
        }
    }

    /// The take with its original audio and the clean and dry voices as three audio tracks.
    private func build() async {
        guard !building, let clock else { return }
        building = true
        defer { building = false }
        let src = AVURLAsset(url: session.appending(path: take.file))
        let cleanAsset = AVURLAsset(url: Voice.clean(session, key))
        let dryAsset = AVURLAsset(url: Voice.dry(session, key))
        do {
            let comp = AVMutableComposition()
            let duration = try await src.load(.duration)
            let whole = CMTimeRange(start: .zero, duration: duration)
            for v in try await src.loadTracks(withMediaType: .video) {
                let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(whole, of: v, at: .zero)
                t?.preferredTransform = try await v.load(.preferredTransform)
            }
            var orig: [AVAssetTrack] = []
            var audioStart = CMTime.zero
            for (i, a) in try await src.loadTracks(withMediaType: .audio).enumerated() {
                if i == 0 { audioStart = try await a.load(.timeRange).start }
                let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(whole, of: a, at: .zero)
                if let t { orig.append(t) }
            }
            func voice(_ asset: AVURLAsset) async throws -> AVAssetTrack? {
                guard let a = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
                let d = min(try await asset.load(.duration), duration - audioStart)
                let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: a, at: audioStart)
                return t
            }
            guard let c = try await voice(cleanAsset), let d = try await voice(dryAsset) else { return }
            tracks = (orig, c, d)
            clock.swap(AVPlayerItem(asset: comp))
            apply()
        } catch {
            self.error = "Could not play the clean voice: \(error.localizedDescription)"
        }
    }

    /// Hear the settings now, without saving (while the slider moves).
    func hear() { apply() }

    private func apply() {
        guard let item = clock?.player.currentItem, let tracks else { return }
        let v = Voice.volumes(clean: playingClean, strength: strength, quiet: quiet)
        func input(_ t: AVAssetTrack, _ volume: Float) -> AVAudioMixInputParameters {
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(volume, at: .zero)
            return p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.orig.map { input($0, v.orig) } + [input(tracks.clean, v.clean), input(tracks.dry, v.dry)]
        item.audioMix = mix
        applied = true
        objectWillChange.send()
    }
}

// MARK: - Views

/// In the player bar: the voice's state. Click for the panel.
struct VoiceButton: View {
    @ObservedObject var voice: VoiceMix
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if voice.cleaning {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: voice.state == "failed" ? "exclamationmark.triangle" : "waveform")
                }
                Text(label)
            }
            .font(Theme.mono(11, .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(active ? Theme.accent.opacity(0.9) : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .foregroundStyle(.white.opacity(active ? 1 : 0.8))
        }
        .buttonStyle(.plain)
        .help("Clean voice: make this take sound like a proper mic")
        .popover(isPresented: $open, arrowEdge: .top) { VoicePanel(voice: voice) }
    }

    private var active: Bool { voice.ready && voice.on }
    private var label: String {
        switch voice.state {
        case "running": "Cleaning"
        case "failed": "Voice"
        default: voice.ready && voice.on ? "Clean voice" : "Voice"
        }
    }
}

/// Clean voice: on or off, how strong, how loud, and hold to hear the original.
struct VoicePanel: View {
    @ObservedObject var voice: VoiceMix

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean voice").font(Theme.sans(14, .bold))
                    Text("Sounds like a proper mic").font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if voice.ready {
                    Toggle("", isOn: Binding(get: { voice.on }, set: { voice.on = $0; voice.changed() }))
                        .toggleStyle(.switch).labelsHidden()
                        .help(voice.on ? "Use the original audio" : "Use the clean voice")
                }
            }
            switch voice.state {
            case "running": progress
            case "done": settings
            case "failed": failed
            default: intro
            }
        }
        .padding(16)
        .frame(width: 320)
        .tint(Theme.accent)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Removes room echo, noise, clipping and hum, then levels your voice. The take itself stays as it is.")
                .font(Theme.sans(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Button("Clean voice") { voice.start() }
                .buttonStyle(AccentButtonStyle(kind: .solid))
            Text("About \(SessionDoc.clock(voice.estimate)). You can keep working.")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = voice.started.map { ctx.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(0.95, elapsed / voice.estimate))
                Text("Cleaning · \(SessionDoc.clock(elapsed)) of about \(SessionDoc.clock(voice.estimate))")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                if !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.cache/clearvoice") {
                    Text("This first time, it also downloads the voice model.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Strength").font(Theme.sans(12, .medium))
                    Spacer()
                    Text("\(Int((voice.strength * 100).rounded())) %").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                Slider(value: $voice.strength, in: 0...1) { editing in if !editing { voice.changed() } }
                    .onChange(of: voice.strength) { voice.hear() }
                    .help("100 % is the full cleanup. Lower keeps some of the room, which sounds less processed.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Loudness").font(Theme.sans(12, .medium))
                Picker("", selection: Binding(get: { voice.quiet }, set: { voice.quiet = $0; voice.changed() })) {
                    Text("Normal · -14 LUFS").tag(false)
                    Text("Quiet · -18 LUFS").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                .help("Normal is right for social video. Quiet leaves room for music under the voice.")
            }
            .disabled(!voice.on)
            .opacity(voice.on ? 1 : 0.5)
            compare
            Text(voice.summary).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let e = voice.error { Text(e).font(Theme.sans(11)).foregroundStyle(Theme.accentInk) }
            Button("Clean again from the raw take") { voice.start() }
                .buttonStyle(.plain).font(Theme.sans(11.5)).foregroundStyle(Theme.accentInk)
                .help("Run the cleanup again, for example after the voice-cleanup skill changed")
        }
    }

    /// Press and hold: the original. Let go: the clean voice.
    private var compare: some View {
        HStack(spacing: 6) {
            Image(systemName: voice.comparing ? "ear.fill" : "ear")
            Text(voice.comparing ? "Original" : "Hold to hear the original")
        }
        .font(Theme.sans(12, .medium))
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(voice.comparing ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(voice.comparing ? Theme.accent : Theme.border))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 60, maximumDistance: 50, perform: {}, onPressingChanged: { voice.comparing = $0 })
        .disabled(!voice.on)
        .opacity(voice.on ? 1 : 0.5)
        .help("Hear the take as it was recorded while you hold this")
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(voice.error ?? "The cleanup failed.").font(Theme.sans(12)).foregroundStyle(Theme.accentInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { voice.start() }.buttonStyle(AccentButtonStyle(kind: .solid))
        }
    }
}

/// Keeps an optional VoiceMix alive for the life of a player view.
@MainActor
final class VoiceHolder: ObservableObject {
    let mix: VoiceMix?
    init(_ mix: VoiceMix?) { self.mix = mix }
}
