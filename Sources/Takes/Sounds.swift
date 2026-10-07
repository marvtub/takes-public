import AppKit
import AVFoundation
import Combine
import SwiftUI

// Music and sound effects live in the Takes library, next to the styles:
//
//   <root>/_library/audio/Music/26428_Chasing the Truth.mp3
//   <root>/_library/audio/SFX/47458_Whoosh To Hit 10.mp3
//
// They are copied in from a source folder (default ~/Documents/Epidemic Sound, which mirrors the
// same Music/ and SFX/ folders). Originals are never moved or changed.
//
// A session can pick one song for its video. session.json:
//   "music": {"file": "Music/26428_Chasing the Truth.mp3", "start": 12.5, "volume": 0.35}
// file is relative to _library/audio; start is the second of the song that lines up with the
// start of the video. The MCP server reads and writes the same shape (get_session, set_music).

/// A sound effect placed on one of the session's videos. session.json:
///   "sfx": [{"file": "SFX/47458_Whoosh To Hit 10.mp3", "video": "edits/intro-v3.mp4", "at": 12.4, "volume": 0.8}]
/// video is relative to the session folder (a take or an edit): the same second means another
/// moment in another file.
struct EffectCue: Codable, Hashable, Identifiable {
    var file: String
    var video: String
    var at: Double
    var volume: Double = 0.8
    var id: String { "\(video)|\(at)|\(file)" }

    /// The video's path as a cue stores it: relative to the session when it is inside.
    nonisolated static func rel(_ video: URL, in session: URL) -> String {
        let v = video.standardizedFileURL.path, s = session.standardizedFileURL.path + "/"
        return v.hasPrefix(s) ? String(v.dropFirst(s.count)) : v
    }
}

extension SessionDoc {
    func addEffect(_ cue: EffectCue) {
        var all = meta.sfx ?? []
        all.append(cue)
        all.sort { ($0.video, $0.at) < ($1.video, $1.at) }
        meta.sfx = all
        save()
    }

    func removeEffect(_ cue: EffectCue) {
        let all = (meta.sfx ?? []).filter { $0 != cue }
        meta.sfx = all.isEmpty ? nil : all
        save()
    }
}

/// Plays the effects placed on the video on screen, each at its second, while the video plays.
@MainActor
final class EffectTrack {
    var session: URL? { didSet { if session != oldValue { rebuild() } } }
    var dir: URL?
    var cues: [EffectCue] = [] { didSet { if cues != oldValue { rebuild() } } }
    /// The file on screen.
    var video: URL? { didSet { if video != oldValue { rebuild() } } }
    private weak var player: AVPlayer?
    private var boundary: Any?
    private var kvo: NSKeyValueObservation?
    private var sounding: [AVAudioPlayer] = []
    /// How many effects played (tests).
    private(set) var fired = 0

    /// The cues of the video on screen.
    var here: [EffectCue] {
        guard let video, let session else { return [] }
        let rel = EffectCue.rel(video, in: session)
        return cues.filter { $0.video == rel }
    }

    func attach(_ p: AVPlayer?) {
        guard p !== player else { return }
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil
        kvo = nil
        stopAll()
        player = p
        kvo = p?.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let paused = p.timeControlStatus == .paused
            Task { @MainActor in if paused { self?.stopAll() } }
        }
        rebuild()
    }

    private func rebuild() {
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil
        last = nil
        guard let player, !here.isEmpty else { return }
        // A tick every 0.1 s, not a boundary observer: on a busy Mac the boundary callback came late
        // or not at all, and effects were skipped (2026-10-04). Each tick plays the cues passed since
        // the last one; a jump (a seek) plays nothing.
        boundary = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// Where the last tick saw the playhead.
    private var last: Double?

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        defer { last = t }
        // The first tick from the start counts a cue at 0:00 too.
        guard let from = last ?? (t < 0.2 ? -1 : nil), t > from, t - from < 1.5, player?.rate ?? 0 > 0 else { return }
        for c in here where c.at > from && c.at <= t { play(c) }
    }

    func play(_ c: EffectCue) {
        guard let dir, let a = try? AVAudioPlayer(contentsOf: dir.appending(path: c.file)) else { return }
        a.volume = Float(c.volume)
        a.play()
        sounding = sounding.filter(\.isPlaying) + [a]
        fired += 1
    }

    func stopAll() {
        sounding.forEach { $0.stop() }
        sounding = []
    }
}

struct SongPick: Codable, Hashable {
    var file: String
    var start: Double = 0
    var volume: Double = 0.35
}

struct Sound: Identifiable, Hashable {
    let url: URL
    let group: String   // Music, SFX, … ("" = loose in audio/)
    let rel: String     // path inside _library/audio
    var id: URL { url }

    /// "26428_Chasing the Truth.mp3" -> "Chasing the Truth".
    var title: String { Self.title(url.lastPathComponent) }

    nonisolated static func title(_ file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        guard let r = stem.range(of: #"^\d+_"#, options: .regularExpression) else { return stem }
        return String(stem[r.upperBound...])
    }
}

struct SoundInfo: Hashable {
    var artist: String?
    var genre: String?
    var bpm: Int?
    var duration: Double?
}

enum SoundLib {
    static let exts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac", "flac"]

    static func dir(root: URL) -> URL { StyleLib.user(root: root).appending(path: "audio") }

    static var defaultSource: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Epidemic Sound")
    }

    static var source: URL? {
        get {
            if let s = UserDefaults.standard.string(forKey: "soundSource") { return URL(fileURLWithPath: s) }
            return Plugins.own && FileManager.default.fileExists(atPath: defaultSource.path) ? defaultSource : nil
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "soundSource") }
    }

    /// Every audio file under `dir`, grouped by top-level folder.
    static func scan(_ dir: URL) -> [Sound] {
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.pathComponents.count
        var out: [Sound] = []
        for case let f as URL in walk where exts.contains(f.pathExtension.lowercased()) {
            let parts = Array(f.standardizedFileURL.pathComponents.dropFirst(base))
            out.append(Sound(url: f, group: parts.count > 1 ? parts[0] : "", rel: parts.joined(separator: "/")))
        }
        return out.sorted { ($0.group, $0.title.lowercased()) < ($1.group, $1.title.lowercased()) }
    }

    /// Copies audio files from `source` that `dir` does not have yet, keeping their folders.
    /// Returns how many were copied.
    @discardableResult
    static func sync(from source: URL, to dir: URL) -> Int {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                       options: [.skipsHiddenFiles]) else { return 0 }
        let base = source.standardizedFileURL.pathComponents.count
        var copied = 0
        for case let f as URL in walk where exts.contains(f.pathExtension.lowercased()) {
            let rel = f.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let target = dir.appending(path: rel)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: f, to: target)) != nil { copied += 1 }
        }
        return copied
    }

    private static var cache: [URL: SoundInfo] = [:]

    @MainActor static func info(_ url: URL) async -> SoundInfo {
        if let hit = cache[url] { return hit }
        let asset = AVURLAsset(url: url)
        var i = SoundInfo()
        if let d = try? await asset.load(.duration), d.isNumeric { i.duration = d.seconds }
        if let items = try? await asset.load(.metadata) {
            func text(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
                return try? await item.load(.stringValue)
            }
            if let a = await text(.id3MetadataLeadPerformer) { i.artist = a } else { i.artist = await text(.commonIdentifierArtist) }
            i.genre = await text(.id3MetadataContentType)
            i.bpm = await text(.id3MetadataBeatsPerMinute).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        cache[url] = i
        return i
    }
}

extension SessionDoc {
    func setMusic(_ pick: SongPick?) {
        guard meta.music != pick else { return }
        meta.music = pick
        save()
    }
}

// MARK: - The music bed

/// One song that plays under the video in the player: it follows play, pause and seeks, so you
/// hear how the video feels with it. With no video on screen it plays on its own (preview).
@MainActor
final class MusicBed: ObservableObject {
    @Published private(set) var song: URL?
    @Published private(set) var playing = false
    @Published var volume: Double = 0.35 { didSet { audio?.volume = Float(volume) } }
    /// Second of the song that lines up with the start of the video.
    @Published var start: Double = 0 { didSet { if start != oldValue { resync() } } }
    /// Play along with the video. Off = the video plays alone.
    @Published var on = true { didSet { if on != oldValue { on ? resync() : pauseAudio() } } }
    @Published private(set) var duration: Double = 0
    private(set) weak var video: AVPlayer?
    private var audio: AVAudioPlayer?
    private var kvo: NSKeyValueObservation?
    private var tick: Any?
    private var jump: NSObjectProtocol?
    private var standalone: Timer?

    var withVideo: Bool { video != nil }
    /// Where the song is now, in seconds.
    var songTime: Double { audio?.currentTime ?? 0 }

    func load(_ url: URL?, start: Double = 0, volume: Double? = nil) {
        if let volume { self.volume = volume }
        if url == song { self.start = start; return }
        audio?.stop()
        audio = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        audio?.volume = Float(self.volume)
        audio?.prepareToPlay()
        song = audio == nil ? nil : url
        duration = audio?.duration ?? 0
        self.start = start
        playing = false
        resync()
    }

    /// Follow this video player (nil = none on screen).
    func attach(_ player: AVPlayer?) {
        guard player !== video else { return }
        detach()
        video = player
        guard let player else { return }
        kvo = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.resync() }
        }
        // Seeks and scrubs: jump the song too. A slow tick catches drift while it plays.
        jump = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification,
                                                      object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.video?.currentItem else { return }
                self.resync()
            }
        }
        tick = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync(onlyIfDrift: true) }
        }
        resync()
    }

    private func detach() {
        if let tick, let video { video.removeTimeObserver(tick) }
        tick = nil
        kvo = nil
        if let jump { NotificationCenter.default.removeObserver(jump) }
        jump = nil
        if video != nil { pauseAudio() }
        video = nil
    }

    /// Where the song should be for the video's time.
    nonisolated static func position(videoTime: Double, start: Double) -> Double { max(0, start + videoTime) }

    private func resync(onlyIfDrift: Bool = false) {
        guard let audio, let video else { return }
        let rolling = video.timeControlStatus == .playing
        let t = video.currentTime().seconds
        let want = Self.position(videoTime: t.isFinite ? t : 0, start: start)
        guard on, rolling, want < audio.duration else { pauseAudio(); return }
        if !onlyIfDrift || abs(audio.currentTime - want) > 0.15 { audio.currentTime = want }
        if !audio.isPlaying { audio.play() }
        if !playing { playing = true }  // a tick a second: an equal value still redraws every view of the bed
    }

    private func pauseAudio() {
        audio?.pause()
        standalone?.invalidate()
        standalone = nil
        if playing { playing = false }
    }

    /// Play or pause. With a video on screen this plays the video (the song follows).
    func toggle() {
        if let video {
            on = true
            if video.timeControlStatus == .playing { video.pause() } else { video.play() }
            return
        }
        guard let audio else { return }
        if audio.isPlaying { pauseAudio(); return }
        if audio.currentTime < start || audio.currentTime >= audio.duration - 0.1 { audio.currentTime = start }
        audio.play()
        playing = true
        // Notice the end of a preview without a delegate.
        standalone = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.audio?.isPlaying == false { self?.pauseAudio() } }
        }
        standalone?.tolerance = 0.25
    }

    func pause() { pauseAudio() }

    func stop() {
        pauseAudio()
        audio = nil
        song = nil
        duration = 0
    }
}

/// A sound effect heard on its own, once, over whatever plays. It never moves the video.
@MainActor
final class EffectPreview: ObservableObject {
    @Published private(set) var sound: URL?
    @Published private(set) var playing = false
    private var audio: AVAudioPlayer?
    private var watch: Timer?

    func toggle(_ url: URL) {
        if sound == url, playing { stop(); return }
        audio?.stop()
        audio = try? AVAudioPlayer(contentsOf: url)
        sound = audio == nil ? nil : url
        guard let audio else { return }
        audio.play()
        playing = true
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.audio?.isPlaying == false { self?.stop() } }
        }
    }

    func stop() {
        audio?.stop()
        watch?.invalidate()
        watch = nil
        playing = false
    }
}

// MARK: - Views

struct SoundsPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var paneShown
    var doc: SessionDoc
    @ObservedObject var bed: MusicBed
    /// The whole window (no video open), or the column beside the stage.
    var wide = false
    @State private var sounds: [Sound] = []
    @State private var group = "Music"
    @State private var query = ""
    @State private var note: String?
    @StateObject private var effect = EffectPreview()
    @State private var now: Double = 0
    @Namespace private var tabs

    /// The video on screen and its player, when there is one to place effects on.
    private var screen: (url: URL, player: AVPlayer)? {
        guard let url = app.preview, Asset.kind(of: url) == .video, let p = app.player else { return nil }
        return (url, p)
    }
    private var placed: [EffectCue] {
        guard let s = screen else { return [] }
        let rel = EffectCue.rel(s.url, in: doc.url)
        return (doc.meta.sfx ?? []).filter { $0.video == rel }
    }
    /// The video the post shows: the one to open when none is on screen.
    private var postVideo: URL? {
        let u = PostFile.media(PostFile.read(doc.url), in: doc.url)
        return u.flatMap { Asset.kind(of: $0) == .video ? $0 : nil }
    }

    private var dir: URL { SoundLib.dir(root: app.library.root) }
    private var chosen: URL? { doc.meta.music.map { dir.appending(path: $0.file) } }
    private var groups: [String] {
        let g = Set(sounds.map(\.group))
        return ["Music", "SFX"].filter(g.contains) + g.subtracting(["Music", "SFX"]).sorted()
    }
    private var shown: [Sound] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = groups.count < 2  // once, not once per sound
        return sounds.filter { (all || $0.group == group) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        let _ = Perf.body("SoundsPane")
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    top.padding(.bottom, wide ? 40 : 28)
                    if wide {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Library").font(Theme.display(26)).foregroundStyle(Theme.ink)
                            if !sounds.isEmpty {
                                Text("\(sounds.count)").font(Theme.mono(12.5)).foregroundStyle(Theme.faint)
                            }
                        }
                        .padding(.bottom, 14)
                    }
                    libraryBar.padding(.bottom, 12)
                    if sounds.isEmpty { empty } else { rows }
                }
                .padding(.horizontal, wide ? 28 : 16).padding(.vertical, wide ? 24 : 16)
                .frame(maxWidth: wide ? 1000 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)  // under the Assets switch, like its other pages
            }
            if let song = bed.song, song != chosen {
                Rule()
                BedBar(bed: bed, doc: doc, dir: dir)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas)
        .animation(Theme.motion, value: bed.song)
        .onAppear { refresh(sync: false); syncInBackground() }
        .onDisappear { effect.stop() }
        .onChange(of: paneShown) { _, on in if !on { effect.stop() } }
        .task(id: "\(app.preview?.path ?? "")|\(paneShown)") {
            // The playhead, for the "add at" label: whole seconds, as the label shows them. Adding
            // reads the exact time from the player.
            while paneShown && !Task.isCancelled {
                let t = app.player?.currentTime().seconds ?? 0
                if t.isFinite, t.rounded() != now { now = t.rounded() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onFilesChanged(in: dir) { refresh(sync: false) }
    }

    private var effectsTitle: String {
        screen.map { "Effects on \(($0.url.lastPathComponent as NSString).deletingPathExtension)" } ?? "Effects"
    }

    /// What this video has: its song and its effects. Side by side in the wide page.
    @ViewBuilder private var top: some View {
        if wide {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    heading("Song under the video")
                    songCard.frame(maxHeight: .infinity, alignment: .top)
                }
                VStack(alignment: .leading, spacing: 0) {
                    heading(effectsTitle)
                    effectsCard.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                heading("Song under the video")
                songCard.padding(.bottom, 28)
                heading(effectsTitle)
                effectsCard
            }
        }
    }

    private func heading(_ text: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            if let note { Text(note).font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1) }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder private var songCard: some View {
        if let pick = doc.meta.music, let url = chosen {
            ChosenSong(url: url, pick: pick, bed: bed, compact: true,
                       onPlay: { playChosen(url, pick) },
                       onSave: save,
                       onRemove: { doc.setMusic(nil) })
        } else {
            EmptySlot(icon: "music.note", title: "No song yet",
                      text: sounds.isEmpty ? "Add a music folder below." : "Play one from the library, then click Use.",
                      tint: Theme.accent) { EmptyView() }
        }
    }

    @ViewBuilder private var effectsCard: some View {
        if screen != nil {
            if placed.isEmpty {
                EmptySlot(icon: "waveform.badge.plus", title: "Pause where a sound goes",
                          text: "Then click Add on an effect below.", tint: Color(red: 0.55, green: 0.38, blue: 0.95)) { EmptyView() }
            } else {
                PlacedEffects(cues: placed, onJump: jump, onRemove: { doc.removeEffect($0) })
            }
        } else {
            EmptySlot(icon: "waveform.badge.plus", title: "No effects yet",
                      text: "Open a video to put sounds on it.", tint: Color(red: 0.55, green: 0.38, blue: 0.95)) {
                if let v = postVideo {
                    Button { app.preview = v } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 9))
                            Text("Open \((v.lastPathComponent as NSString).deletingPathExtension)").lineLimit(1)
                        }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                    .help("Show the video the post uses, with the sounds beside it")
                    .padding(.top, 10)
                }
            }
        }
    }

    private var libraryBar: some View {
        HStack(spacing: 16) {
            if groups.count > 1 {
                HStack(spacing: 16) {
                    ForEach(groups, id: \.self) { g in
                        Button { withAnimation(Theme.spring) { group = g } } label: {
                            Text(g.isEmpty ? "Other" : g == "Music" ? "Songs" : g == "SFX" ? "Effects" : g)
                                .font(Theme.sans(13, .medium))
                                .foregroundStyle(group == g ? Theme.ink : Theme.faint)
                                .padding(.bottom, 6)
                                .overlay(alignment: .bottom) {
                                    if group == g {
                                        Rectangle().fill(Theme.ink).frame(height: 1.5)
                                            .matchedGeometryEffect(id: "tab", in: tabs)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Library").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if let note { Text(note).font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1) }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Search", text: $query).textFieldStyle(.plain).font(Theme.sans(12.5))
            }
            .padding(.horizontal, 10).frame(width: wide ? 200 : 140, height: 28)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            Menu {
                if let s = SoundLib.source {
                    Button("Copy New Files from “\(s.lastPathComponent)”") { refresh(sync: true, report: true) }
                }
                Button("Choose Source Folder…") { chooseSource() }
                Divider()
                Button("Show Library in Finder") {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.revealSoon([dir])
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Where the music comes from")
        }
    }

    private var rows: some View {
        let shown = self.shown
        return LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rule() }
                let fx = Self.isEffect(s)
                SoundRow(sound: s, current: fx ? effect.sound == s.url : bed.song == s.url,
                         playing: fx ? effect.playing : bed.playing,
                         withVideo: !fx && bed.withVideo, song: !fx, chosen: s.url == chosen,
                         placeAt: fx && screen != nil ? now : nil,
                         onPlay: { play(s) }, onUse: { use(s) }, onPlace: { place(s) })
            }
            if shown.isEmpty {
                Text("Nothing matches “\(query)”.").font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Mascot(size: 56)
            Text("No music yet").font(Theme.display(24))
            Text("Pick the folder you download music into (Epidemic Sound, Artlist, …). Takes copies it to _library/audio/ and keeps it up to date.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose Source Folder…") { chooseSource() }.buttonStyle(AccentButtonStyle(kind: .solid))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    /// Copies new files from the sound source off the main thread (it walks the whole folder),
    /// once a minute at most.
    private func syncInBackground() {
        guard let source = SoundLib.source, Date().timeIntervalSince(Self.lastSync) > 60 else { return }
        Self.lastSync = Date()
        let dir = self.dir
        Task.detached(priority: .utility) {
            let copied = SoundLib.sync(from: source, to: dir)
            guard copied > 0 else { return }
            let found = SoundLib.scan(dir)
            await MainActor.run {
                sounds = found
                note = "\(copied) new file\(copied == 1 ? "" : "s") copied"
            }
        }
    }
    @MainActor private static var lastSync = Date.distantPast

    private func refresh(sync: Bool, report: Bool = false) {
        var copied = 0
        if sync, let s = SoundLib.source { copied = SoundLib.sync(from: s, to: dir) }
        sounds = SoundLib.scan(dir)
        if !groups.contains(group), let first = groups.first { group = first }
        if copied > 0 || report { note = "\(copied) new file\(copied == 1 ? "" : "s") copied" }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = SoundLib.source ?? SoundLib.defaultSource
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SoundLib.source = url
        refresh(sync: true, report: true)
    }

    /// Sound effects are short: they play alone, never as the video's song.
    nonisolated static func isEffect(_ s: Sound) -> Bool { s.group.lowercased() != "music" }

    /// Hear it: a song with the video if one is on screen (alone otherwise), an effect alone.
    private func play(_ s: Sound) {
        if Self.isEffect(s) { effect.toggle(s.url); return }
        effect.stop()
        if bed.song == s.url { bed.toggle(); return }
        let pick = doc.meta.music
        bed.load(s.url, start: s.url == chosen ? pick?.start ?? 0 : 0, volume: s.url == chosen ? pick?.volume : nil)
        bed.toggle()
    }

    private func playChosen(_ url: URL, _ pick: SongPick) {
        effect.stop()
        if bed.song != url { bed.load(url, start: pick.start, volume: pick.volume) }
        bed.toggle()
    }

    /// Keeps the start and volume you set on the chosen song.
    private func save() {
        guard var pick = doc.meta.music, bed.song == chosen else { return }
        pick.start = (bed.start * 10).rounded() / 10
        pick.volume = (bed.volume * 100).rounded() / 100
        doc.setMusic(pick)
    }

    /// Puts the effect on the video on screen, at the playhead.
    private func place(_ s: Sound) {
        guard let (url, player) = screen else { return }
        let t = player.currentTime().seconds
        let at = ((t.isFinite ? t : 0) * 10).rounded() / 10
        doc.addEffect(EffectCue(file: s.rel, video: EffectCue.rel(url, in: doc.url), at: at))
        effect.toggle(s.url)
        app.show(toast: "\(s.title) at \(SessionDoc.clock(at))")
    }

    /// Hear a placed effect in place: from a second before it.
    private func jump(_ c: EffectCue) {
        guard let (_, player) = screen else { return }
        player.seek(to: CMTime(seconds: max(0, c.at - 1), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func use(_ s: Sound) {
        guard !Self.isEffect(s) else { return }
        let same = bed.song == s.url
        doc.setMusic(SongPick(file: s.rel, start: same ? bed.start : 0, volume: same ? bed.volume : 0.35))
        if !same { bed.load(s.url, start: 0, volume: 0.35) }
        app.show(toast: "♪ \(s.title) for this video")
    }
}

struct SoundRow: View {
    let sound: Sound
    let current: Bool
    let playing: Bool
    let withVideo: Bool
    /// A song can be the video's song; an effect only plays.
    let song: Bool
    let chosen: Bool
    /// The playhead, when this effect can go on the video on screen.
    var placeAt: Double? = nil
    let onPlay: () -> Void
    let onUse: () -> Void
    var onPlace: () -> Void = {}
    @State private var info = SoundInfo()
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                SoundCover(title: sound.title, effect: !song, current: current, playing: playing, hover: hover)
            }
            .buttonStyle(.plain)
            .help(!song ? "Hear this sound" : withVideo ? "Play the video with this song" : "Play this song")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sound.title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if chosen { Tag(text: "This video", accent: true) }
                }
                if !details.isEmpty {
                    Text(details).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let t = placeAt, hover || current {
                Button("Add at \(SessionDoc.clock(t))") { onPlace() }
                    .buttonStyle(BracketButtonStyle(active: false))
                    .help("Put this sound on the video at the playhead. It plays there, and Takes' edit uses it.")
                    .transition(.opacity)
            }
            if song && !chosen && (hover || current) {
                Button("Use") { onUse() }
                    .buttonStyle(BracketButtonStyle(active: false))
                    .help("Pick this song for this session's video")
                    .transition(.opacity)
            }
            if let d = info.duration {
                Text(SessionDoc.clock(d)).font(Theme.mono(12)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(current ? Theme.accentSoft.opacity(0.6) : hover ? Theme.hover : .clear)
        .overlay(alignment: .leading) {
            if chosen { Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 10) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        // Play on the first click, not after the double-click interval. A double-click on a song
        // also uses it; the first click already started it playing.
        .gesture(TapGesture(count: 2).onEnded { if song { onUse() } })
        .simultaneousGesture(TapGesture().onEnded { if NSApp.firstClick { onPlay() } })
        .onDrag { NSItemProvider(contentsOf: sound.url) ?? NSItemProvider() }
        .contextMenu {
            if song { Button("Use for This Video") { onUse() } }
            if placeAt != nil { Button("Add at the Playhead") { onPlace() } }
            Button("Reveal in Finder") { NSWorkspace.shared.revealSoon([sound.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sound.url.path, forType: .string)
            }
        }
        .task(id: sound.url) { info = await SoundLib.info(sound.url) }
    }

    private var details: String {
        [info.artist, info.genre, info.bpm.map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The effects placed on the video on screen.
struct PlacedEffects: View {
    let cues: [EffectCue]
    let onJump: (EffectCue) -> Void
    let onRemove: (EffectCue) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(cues.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rule() }
                HStack(spacing: 12) {
                    Button { onJump(c) } label: {
                        Text(SessionDoc.clock(c.at)).font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.accentInk)
                            .frame(width: 40, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Play from just before it")
                    Text(Sound.title((c.file as NSString).lastPathComponent)).font(Theme.sans(13)).lineLimit(1)
                    Spacer()
                    Button { onRemove(c) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 22, height: 22) }
                        .buttonStyle(IconButtonStyle())
                        .help("Take this sound off the video")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// The song picked for this session: play it, set where it starts and how loud it is.
struct ChosenSong: View {
    let url: URL
    let pick: SongPick
    @ObservedObject var bed: MusicBed
    var compact = false
    let onPlay: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    private var loaded: Bool { bed.song == url }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button(action: onPlay) {
                    Image(systemName: loaded && bed.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 38, height: 38)
                        .background(Theme.ink, in: Circle())
                        .scaleEffect(hover ? 1.06 : 1)
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .animation(Theme.spring, value: hover)
                .help(bed.withVideo ? "Play the video with its song" : "Play the song")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Sound.title(url.lastPathComponent)).font(Theme.display(22)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("Starts at \(SessionDoc.clock(loaded ? bed.start : pick.start)) · volume \(Int(((loaded ? bed.volume : pick.volume) * 100).rounded()))%")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                if loaded && bed.withVideo {
                    Toggle("Song on", isOn: $bed.on).toggleStyle(.switch).controlSize(.mini)
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .help("Hear the video with or without the song")
                }
                Menu {
                    Button("No Song for This Video", role: .destructive) { onRemove() }
                    Button("Reveal in Finder") { NSWorkspace.shared.revealSoon([url]) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if loaded {
                let sliders = Group {
                    slider("Start", value: $bed.start, in: 0...max(1, bed.duration - 1), label: SessionDoc.clock(bed.start))
                        .help("The second of the song that plays when the video starts")
                    slider("Volume", value: $bed.volume, in: 0...1, label: "\(Int((bed.volume * 100).rounded()))%")
                }
                if compact { VStack(spacing: 8) { sliders } } else { HStack(spacing: 24) { sliders } }
            }
        }
        .card(padding: 16)
        .animation(Theme.motion, value: loaded)
        .tint(Theme.ink)
    }

    private func slider(_ name: String, value: Binding<Double>, in range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Theme.sans(12)).foregroundStyle(Theme.faint).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range) { if !$0 { onSave() } }.controlSize(.mini)
            Text(label).font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 38, alignment: .trailing)
        }
    }
}

/// Now playing, when it is not the chosen song: play or stop it, or change where it starts.
struct BedBar: View {
    @ObservedObject var bed: MusicBed
    var doc: SessionDoc
    let dir: URL

    var body: some View {
        HStack(spacing: 12) {
            Button { bed.toggle() } label: {
                Image(systemName: bed.playing ? "pause.fill" : "play.fill").frame(width: 24, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            VStack(alignment: .leading, spacing: 1) {
                Text(bed.song.map { Sound.title($0.lastPathComponent) } ?? "").font(Theme.sans(13, .medium)).lineLimit(1)
                Text(bed.withVideo ? "With the video" : "Alone")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    .help(bed.withVideo ? "Follows the video: play, pause and scrub it" : "Show a video in the player to hear them together")
            }
            Spacer(minLength: 8)
            Slider(value: $bed.start, in: 0...max(1, bed.duration - 1)).controlSize(.mini).frame(maxWidth: 160)
                .help("The second of the song that plays when the video starts")
            Text(SessionDoc.clock(bed.start)).font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 36, alignment: .trailing)
            Button { bed.stop() } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 22, height: 22) }
                .buttonStyle(IconButtonStyle()).help("Stop")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.paper)
        .tint(Theme.ink)
    }
}

/// On the video: which song plays under it. Click to hear the video with or without it.
struct BedPill: View {
    @ObservedObject var bed: MusicBed

    var body: some View {
        if let song = bed.song, bed.withVideo {
            Button { bed.on.toggle() } label: {
                StagePill(text: Sound.title(song.lastPathComponent), icon: bed.on ? "music.note" : "speaker.slash", accent: bed.on)
                    .opacity(bed.on ? 1 : 0.7)
            }
            .buttonStyle(.plain)
            .help(bed.on ? "The song plays with the video. Click to hear the video alone." : "Click to hear the song with the video")
        }
    }
}

/// A small cover for a sound: a gradient picked from its title, so each track keeps its colour.
/// Hover shows play; the playing track shows a moving waveform (a symbol effect, drawn by the system).
struct SoundCover: View {
    let title: String
    let effect: Bool
    let current: Bool
    let playing: Bool
    let hover: Bool

    private var hue: Double {
        let h = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Double(h % 360) / 360
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.42, brightness: 0.95),
                                               Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.74)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(.black.opacity(hover || current ? 0.3 : 0))
            glyph.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 38, height: 38)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .scaleEffect(hover ? 1.05 : 1)
        .animation(Theme.spring, value: hover)
        .animation(Theme.motion, value: current)
    }

    @ViewBuilder private var glyph: some View {
        if hover || (current && !playing) {
            Image(systemName: current && playing ? "pause.fill" : "play.fill")
        } else if current && playing {
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: true)
        } else {
            Image(systemName: effect ? "waveform" : "music.note").opacity(0.85)
        }
    }
}

/// The faint waveform behind an empty spot.
private let slotBars: [CGFloat] = [0.35, 0.6, 0.9, 0.55, 0.75, 1, 0.65, 0.4, 0.8, 0.5, 0.3, 0.6, 0.85, 0.45, 0.25]

/// An empty spot on the Sound page: a tinted icon, one line and a hint, over a faint waveform.
private struct EmptySlot<Extra: View>: View {
    let icon: String
    let title: String
    let text: String
    let tint: Color
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                extra
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(slotBars.enumerated()), id: \.offset) { _, b in
                    Capsule().fill(tint.opacity(0.13)).frame(width: 3, height: 34 * b)
                }
            }
            .padding(.trailing, 20).padding(.bottom, 18)
            .accessibilityHidden(true)
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape.fill(Theme.paper)
                .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
                .shadow(color: Theme.shadow, radius: 10, y: 4)
        }
    }
}
