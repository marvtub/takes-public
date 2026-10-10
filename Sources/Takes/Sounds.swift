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
// The app never plays sound over a video. The chat mixes music and effects into a new version of
// the file, so what plays is what posts. Until 2026-10-09 a session could pick a song and place
// effects that the player added live; the chat also mixed the song in, so it played twice,
// and nobody could tell which was which. Here you only hear sounds alone, and Use asks the chat.

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

@MainActor
final class SoundPreview: ObservableObject {
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
    /// The whole window (no video open), or the column beside the stage.
    var wide = false
    @State private var sounds: [Sound] = []
    @State private var group = "Music"
    @State private var query = ""
    @State private var note: String?
    @StateObject private var preview = SoundPreview()
    @State private var now: Double = 0
    @Namespace private var tabs

    /// The video on screen and its player: an effect goes in at its playhead.
    private var screen: (url: URL, player: AVPlayer)? {
        guard let url = app.preview, Asset.kind(of: url) == .video, let p = app.player else { return nil }
        return (url, p)
    }

    private var dir: URL { SoundLib.dir(root: app.library.root) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Sound").font(Theme.display(wide ? 26 : 22)).foregroundStyle(Theme.ink)
                    if !sounds.isEmpty {
                        Text("\(sounds.count)").font(Theme.mono(12.5)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.bottom, 4)
                Text("Takes mixes music and effects into the video file. Click Use and the chat makes a new version with it.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, wide ? 24 : 18)
                libraryBar.padding(.bottom, 12)
                if sounds.isEmpty { empty } else { rows }
            }
            .padding(.horizontal, wide ? 28 : 16).padding(.vertical, wide ? 24 : 16)
            .frame(maxWidth: wide ? 1000 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)  // under the Assets switch, like its other pages
        }
        .background(Theme.canvas)
        .onAppear { refresh(sync: false); syncInBackground() }
        .onDisappear { preview.stop() }
        .onChange(of: paneShown) { _, on in if !on { preview.stop() } }
        // A video starting stops the sound you were hearing: never both at once.
        .onChange(of: app.preview) { preview.stop() }
        .task(id: "\(app.preview?.path ?? "")|\(paneShown)") {
            // The playhead, for the "Add at" label: whole seconds, as the label shows them. The ask
            // reads the exact time from the player.
            while paneShown && !Task.isCancelled {
                let t = app.player?.currentTime().seconds ?? 0
                if t.isFinite, t.rounded() != now { now = t.rounded() }
                if app.player?.timeControlStatus == .playing, preview.playing { preview.stop() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onFilesChanged(in: dir) { refresh(sync: false) }
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
                SoundRow(sound: s, current: preview.sound == s.url, playing: preview.playing, effect: fx,
                         placeAt: fx && screen != nil ? now : nil,
                         onPlay: { play(s) }, onUse: { use(s) })
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


    /// Sound effects are short; songs are the bed under a whole video.
    nonisolated static func isEffect(_ s: Sound) -> Bool { s.group.lowercased() != "music" }

    /// Hear it alone. A playing video pauses first: never the two at once.
    private func play(_ s: Sound) {
        if app.player?.timeControlStatus == .playing { app.player?.pause() }
        preview.toggle(s.url)
    }

    /// Asks the chat to mix the sound into a new version of the video.
    private func use(_ s: Sound) {
        preview.stop()
        app.chats.chat(doc.url).send(Self.ask(s, video: screen.map { EffectRef(url: $0.url, at: at($0.player)) }, session: doc.url),
                                     title: doc.meta.title, onStage: app.preview,
                                     shown: Self.isEffect(s) ? "Add “\(s.title)”" : "Use “\(s.title)” as the music")
        app.chats.open = true
    }

    private func at(_ player: AVPlayer) -> Double {
        let t = player.currentTime().seconds
        return ((t.isFinite ? t : 0) * 10).rounded() / 10
    }

    /// The video on screen and its playhead, for an effect.
    struct EffectRef { let url: URL; let at: Double }

    /// What the chat gets for Use: the file, and for an effect the video and second it goes at.
    static func ask(_ s: Sound, video: EffectRef?, session: URL) -> String {
        let file = "_library/audio/\(s.rel)"
        if !isEffect(s) {
            return "Use the song “\(s.title)” (\(file)) as the music for this video. Mix it into a new version of the edit, "
                + "under the voice, and tell me which file has it."
        }
        guard let video else {
            return "Add the sound effect “\(s.title)” (\(file)) to this video where it fits. Mix it into a new version of the edit "
                + "and tell me the second."
        }
        let name = video.url.path.hasPrefix(session.path + "/") ? String(video.url.path.dropFirst(session.path.count + 1)) : video.url.path
        return "Add the sound effect “\(s.title)” (\(file)) to \(name) at \(SessionDoc.clock(video.at)) (\(video.at) s). "
            + "Mix it into a new version of that video."
    }
}

struct SoundRow: View {
    let sound: Sound
    let current: Bool
    let playing: Bool
    /// An effect; otherwise a song.
    let effect: Bool
    /// The playhead, when an effect can go on the video on screen.
    var placeAt: Double? = nil
    let onPlay: () -> Void
    let onUse: () -> Void
    @State private var info = SoundInfo()
    @State private var hover = false

    private var useLabel: String { placeAt.map { "Add at \(SessionDoc.clock($0))" } ?? "Use" }

    var body: some View {
        HStack(spacing: 12) {
            // Not a button: the row's tap plays it. As a button inside the row, one click fired both
            // and paused the song it had just started (2026-10-09).
            SoundCover(title: sound.title, effect: effect, current: current, playing: playing, hover: hover)
            .help(effect ? "Hear this sound" : "Hear this song")
            VStack(alignment: .leading, spacing: 1) {
                Text(sound.title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if !details.isEmpty {
                    Text(details).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hover || current {
                Button(useLabel) { onUse() }
                    .buttonStyle(BracketButtonStyle(active: false))
                    .help(effect ? "Ask the chat to mix this sound into the video" : "Ask the chat to mix this song under the video")
                    .transition(.opacity)
            }
            if let d = info.duration {
                Text(SessionDoc.clock(d)).font(Theme.mono(12)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(current ? Theme.accentSoft.opacity(0.6) : hover ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        // Play on the first click, not after the double-click interval.
        .simultaneousGesture(TapGesture().onEnded { if NSApp.firstClick { onPlay() } })
        .onDrag { NSItemProvider(contentsOf: sound.url) ?? NSItemProvider() }
        .contextMenu {
            Button(effect ? (placeAt == nil ? "Add to This Video" : "Add at the Playhead") : "Use for This Video") { onUse() }
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
