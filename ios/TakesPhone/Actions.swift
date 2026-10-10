import AVKit
import SwiftUI

// The everyday actions on the phone (2026-10-09), as on the Mac: the session's More panel, a
// project's panel, a file's panel, clean voice, and the history of the script and the posts.
// The Mac side is Sources/Takes/PhoneActions.swift. Public.

/// Platforms a session can be marked published on: the Mac's Platforms.all.
let publishPlatforms = ["LinkedIn", "X", "YouTube", "Instagram", "TikTok"]

/// The session's More panel: the Mac's MorePanel, less what only a Mac can do (Finder, a path).
struct SessionMore: View {
    @EnvironmentObject var model: Model
    let session: Session
    let detail: SessionDetail?
    @Binding var open: Bool
    @Binding var confirm: Confirm?
    @Binding var ask: NameAsk?
    /// The session left this screen: to the Trash.
    let left: () -> Void
    let reload: () async -> Void
    @State private var moving = false
    @State private var publishing = false

    private var id: String { model.resolve(session.id) }
    private var projects: [String] { model.projects.isEmpty ? Array(Set(model.sessions.map(\.project))).sorted() : model.projects }
    private var title: String { detail?.session.title ?? session.title }
    private var project: String { detail?.session.project ?? session.project }
    private var archived: Bool { (detail?.session.archived ?? session.archived) == true }
    private var unstarred: Int { detail?.files.filter { $0.folder == "takes" && $0.keeper != true }.compactMap(\.take).reduce(into: Set<Int>()) { $0.insert($1) }.count ?? 0 }

    var body: some View {
        PanelRow(icon: "pencil", title: "Rename…") {
            close()
            ask = NameAsk(title: "Rename the session", name: title) { name in await rename(name) }
        }
        PanelDivider()
        PanelGroup(icon: "folder", title: "Move to project", open: $moving) {
            ForEach(projects.filter { $0 != project }, id: \.self) { p in
                PanelChoice(title: p) { close(); Task { await move(to: p) } }
            }
            if projects.filter({ $0 != project }).isEmpty {
                Text("No other project yet").font(.inter(.footnote)).foregroundStyle(Palette.faint).padding(.horizontal, 10).frame(height: 34)
            }
        }
        PanelGroup(icon: "paperplane", title: "Mark as published on", open: $publishing) {
            ForEach(publishPlatforms + [""], id: \.self) { p in
                let on = detail?.publishedOn?.contains(p) == true
                PanelChoice(title: p.isEmpty ? "Somewhere else" : p, checked: on) {
                    Task {
                        if let e = await model.tryAct("/api/published", ["id": id], ["platform": p, "on": on ? "0" : "1"]) { model.toast = e }
                        await reload()
                    }
                }
            }
        }
        PanelRow(icon: "star.slash", title: "Trash takes without a star", enabled: unstarred > 0,
                 detail: unstarred > 0 ? "\(unstarred)" : nil) {
            close()
            confirm = Confirm(title: "Trash \(unstarred) take\(unstarred == 1 ? "" : "s") without a star?",
                              message: "They go to the Trash on the Mac, so you can get them back.", button: "Move to Trash") {
                do {
                    let data = try await model.act("/api/trash", ["id": id], ["what": "unstarred"])
                    let n = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Int])?["trashed"] ?? 0
                    model.toast = "Moved \(n) take\(n == 1 ? "" : "s") to the Trash"
                    await reload()
                    return nil
                } catch { return error.localizedDescription }
            }
        }
        PanelRow(icon: "archivebox", title: archived ? "Unarchive" : "Archive") {
            close()
            Task { await model.archive(id, !archived); await reload() }
        }
        PanelDivider()
        PanelRow(icon: "trash", title: "Move session to Trash", danger: true) {
            close()
            confirm = Confirm(title: "Move “\(title)” to the Trash?",
                              message: "The session and its takes go to the Trash on the Mac, so you can get them back.",
                              button: "Move to Trash") {
                if let e = await model.tryAct("/api/trash", ["id": id], ["what": "session"]) { return e }
                model.gone(id)
                left()
                return nil
            }
        }
    }

    private func close() { withAnimation(Brand.quick) { open = false } }

    private func rename(_ name: String) async -> String? {
        do {
            let data = try await model.act("/api/rename", ["id": id], ["what": "session", "name": name])
            let s = try API.decoder.decode(Session.self, from: data)
            model.moved(id, to: s)
            await reload()
            return nil
        } catch { return error.localizedDescription }
    }

    private func move(to p: String) async {
        do {
            let data = try await model.act("/api/move", ["id": id], ["project": p])
            let s = try API.decoder.decode(Session.self, from: data)
            model.moved(id, to: s)
            model.toast = "Moved to \(p)"
            await reload()
        } catch { model.toast = error.localizedDescription }
    }
}

/// A project's panel in the list of videos: the Mac sidebar's project menu.
struct ProjectMore: View {
    @EnvironmentObject var model: Model
    let project: String
    @Binding var open: Bool
    @Binding var confirm: Confirm?
    @Binding var ask: NameAsk?

    var body: some View {
        PanelRow(icon: "pencil", title: "Rename…") {
            withAnimation(Brand.quick) { open = false }
            ask = NameAsk(title: "Rename the project", name: project) { name in
                if let e = await model.tryAct("/api/rename", [:], ["what": "project", "project": project, "name": name]) { return e }
                await model.refresh()
                return nil
            }
        }
        PanelDivider()
        PanelRow(icon: "trash", title: "Move project to Trash", danger: true) {
            withAnimation(Brand.quick) { open = false }
            let n = model.sessions.filter { $0.project == project }.count
            confirm = Confirm(title: "Move “\(project)” to the Trash?",
                              message: "Its \(n) session\(n == 1 ? "" : "s") go to the Trash on the Mac, so you can get them back.",
                              button: "Move to Trash") {
                if let e = await model.tryAct("/api/trash", [:], ["what": "project", "project": project]) { return e }
                await model.refresh()
                return nil
            }
        }
    }
}

/// A file's panel in the viewer: the Mac's Assets menu, less Finder.
struct FileMore: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let sessionID: String
    @Binding var open: Bool
    @Binding var confirm: Confirm?
    @Binding var ask: NameAsk?
    @Binding var voice: Bool
    let done: () -> Void
    var toChat: (() -> Void)? = nil
    @State private var saving = false
    @State private var folders: [String] = []

    private var id: String { model.resolve(sessionID) }

    var body: some View {
        // The Mac's Change Image… and Make Final (Assets.swift): the ask goes to the chat.
        if let toChat, let change = file.change {
            PanelRow(icon: "wand.and.stars", title: "Change image…") {
                withAnimation(Brand.quick) { open = false }
                UserDefaults.standard.set(change, forKey: "chatDraft." + sessionID)
                toChat()
            }
            if let final = file.final {
                PanelRow(icon: "sparkles", title: "Make Final") {
                    withAnimation(Brand.quick) { open = false }
                    Task { if await model.say(final, in: sessionID) { toChat() } else { model.toast = "The chat did not take it. Try again." } }
                }
            }
            PanelDivider()
        }
        if file.isVideo {
            PanelGroup(icon: "film.stack", title: "Save to B-roll", open: $saving) {
                ForEach(folders.isEmpty ? ["Clips"] : folders, id: \.self) { f in
                    PanelChoice(title: f.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)) {
                        withAnimation(Brand.quick) { open = false }
                        Task {
                            if let e = await model.tryAct("/api/broll", ["id": id], ["action": "save", "path": file.path, "folder": f]) { model.toast = e }
                            else { model.toast = "Saving it to B-roll. Gemini names it in about a minute" }
                        }
                    }
                }
            }
            .task {
                guard let d = try? await model.act("/api/broll", ["id": id], nil, method: "GET"),
                      let lib = try? API.decoder.decode([BrollFolder].self, from: d) else { return }
                folders = lib.map(\.folder)
            }
        }
        if let n = file.take {
            PanelRow(icon: "pencil", title: "Rename take…") {
                withAnimation(Brand.quick) { open = false }
                let shown = file.name.hasPrefix("Take ") ? "" : file.name
                ask = NameAsk(title: "Name take \(n)", name: shown) { name in
                    await model.tryAct("/api/rename", ["id": id], ["what": "take", "take": String(n), "name": name])
                }
            }
            PanelRow(icon: "waveform", title: "Clean voice…") { withAnimation(Brand.quick) { open = false }; voice = true }
            PanelDivider()
            PanelRow(icon: "trash", title: "Move take \(n) to Trash", danger: true) {
                withAnimation(Brand.quick) { open = false }
                confirm = Confirm(title: "Move take \(n) to the Trash?",
                                  message: "Its camera and screen files go to the Trash on the Mac, so you can get them back.",
                                  button: "Move to Trash") {
                    if let e = await model.tryAct("/api/trash", ["id": id], ["what": "take", "take": String(n)]) { return e }
                    done()
                    return nil
                }
            }
        } else {
            PanelRow(icon: "trash", title: "Move to Trash", danger: true) {
                withAnimation(Brand.quick) { open = false }
                confirm = Confirm(title: "Move \(file.name) to the Trash?",
                                  message: "It goes to the Trash on the Mac, so you can get it back.", button: "Move to Trash") {
                    if let e = await model.tryAct("/api/trash", ["id": id], ["what": "file", "path": file.path]) { return e }
                    done()
                    return nil
                }
            }
        }
    }
}

// MARK: - Clean voice

/// The Mac's Voice panel: clean the take's voice, how strong, how loud, clean again from the raw
/// take. On the phone the clean voice plays from the blended file the edits use.
struct VoiceSheet: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let sessionID: String
    let close: () -> Void
    @State private var v: VoiceState?
    @State private var failed: String?
    @State private var strength = 1.0
    @State private var player: AVPlayer?

    private var query: [String: String] {
        ["id": model.resolve(sessionID), "take": String(file.take ?? 0), "kind": file.name.contains("screen") || file.path.hasSuffix("-screen.mov") ? "screen" : "camera"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetBar(title: "Clean voice", cancel: "Done", close: close) { EmptyView() }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean voice").font(.nunito(size: 20, relativeTo: .title3))
                    Text("Sounds like a proper mic").font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                }
                if let v {
                    switch v.state {
                    case "running": running(v)
                    case "done": settings(v)
                    case "failed": failedView(v)
                    default: intro(v)
                    }
                }
                if let failed { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
            }
            .padding(.horizontal, 20)
            .arrive(0)
            Spacer()
        }
        .background(Palette.paper.ignoresSafeArea())
        .task { await load() }
        .task(id: v?.state) {
            // While it cleans, ask again every few seconds.
            while v?.state == "running" {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
        .onDisappear { player?.pause() }
    }

    private func intro(_ v: VoiceState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Removes room echo, noise, clipping and hum, then levels your voice. The take itself stays as it is.")
                .font(.inter(.callout)).fixedSize(horizontal: false, vertical: true)
            Button("Clean voice") { Task { await send(["action": "clean"]) } }.buttonStyle(.pill(.ink))
            Text("About \(Self.clock(v.estimate)). It runs on the Mac.").font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.muted)
        }
    }

    private func running(_ v: VoiceState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = v.started.map { ctx.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                Bar(value: min(0.95, elapsed / max(v.estimate, 1)))
                Text("Cleaning · \(Self.clock(elapsed)) of about \(Self.clock(v.estimate))")
                    .font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.muted)
            }
        }
    }

    private func settings(_ v: VoiceState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Use the clean voice").font(.inter(.callout, .medium))
                Spacer()
                Switch(on: v.on) { on in Task { await send(["action": "set", "on": on ? "1" : "0"]) } }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Strength").font(.inter(.subheadline, .medium))
                    Spacer()
                    Text("\(Int((strength * 100).rounded())) %").font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.muted)
                }
                Track(value: $strength) { Task { await send(["action": "set", "strength": String(format: "%.2f", strength)]) } }
            }
            .disabled(!v.on).opacity(v.on ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 6) {
                Text("Loudness").font(.inter(.subheadline, .medium))
                Segments(items: [false, true], selection: Binding(get: { v.quiet }, set: { q in
                    Task { await send(["action": "set", "loudness": q ? "quiet" : "normal"]) }
                }), title: { $0 ? "Quiet · -18 LUFS" : "Normal · -14 LUFS" })
            }
            .disabled(!v.on).opacity(v.on ? 1 : 0.5)
            if let f = v.file {
                Button {
                    if let player, player.timeControlStatus == .playing { player.pause() } else {
                        let p = AVPlayer(url: model.api.media(f))
                        player = p
                        AVAudioSession.sharedInstance().use(.playback)
                        p.play()
                    }
                } label: { Label("Hear the clean voice", systemImage: "play.fill") }
                .buttonStyle(.pill(.soft, small: true))
            }
            Text(v.summary).font(.inter(.footnote)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let e = v.error { Text(e).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
            Button("Clean again from the raw take") { Task { await send(["action": "clean"]) } }
                .buttonStyle(.plain).font(.inter(.subheadline, .medium)).foregroundStyle(Palette.accent)
        }
    }

    private func failedView(_ v: VoiceState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(v.error ?? "The cleanup failed.").font(.inter(.callout)).foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await send(["action": "clean"]) } }.buttonStyle(.pill(.ink))
        }
    }

    private func load() async {
        do {
            let data = try await model.act("/api/voice", query, nil, method: "GET")
            let next = try API.decoder.decode(VoiceState.self, from: data)
            if next != v { withAnimation(Brand.quick) { v = next }; strength = next.strength }
            failed = nil
        } catch { failed = error.localizedDescription }
    }

    private func send(_ body: [String: String]) async {
        var b = body
        b["take"] = query["take"]
        b["kind"] = query["kind"]
        do {
            let data = try await model.act("/api/voice", ["id": query["id"] ?? ""], b)
            let next = try API.decoder.decode(VoiceState.self, from: data)
            withAnimation(Brand.quick) { v = next }
            failed = nil
        } catch { failed = error.localizedDescription }
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Controls in Takes's own style

/// A thin progress line in the accent.
struct Bar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well)
                Capsule().fill(Palette.accent).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 1), value: value)
    }
}

/// On and off, drawn like the Feedback board's RuleSwitch: a capsule with a dot.
struct Switch: View {
    let on: Bool
    let set: (Bool) -> Void
    var body: some View {
        Button { Brand.select(); set(!on) } label: {
            Capsule().fill(on ? Palette.accent : Palette.well)
                .frame(width: 44, height: 26)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Palette.paper).frame(width: 20, height: 20).padding(3)
                        .shadow(color: Palette.shadow, radius: 1, y: 1)
                }
                .animation(Brand.quick, value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A slider drawn in Takes's style: a well, the accent up to the knob. `done` runs on release.
struct Track: View {
    @Binding var value: Double
    let done: () -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well).frame(height: 6)
                Capsule().fill(Palette.accent).frame(width: max(6, w * value), height: 6)
                Circle().fill(Palette.paper).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Palette.border))
                    .shadow(color: Palette.shadow, radius: 2, y: 1)
                    .offset(x: (w - 24) * value)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in value = max(0, min(1, (g.location.x - 12) / max(1, w - 24))) }
                .onEnded { _ in done() })
        }
        .frame(height: 28)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

// MARK: - History

/// Saved versions, newest first, as the Mac's history sheet: tap one to read it, then Restore.
struct HistorySheet: View {
    @EnvironmentObject var model: Model
    let title: String
    let subtitle: String
    let empty: String
    let load: () async throws -> [Version]
    let restore: (Version) async -> String?
    let close: () -> Void
    @State private var versions: [Version]?
    @State private var picked: Version?
    @State private var failed: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: picked == nil ? title : "Saved version", cancel: picked == nil ? "Done" : "Back",
                     close: { if picked != nil { withAnimation(Brand.quick) { picked = nil } } else { close() } }) { EmptyView() }
            if let picked {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        row(picked, open: true).allowsHitTesting(false)
                        Text(picked.text).font(.inter(.body)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let failed { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
                    Text("Restoring saves the current text as a version first, so nothing is lost.")
                        .font(.inter(.footnote)).foregroundStyle(Palette.muted)
                    Button(busy ? "Restoring…" : "Restore This Version") {
                        busy = true
                        Task {
                            if let e = await restore(picked) { failed = e; busy = false } else { close() }
                        }
                    }
                    .buttonStyle(.pill(.ink, wide: true)).disabled(busy)
                }
                .padding(16)
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
                .transition(.opacity)
            } else if let versions {
                if versions.isEmpty {
                    MascotEmpty(title: "No versions yet", message: empty).frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in row(v).arrive(min(i, 6)) }
                        }
                        .padding(8)
                    }
                }
            } else if let failed {
                MascotEmpty(title: "Can't load the history", message: failed, mood: .sorry).frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .overlay(alignment: .top) { if picked == nil { Text(subtitle).font(.inter(.footnote)).foregroundStyle(Palette.faint).lineLimit(1).padding(.top, 50) } }
        .task {
            do { versions = try await load() } catch { failed = error.localizedDescription }
        }
    }

    private func row(_ v: Version, open: Bool = false) -> some View {
        Button { withAnimation(Brand.quick) { picked = v; failed = nil } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: v.author == "claude" ? "sparkles" : "person.fill").font(.inter(.caption)).foregroundStyle(Palette.accent)
                    Text(v.note.isEmpty ? "Saved" : v.note).font(.inter(.callout, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                }
                Text("\(Self.when(v.created)) · \(v.draftName)").font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.muted)
                if !open {
                    Text(v.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.inter(.footnote)).foregroundStyle(Palette.faint).lineLimit(2)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
    }

    /// "Today 2:10 PM", "Yesterday 9:00 AM", "Oct 7 5:23 PM": the Mac's SessionList.when.
    static func when(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
}

// MARK: - Arrival

extension View {
    /// The Mac's page motion (PageMotion.swift): parts rise in from a blur, in order. No spinner.
    func arrive(_ step: Int) -> some View { modifier(Arrive(step: step)) }
}

private struct Arrive: ViewModifier {
    let step: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .animation(.smooth(duration: 0.6).delay(Double(step) * 0.06)) {
                $0.opacity(shown ? 1 : 0)
                    .blur(radius: shown || reduceMotion ? 0 : 8)
                    .offset(y: shown || reduceMotion ? 0 : 12)
            }
            .onAppear { shown = true }
    }
}

// MARK: - Draft bar

/// Main and the variants as chips, + for a copy, the history: the Mac's DraftBar and PostDraftBar,
/// which look the same. Under the chips, the variant on show: its note, rename, delete, Use as Main.
struct DraftBar: View {
    let variants: [PostVariant]
    @Binding var draft: String
    /// The script's favorite ("main" or a slug); nil for a post, which has none.
    var favorite: String? = nil
    let history: Int
    let busy: Bool
    var canNew = true
    let new: () -> Void
    let showHistory: () -> Void
    /// The Edit button, when the bar holds it (the Script tab).
    var edit: (label: String, run: () -> Void)? = nil
    let rename: (PostVariant) -> Void
    let delete: (PostVariant) -> Void
    let promote: (PostVariant) -> Void
    var toggleFavorite: ((String) -> Void)? = nil

    private var variant: PostVariant? { variants.first { $0.slug == draft } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("main", "Main", author: "")
                        ForEach(variants) { chip($0.slug, $0.name, author: $0.author) }
                        Button { Brand.select(); new() } label: {
                            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.press).disabled(busy || !canNew)
                        .accessibilityLabel("New variant")
                    }
                }
                Button { showHistory() } label: {
                    Label("\(history)", systemImage: "clock.arrow.circlepath")
                        .font(.inter(.footnote, .medium).monospacedDigit()).foregroundStyle(Palette.muted)
                        .frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel(favorite == nil ? "Post history" : "Script history")
                if let edit {
                    Button(action: edit.run) { Label(edit.label, systemImage: "pencil") }
                        .buttonStyle(.pill(.soft, small: true))
                }
            }
            if let variant {
                HStack(spacing: 8) {
                    Image(systemName: variant.author == "claude" ? "sparkles" : "person.fill")
                    Text(variant.note.isEmpty ? "Variant\(variant.author.isEmpty ? "" : " by \(variant.author == "claude" ? "Takes" : variant.author.capitalized)")" : variant.note)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button { Brand.select(); rename(variant) } label: { Image(systemName: "pencil").frame(width: 30, height: 30) }
                        .buttonStyle(.press).accessibilityLabel("Rename the variant")
                    Button { Brand.select(); delete(variant) } label: { Image(systemName: "trash").frame(width: 30, height: 30) }
                        .buttonStyle(.press).accessibilityLabel("Delete the variant")
                    Button("Use as Main") { promote(variant) }
                        .buttonStyle(.pill(.ink, small: true)).disabled(busy)
                }
                .font(.inter(.footnote)).foregroundStyle(Palette.muted)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(Brand.spring, value: draft)
    }

    private func chip(_ slug: String, _ name: String, author: String) -> some View {
        let on = draft == slug
        let fav = favorite == slug
        return Button { Brand.select(); withAnimation(Brand.spring) { draft = slug } } label: {
            HStack(spacing: 4) {
                if fav { Image(systemName: "star.fill").font(.inter(.caption2)).foregroundStyle(Palette.accent) }
                if author == "claude" { Image(systemName: "sparkles").font(.inter(.caption2)) }
                Text(name).lineLimit(1)
            }
            .font(.inter(.subheadline, on ? .semibold : .medium))
            .foregroundStyle(on ? Palette.accentInk : Palette.muted)
            .padding(.horizontal, 12).frame(height: 32)
            .background(on ? Palette.accentSoft : Palette.well, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A long press marks the favorite, as the Mac's Mark as Favorite.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard let toggleFavorite else { return }
            Brand.tap(.medium)
            toggleFavorite(slug)
        })
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: fav ? "Remove favorite" : "Mark as favorite") { toggleFavorite?(slug) }
    }
}
