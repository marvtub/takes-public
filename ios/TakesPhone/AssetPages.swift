import AVFoundation
import SwiftUI

// The B-roll and Sound pages of the Files tab (2026-10-09), as the Mac's Assets switch has them
// (Broll.swift, Sounds.swift): add a library clip to the session, pick the song under the video,
// place a sound effect at a second. The Mac side is Sources/Takes/PhoneBoard.swift. Public.

/// Your B-roll library, by folder. A clip in this session has a check; tap it to add or take it out.
struct BrollPage: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    @State private var folders: [BrollFolder]?
    @State private var folder: String?
    @State private var failed: String?
    @State private var busy: String?
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    private var open: BrollFolder? { folders?.first { $0.folder == folder } ?? folders?.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let folders {
                    if folders.isEmpty {
                        MascotEmpty(title: "No B-roll yet", message: "Save a video to B-roll from its panel, or put clips in the library's broll folder on the Mac.")
                            .padding(.top, 30)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(folders) { f in
                                    ToggleChip(title: "\(f.name) \(f.clips.count)", on: f.folder == open?.folder) { folder = f.folder }
                                }
                            }
                        }
                        .arrive(0)
                        if let open {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Array(open.clips.enumerated()), id: \.element.id) { i, c in tile(c).arrive(min(i, 8) + 1) }
                            }
                            .id(open.folder)
                        }
                    }
                } else if let failed {
                    MascotEmpty(title: "Can't load the B-roll", message: failed, mood: .sorry).padding(.top, 30)
                }
            }
            .padding(16)
        }
        .refreshable { await load() }
        .task(id: sessionID) { await load() }
    }

    private func tile(_ c: BrollClip) -> some View {
        Button { toggle(c) } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: model.api.thumb(c.path, width: 400)) { $0.resizable().scaledToFill() } placeholder: { Palette.well }
                    .frame(height: 100).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.added ? Palette.accent : Palette.border, lineWidth: c.added ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        if c.added {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(Palette.accent, in: Circle()).padding(5)
                        }
                    }
                    .opacity(busy == c.path ? 0.5 : 1)
                Text(c.title).font(.inter(.footnote, .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.press)
        .disabled(busy != nil)
        .accessibilityLabel(c.added ? "\(c.title): in this session. Take it out" : "Add \(c.title) to this session")
    }

    private func toggle(_ c: BrollClip) {
        busy = c.path
        Task {
            defer { busy = nil }
            if let e = await model.tryAct("/api/broll", ["id": sessionID], ["action": c.added ? "remove" : "add", "path": c.path]) {
                model.toast = e
                return
            }
            model.toast = c.added ? "Removed from this session" : "Added to this session's broll/"
            await load()
        }
    }

    private func load() async {
        do {
            let data = try await model.act("/api/broll", ["id": sessionID], nil, method: "GET")
            let next = try API.decoder.decode([BrollFolder].self, from: data)
            if next != folders { folders = next }
            failed = nil
        } catch { failed = error.localizedDescription }
    }
}

/// The song under the video and the effects on it, then the library: Music and SFX, as the Mac's
/// Sound page. Tap a sound to hear it. Use and Add ask the chat to mix it into the video: Takes
/// never plays sound over a video (2026-10-09).
struct SoundPage: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let detail: SessionDetail
    @State private var data: Sounds?
    @State private var group = "Music"
    @State private var query = ""
    @State private var failed: String?
    @State private var playing: String?
    @State private var player: AVPlayer?
    @State private var placing: SoundItem?

    private var groups: [String] {
        let g = Set((data?.sounds ?? []).map(\.group))
        return ["Music", "SFX"].filter(g.contains) + g.subtracting(["Music", "SFX"]).sorted()
    }
    private var shown: [SoundItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (data?.sounds ?? []).filter { (groups.count < 2 || $0.group == group) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }
    }
    /// The session's videos an effect can go on: edits first, then takes.
    private var videos: [RemoteFile] {
        detail.files.filter(\.isVideo).sorted { ($0.folder == "edits" ? 0 : 1, $1.modified) < ($1.folder == "edits" ? 0 : 1, $0.modified) }
    }

    var body: some View {
        ScrollView {
            if let data {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Takes mixes music and effects into the video file. Tap Use and the chat makes a new version with it.")
                        .font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16).arrive(0)
                    library.arrive(1)
                }
                .padding(16)
            } else if let failed {
                MascotEmpty(title: "Can't load the sounds", message: failed, mood: .sorry).padding(.top, 30)
            }
        }
        .refreshable { await load() }
        .task(id: sessionID) { await load() }
        .onDisappear { player?.pause(); playing = nil }
        .overlay {
            if let p = placing {
                PlaceEffect(sessionID: sessionID, sound: p, videos: videos) { video, at in
                    await use(p, ["video": video, "at": String(format: "%.1f", at)])
                } close: { placing = nil }
            }
        }
        .animation(Brand.quick, value: placing)
    }

    private func heading(_ t: String) -> some View {
        Text(t.uppercased()).font(.inter(.caption, .semibold)).tracking(0.8).foregroundStyle(Palette.muted).padding(.bottom, 8)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.count > 1 {
                Segments(items: groups, selection: $group, title: { $0 })
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
                TextField("Find a sound", text: $query).font(.inter(.callout))
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if (data?.sounds ?? []).isEmpty {
                Text("No sounds in the library yet. Add them on the Mac's Sound page.").font(.inter(.subheadline)).foregroundStyle(Palette.muted)
            }
            LazyVStack(spacing: 1) {
                ForEach(shown) { s in row(s) }
            }
        }
    }

    private func row(_ s: SoundItem) -> some View {
        let effect = s.group.lowercased() != "music"
        return HStack(spacing: 10) {
            playButton(s.path, title: s.title)
            Text(s.title).font(.inter(.callout)).foregroundStyle(Palette.ink).lineLimit(1)
            Spacer()
            if effect {
                Button("Add") { placing = s }.buttonStyle(.pill(.soft, small: true)).disabled(videos.isEmpty)
            } else {
                Button("Use") { Task { await use(s) } }.buttonStyle(.pill(.soft, small: true))
            }
        }
        .padding(.horizontal, 6).frame(minHeight: 50)
    }

    private func playButton(_ path: String?, title: String) -> some View {
        let on = path != nil && playing == path
        return Button {
            guard let path else { return }
            if on { player?.pause(); playing = nil; return }
            let p = AVPlayer(url: model.api.media(path))
            p.volume = 1
            AVAudioSession.sharedInstance().use(.playback)
            player?.pause()
            player = p
            playing = path
            p.play()
        } label: {
            Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.accentInk : Palette.ink)
                .frame(width: 36, height: 36)
                .background(on ? Palette.accentSoft : Palette.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.press)
        .accessibilityLabel(on ? "Stop \(title)" : "Play \(title)")
    }

    /// Asks the session's chat to mix the sound in. `extra`: the video and second of an effect.
    @discardableResult
    private func use(_ s: SoundItem, _ extra: [String: String] = [:]) async -> String? {
        do {
            _ = try await model.act("/api/sounds", ["id": sessionID], ["action": "use", "file": s.rel].merging(extra) { $1 })
            player?.pause(); playing = nil
            model.toast = "Asked Takes to mix in \(s.title)"
            return nil
        } catch {
            model.toast = error.localizedDescription
            return error.localizedDescription
        }
    }

    private func load() async {
        do {
            let d = try await model.act("/api/sounds", ["id": sessionID], nil, method: "GET")
            let next = try API.decoder.decode(Sounds.self, from: d)
            if next != data { data = next }
            failed = nil
        } catch { failed = error.localizedDescription }
    }
}

/// Which video and which second an effect goes on. The Mac places it at the playhead; the phone
/// has no playhead, so the second is set here.
struct PlaceEffect: View {
    let sessionID: String
    let sound: SoundItem
    let videos: [RemoteFile]
    let place: (String, Double) async -> String?
    let close: () -> Void
    @State private var video: RemoteFile?
    @State private var at = 0.0
    @State private var busy = false
    @State private var failed: String?

    var body: some View {
        CardOverlay(close: close) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add \(sound.title)").font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                Text("On").font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(videos) { v in ToggleChip(title: v.name, on: v.id == video?.id) { video = v } }
                    }
                }
                Text("At").font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
                HStack(spacing: 10) {
                    step("minus", "Earlier") { at = max(0, at - 0.5) }
                    Text(String(format: "%d:%04.1f", Int(at) / 60, at.truncatingRemainder(dividingBy: 60)))
                        .font(.inter(.title3, .semibold)).monospacedDigit()
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    step("plus", "Later") { at = min(video?.duration ?? 3600, at + 0.5) }
                }
                if let failed { Text(failed).font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close).buttonStyle(.pill(.quiet, small: true))
                    Button(busy ? "Adding…" : "Add") {
                        guard let v = video?.rel(in: sessionID) else { return }
                        busy = true
                        Task {
                            if let e = await place(v, at) { failed = e; busy = false } else { close() }
                        }
                    }
                    .buttonStyle(.pill(.ink, small: true)).disabled(busy || video == nil)
                }
            }
        }
        .onAppear { video = videos.first }
    }

    private func step(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }
}
