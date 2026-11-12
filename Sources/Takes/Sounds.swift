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

    /// Songs Takes made with ElevenLabs Music (make_music, 2026-11-03): audio/Made/.
    static let made = "Made"

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
        // Length and tags load side by side: neither needs the other.
        async let length = try? await asset.load(.duration)
        async let tags = try? await asset.load(.metadata)
        if let d = await length, d.isNumeric { i.duration = d.seconds }
        if let items = await tags {
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

/// Tags on songs and effects (2026-11-08): <audio>/.tags.json maps a file's path inside audio/ to
/// its tags, {"Made/Calm piano v1.mp3": ["Education", "Calm"]}. Same file as the server's
/// tag_sounds and list_music tag. Two tags that differ only in case are one tag; the first
/// spelling stays. The file is hidden, so the scan and the Finder skip it.
enum SoundTags {
    static let file = ".tags.json"
    static let maxLength = 32

    static func url(_ dir: URL) -> URL { dir.appending(path: file) }

    /// The tags, or nil when the file is there but does not parse: then nothing writes over it.
    static func load(_ dir: URL) -> [String: [String]]? {
        let u = url(dir)
        guard let data = try? Data(contentsOf: u) else { return FileManager.default.fileExists(atPath: u.path) ? nil : [:] }
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: [String]] = [:]
        for (k, v) in all { if let list = v as? [Any] { out[k] = list.compactMap { $0 as? String } } }
        return out
    }

    @discardableResult
    static func save(_ tags: [String: [String]], to dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: tags.filter { !$0.value.isEmpty },
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: url(dir), options: .atomic)) != nil
    }

    /// One line, single spaces, at most 32 characters.
    static func clean(_ tag: String) -> String {
        String(tag.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// have + add - remove, in order, case-insensitive. A new tag takes the spelling `known` uses.
    static func merge(_ have: [String], add: [String] = [], remove: [String] = [], known: [String] = []) -> [String] {
        let spelled = Dictionary(known.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let gone = Set(remove.map { clean($0).lowercased() })
        var seen = Set<String>(), out: [String] = []
        for t in have + add.map({ spelled[clean($0).lowercased()] ?? clean($0) }) {
            let k = t.lowercased()
            if !t.isEmpty, !gone.contains(k), seen.insert(k).inserted { out.append(t) }
        }
        return out
    }

    /// Every tag on these sounds, most used first, then by name.
    static func counts(_ lists: [[String]]) -> [(name: String, count: Int)] {
        var c: [String: (name: String, count: Int)] = [:]
        for list in lists { for t in list { c[t.lowercased(), default: (t, 0)].count += 1 } }
        return c.values.sorted { ($0.count, $1.name.lowercased()) > ($1.count, $0.name.lowercased()) }
    }

    static func has(_ list: [String], _ tag: String) -> Bool { list.contains { $0.lowercased() == tag.lowercased() } }
}

@MainActor
final class SoundPreview: ObservableObject {
    @Published private(set) var sound: URL?
    @Published private(set) var playing = false
    private var audio: AVAudioPlayer?
    private var watch: Timer?

    func toggle(_ url: URL) {
        if sound == url, playing { stop(); return }
        fadeOut(audio)
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

    /// Stops with a short fade (2026-11-08): a cut mid-note, on a tab change, sounded like a crack.
    func stop() {
        fadeOut(audio)
        audio = nil
        watch?.invalidate()
        watch = nil
        playing = false
    }

    /// The closure keeps the player, so the fade ends even when the pane and this object are gone.
    static let fade: TimeInterval = 0.4
    private func fadeOut(_ player: AVAudioPlayer?) {
        guard let player, player.isPlaying else { player?.stop(); return }
        player.setVolume(0, fadeDuration: Self.fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.05) { player.stop() }
    }
}

// MARK: - Views

struct SoundsPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.paneShown) private var paneShown
    var doc: SessionDoc
    /// The whole window (no video open), or the column beside the stage.
    var wide = false
    /// The tab to open on (snapshots).
    var startOn: String? = nil
    @State private var sounds: [Sound] = []
    @State private var prompt = ""
    @FocusState private var typing: Bool
    @Environment(\.displayScale) private var scale
    @State private var group = "Music"
    @State private var query = ""
    @State private var note: String?
    /// Tags by file (`SoundTags`); nil while the file does not parse, so nothing writes over it.
    @State private var tags: [String: [String]]? = [:]
    @State private var tagFilter: String?
    @StateObject private var preview = SoundPreview()
    @State private var now: Double = 0
    @Namespace private var tabs

    /// The video on screen and its player: an effect goes in at its playhead.
    private var screen: (url: URL, player: AVPlayer)? {
        guard let url = app.preview, Asset.kind(of: url) == .video, let p = app.player else { return nil }
        return (url, p)
    }

    private var dir: URL { SoundLib.dir(root: app.library.root) }
    /// Made is always there: it is where you make a song, even before the first one.
    private var groups: [String] { Self.groups(sounds) }
    nonisolated static func groups(_ sounds: [Sound]) -> [String] {
        let g = Set(sounds.map(\.group))
        let first = ["Music", "SFX"]
        return first.filter(g.contains) + g.subtracting(first + [SoundLib.made]).sorted() + [SoundLib.made]
    }
    private var onMade: Bool { group == SoundLib.made }
    /// The sounds on this tab, before the search and the tag.
    private var onTab: [Sound] {
        let all = groups.count < 2  // once, not once per sound
        return sounds.filter { all || $0.group == group }
    }
    private func tagsOf(_ s: Sound) -> [String] { tags?[s.rel] ?? [] }
    private var shown: [Sound] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return onTab.filter { s in
            let t = tagsOf(s)
            return (tagFilter.map { SoundTags.has(t, $0) } ?? true)
                && (q.isEmpty || s.title.localizedCaseInsensitiveContains(q) || t.contains { $0.localizedCaseInsensitiveContains(q) })
        }
    }
    /// The tags on this tab, for the filter row.
    private var tabTags: [(name: String, count: Int)] { SoundTags.counts(onTab.map(tagsOf)) }
    /// Every tag in the library, for the editor's suggestions.
    private var libraryTags: [String] { SoundTags.counts(Array((tags ?? [:]).values)).map(\.name) }

    var body: some View {
        let _ = Perf.body("SoundsPane")
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Named sections (2026-11-08): a mod can hide, move or replace each one (mods/layouts/sound.json).
                BoardSections(board: "sound", available: sectionIDs, snapshots: { sectionSnapshots }) { id in section(id) }
            }
            .padding(.horizontal, wide ? 28 : 16).padding(.vertical, wide ? 24 : 16)
            .frame(maxWidth: wide ? 1000 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)  // under the Assets switch, like its other pages
        }
        .background(Theme.canvas)
        .onAppear {
            refresh(sync: false); syncInBackground()
            if let startOn { group = startOn }
        }
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
        .onChange(of: group) { tagFilter = nil }
    }

    /// The sections on screen now, in Takes's order. A plain function, so tests read the rule.
    private var sectionIDs: [String] {
        Self.sectionIDs(empty: sounds.isEmpty, tags: !tabTags.isEmpty, made: onMade, rows: onMade ? !shown.isEmpty : !sounds.isEmpty)
    }
    nonisolated static func sectionIDs(empty: Bool, tags: Bool, made: Bool, rows: Bool) -> [String] {
        var ids = ["sound.header"]
        if empty { ids.append("sound.empty") }
        ids.append("sound.tabs")
        if tags { ids.append("sound.tags") }
        if made { ids.append("sound.made.input") }
        if rows { ids.append(made ? "sound.made.list" : "sound.list") }
        return ids
    }

    @ViewBuilder private func section(_ id: String) -> some View {
        switch id {
        case "sound.header": header
        case "sound.empty": empty.padding(.bottom, 18)
        case "sound.tabs": libraryBar.padding(.bottom, 12)
        case "sound.tags": tagBar.padding(.bottom, 12)
        case "sound.made.input": makeBar.padding(.bottom, 12)
        case "sound.made.list", "sound.list": rows
        default: EmptyView()
        }
    }

    nonisolated static let subtitle = "Takes mixes music and effects into the video file. Click Use and the chat makes a new version with it."
    nonisolated static let makeHint = "Describe a song: piano over soft drum and bass, 174 BPM, calm build"
    nonisolated static func tabTitle(_ g: String) -> String { g.isEmpty ? "Other" : g == "Music" ? "Songs" : g == "SFX" ? "Effects" : g }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sound").font(Theme.display(wide ? 26 : 22)).foregroundStyle(Theme.ink)
                if !sounds.isEmpty {
                    Text("\(sounds.count)").font(Theme.mono(12.5)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.bottom, 4)
            Text(Self.subtitle)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, wide ? 24 : 18)
        }
    }

    /// What a mod reads as data.section, built only when a mod asks for a Sound section.
    private var sectionSnapshots: [String: [String: Any]] {
        let rows = shown.map { s -> [String: Any] in
            ["title": s.title, "file": "_library/audio/\(s.rel)", "group": s.group, "tags": tagsOf(s),
             "effect": Self.isEffect(s), "playing": preview.sound == s.url && preview.playing]
        }
        let list: [String: Any] = ["rows": rows, "count": rows.count, "tab": group, "query": query, "tag": tagFilter ?? NSNull()]
        let made = sounds.filter { $0.group == SoundLib.made }.count
        return [
            "sound.header": ["title": "Sound", "subtitle": Self.subtitle, "count": sounds.count],
            "sound.empty": ["source": SoundLib.source?.path ?? NSNull(), "library": dir.path],
            "sound.tabs": ["tabs": groups.map { g in ["id": g, "title": Self.tabTitle(g), "selected": g == group,
                                                      "count": sounds.filter { $0.group == g }.count] as [String: Any] },
                           "tab": group, "query": query, "note": note ?? NSNull(), "source": SoundLib.source?.path ?? NSNull()],
            "sound.tags": ["tags": tabTags.map { t in ["name": t.name, "count": t.count,
                                                       "on": tagFilter?.lowercased() == t.name.lowercased()] as [String: Any] },
                           "picked": tagFilter ?? NSNull()],
            "sound.made.input": ["prompt": prompt, "placeholder": Self.makeHint, "made": made],
            "sound.made.list": list,
            "sound.list": list,
        ]
    }

    /// The tags on this tab: a click shows only the sounds with it, a second click shows all.
    private var tagBar: some View {
        TagFlow(spacing: 6) {
            ForEach(tabTags, id: \.name) { t in
                let on = tagFilter.map { $0.lowercased() == t.name.lowercased() } ?? false
                Button { withAnimation(Theme.spring) { tagFilter = on ? nil : t.name } } label: {
                    HStack(spacing: 5) {
                        Text(t.name).font(Theme.sans(12, .medium)).lineLimit(1)
                        Text("\(t.count)").font(Theme.mono(10.5)).opacity(0.7)
                    }
                    .foregroundStyle(on ? Theme.accentInk : Theme.muted)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(on ? Theme.accentSoft : Theme.paper, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.4) : Theme.border, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "Show every sound" : "Show only sounds tagged “\(t.name)”")
            }
        }
    }

    /// Writes one sound's tags. Reads the file first, so a tag the chat just added stays.
    private func setTags(_ s: Sound, _ list: [String]) {
        guard var all = SoundTags.load(dir) else {
            tags = nil
            note = "Tags not saved: \(SoundTags.file) does not read"
            return
        }
        all[s.rel] = list
        if SoundTags.save(all, to: dir) { tags = all.filter { !$0.value.isEmpty } } else { note = "Tags not saved" }
        if let f = tagFilter, !SoundTags.counts(onTab.map(tagsOf)).contains(where: { $0.name.lowercased() == f.lowercased() }) {
            tagFilter = nil
        }
    }


    private var libraryBar: some View {
        HStack(spacing: 16) {
            if groups.count > 1 {
                HStack(spacing: 16) {
                    ForEach(groups, id: \.self) { g in
                        Button { withAnimation(Theme.spring) { group = g } } label: {
                            Text(Self.tabTitle(g))
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
            TakesMenuButton(help: "Where the music comes from") {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            } content: {
                if let s = SoundLib.source {
                    MenuButton("Copy New Files from “\(s.lastPathComponent)”", icon: "arrow.down.doc") { refresh(sync: true, report: true) }
                }
                MenuButton("Choose Source Folder…", icon: "folder.badge.gearshape") { chooseSource() }
                MenuDivider()
                MenuButton("Show Library in Finder", icon: "folder") {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.revealSoon([dir])
                }
            }
            .fixedSize()
        }
    }

    /// Describe a song; Make asks the chat, which runs make_music and puts it on this tab.
    /// Like the chat box (2026-11-08): no icon, no credits line, two lines to write in, Make bottom right.
    private var makeBar: some View {
        let empty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .trailing, spacing: 6) {
                // Its own hint, faint: the field's placeholder drew nearly as dark as typed words.
                TextField("", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.sans(13.5)).lineLimit(2...6)
                    .focused($typing)
                    .onSubmit(make)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(Self.makeHint)
                                .font(Theme.sans(13.5)).foregroundStyle(Theme.faint).allowsHitTesting(false)
                        }
                    }
                Button(action: make) {
                    Text("Make").font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(empty ? Theme.faint : Theme.paper)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(empty ? Theme.border : Theme.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(empty)
                .help("The chat makes the song and puts it here")
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.top, 12).padding(.bottom, 8)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(typing ? Theme.muted.opacity(0.5) : Theme.border,
                                                                      lineWidth: 1 / scale))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { typing = true }
            .animation(Theme.spring, value: typing)
            if shown.isEmpty {
                Text("Songs you make land here.").font(Theme.sans(12)).foregroundStyle(Theme.faint)
            }
        }
    }

    private func make() {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        preview.stop()
        app.chats.chat(doc.url).send(Self.makeAsk(p), title: doc.meta.title, onStage: app.preview,
                                     shown: "Make a song: “\(p)”")
        app.chats.open = true
        prompt = ""
    }

    /// What the chat gets for Make.
    nonisolated static func makeAsk(_ prompt: String) -> String {
        "Make a song with make_music: \(prompt). If a video of this session is on screen, make it as long as that video. "
            + "Then tell me its name and the credits it used."
    }

    private var rows: some View {
        let shown = self.shown
        return LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Rule() }
                let fx = Self.isEffect(s)
                SoundRow(sound: s, current: preview.sound == s.url, playing: preview.playing, effect: fx,
                         placeAt: fx && screen != nil ? now : nil, tags: tagsOf(s), libraryTags: libraryTags,
                         canTag: tags != nil,
                         onPlay: { play(s) }, onUse: { use(s) }, onTags: { setTags(s, $0) })
            }
            if shown.isEmpty {
                Text(query.isEmpty ? "Nothing tagged “\(tagFilter ?? "")” here." : "Nothing matches “\(query)”.").font(Theme.sans(13)).foregroundStyle(Theme.muted)
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
        tags = SoundTags.load(dir)
        if !groups.contains(group), let first = groups.first { group = first }
        if sounds.isEmpty { group = SoundLib.made }
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
    nonisolated static func isEffect(_ s: Sound) -> Bool { !["music", SoundLib.made.lowercased()].contains(s.group.lowercased()) }

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
    var tags: [String] = []
    /// Every tag in the library, offered in the editor.
    var libraryTags: [String] = []
    var canTag = true
    let onPlay: () -> Void
    let onUse: () -> Void
    var onTags: ([String]) -> Void = { _ in }
    @State private var info = SoundInfo()
    @State private var hover = false
    @State private var editing = false

    private var useLabel: String { placeAt.map { "Add at \(SessionDoc.clock($0))" } ?? "Use" }

    var body: some View {
        HStack(spacing: 12) {
            // Not a button: the row's tap plays it. As a button inside the row, one click fired both
            // and paused the song it had just started (2026-10-09).
            SoundCover(title: sound.title, effect: effect, current: current, playing: playing, hover: hover)
            .help(effect ? "Hear this sound" : "Hear this song")
            VStack(alignment: .leading, spacing: 1) {
                Text(sound.title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if !details.isEmpty || !tags.isEmpty {
                    HStack(spacing: 6) {
                        if !details.isEmpty {
                            Text(details).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                        ForEach(tags, id: \.self) { Tag(text: $0) }
                    }
                }
            }
            .takesPopover(isPresented: $editing) {
                SoundTagEditor(title: sound.title, tags: tags, suggestions: libraryTags, onChange: onTags)
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
        .takesContextMenu {
            MenuButton(effect ? (placeAt == nil ? "Add to This Video" : "Add at the Playhead") : "Use for This Video",
                       icon: effect ? "plus.circle" : "music.note") { onUse() }
            MenuButton(tags.isEmpty ? "Add Tags…" : "Edit Tags…", icon: "tag", enabled: canTag) { editing = true }
            MenuDivider()
            MenuButton("Reveal in Finder", icon: "folder") { NSWorkspace.shared.revealSoon([sound.url]) }
            MenuButton("Copy Path", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sound.url.path, forType: .string)
            }
        }
        .task(id: sound.url) { info = await SoundLib.info(sound.url) }
    }

    private var details: String {
        // A genre that is also a tag shows once, as the tag.
        let genre = info.genre.flatMap { SoundTags.has(tags, $0) ? nil : $0 }
        return [info.artist, genre, info.bpm.map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A sound's tags: remove one with its ×, type a new one and press Return, or pick one the
/// library already has. Each change saves at once.
struct SoundTagEditor: View {
    let title: String
    @State var tags: [String]
    let suggestions: [String]
    let onChange: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var offered: [String] {
        let q = SoundTags.clean(text).lowercased()
        return suggestions.filter { !SoundTags.has(tags, $0) && (q.isEmpty || $0.lowercased().contains(q)) }.prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tags").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text(title).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            if !tags.isEmpty {
                TagFlow(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Button { set(SoundTags.merge(tags, remove: [t])) } label: {
                            HStack(spacing: 4) {
                                Text(t).font(Theme.sans(12, .medium)).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
                            }
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(Theme.accentSoft, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(t)”")
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Add a tag", text: $text).textFieldStyle(.plain).font(Theme.sans(12.5))
                    .focused($focused)
                    .onSubmit(add)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Theme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            if !offered.isEmpty {
                TagFlow(spacing: 6) {
                    ForEach(offered, id: \.self) { t in
                        Button { set(SoundTags.merge(tags, add: [t])); text = "" } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                Text(t).font(Theme.sans(12)).lineLimit(1)
                            }
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 9).frame(height: 22)
                            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .onAppear { focused = true }
    }

    private func add() {
        let t = SoundTags.clean(text)
        guard !t.isEmpty else { return }
        set(SoundTags.merge(tags, add: [t], known: suggestions))
        text = ""
    }

    private func set(_ list: [String]) {
        withAnimation(Theme.spring) { tags = list }
        onChange(list)
    }
}

/// Rows of small views that wrap to the next line.
struct TagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [Int] = []; var xs: [CGFloat] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty, x + size.width > maxWidth {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
                row.items = [i]; row.xs = [0]; row.width = size.width; row.height = size.height
            } else {
                row.items.append(i); row.xs.append(x); row.width = x + size.width; row.height = max(row.height, size.height)
            }
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
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
