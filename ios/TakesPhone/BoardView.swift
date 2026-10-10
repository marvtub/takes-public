import AVFoundation
import Combine
import SwiftUI

// The storyboard on the phone, laid out like the Mac's Storyboard tab (2026-10-04): a strip of small
// cards (Hook, Main, End) and the picked shot big under it. Record a take per shot with the red dot,
// see it land under the shot, and leave a note on the shot for Takes.

struct BoardView: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let detail: SessionDetail
    let show: (RemoteFile) -> Void
    let record: (Shot) -> Void
    let reload: () async -> Void
    let toChat: () -> Void
    @State private var picked: String?
    @Namespace private var ns
    @State private var asked = false
    /// Width over height read off each picture, by its path: a Mac from before 2026-10-05 sends no shape.
    @State private var measured: [String: Double] = [:]
    @Environment(\.scenePhase) private var scene

    private static let sections = [("hook", "Hook"), ("main", "Main"), ("end", "End")]

    /// The shots, each with its shape: from the Mac, else from its picture, else from the other
    /// sketches (a sketch still drawing has the storyboard's format too).
    private var shots: [Shot] {
        let all = detail.storyboard ?? []
        guard all.contains(where: { $0.ratio == nil }) else { return all }
        let sketches = all.compactMap { s in s.image.flatMap { Shot.isClip($0) ? nil : measured[$0] } }
        let format = sketches.first ?? all.compactMap { $0.image.flatMap { measured[$0] } }.first
        return all.map { s in
            var s = s
            if s.ratio == nil { s.ratio = s.image.flatMap { measured[$0] } ?? format }
            return s
        }
    }

    /// Reads the shape of each picture the Mac sent no shape for, from its small thumbnail.
    private func measure() async {
        for s in detail.storyboard ?? [] where s.ratio == nil {
            guard let p = s.image, measured[p] == nil,
                  let img = await ImageCache.shared.load(model.api.thumb(p, width: 160), maxPixels: 1600),
                  img.size.width > 0, img.size.height > 0 else { continue }
            measured[p] = img.size.width / img.size.height
        }
    }

    /// Camera takes per shot, oldest first.
    private var takes: [String: [RemoteFile]] {
        Dictionary(grouping: detail.files.filter { $0.folder == "takes" && $0.shot != nil }, by: { $0.shot! })
            .mapValues { $0.sorted { ($0.take ?? 0) < ($1.take ?? 0) } }
    }

    var body: some View {
        Group {
            if shots.isEmpty { empty } else { board }
        }
        // Sketches land in the background, and a take lands after its upload: look again now and then.
        // Only while the app is on screen, and fast only while sketches are still drawing.
        .task(id: sessionID) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(shots.contains { $0.image == nil && $0.error == nil } ? 3 : 10))
                if scene == .active { await reload() }
            }
        }
        .task(id: (detail.storyboard ?? []).compactMap(\.image)) { await measure() }
        .onReceive(model.uploads.$items.map { [sessionID] in $0.filter { $0.session == sessionID && $0.done }.count }.removeDuplicates().dropFirst()) { _ in
            Task { await reload() }
        }
    }

    /// The Mac's layout (2026-10-04): every shot as a small card in a strip, and the picked shot big
    /// under it. Swipe the big shot, or tap a card, to move.
    private var board: some View {
        let takes = self.takes
        let current = currentID(takes)
        return VStack(spacing: 0) {
            header(takes)
            strip(takes, current: current)
            TabView(selection: Binding(get: { current ?? "" }, set: { id in withAnimation(Brand.spring) { picked = id } })) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { i, shot in
                    ShotPage(sessionID: sessionID, shot: shot, number: i + 1, count: shots.count,
                             takes: takes[shot.id] ?? [], on: shot.id == current, show: show,
                             record: { record(shot) }, reload: reload, toChat: toChat)
                        .tag(shot.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: current) { Brand.select() }
        }
    }

    /// The shot the user picked, else the first one with no take yet: where he left off.
    private func currentID(_ takes: [String: [RemoteFile]]) -> String? {
        if let picked, shots.contains(where: { $0.id == picked }) { return picked }
        return (shots.first { takes[$0.id] == nil } ?? shots.first)?.id
    }

    private func header(_ takes: [String: [RemoteFile]]) -> some View {
        let done = shots.filter { takes[$0.id] != nil }.count
        let drawing = shots.filter { $0.image == nil && $0.error == nil }.count
        return HStack(spacing: 6) {
            Text("\(shots.count) shots").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.ink)
            Text("·").foregroundStyle(Palette.faint)
            Text("about \(Self.clock(shots.reduce(0) { $0 + $1.seconds }))").font(.inter(.footnote)).foregroundStyle(Palette.muted)
            if done > 0 {
                Text("·").foregroundStyle(Palette.faint)
                Text("\(done) recorded").font(.inter(.footnote)).foregroundStyle(Palette.live)
            }
            Spacer(minLength: 0)
            if drawing > 0 {
                WorkingDots(color: Palette.faint)
                Text("Drawing \(drawing)").font(.inter(.caption)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }

    /// Every shot as a small card, in order, with the section names above their first card.
    private func strip(_ takes: [String: [RemoteFile]], current: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(Self.sections, id: \.0) { key, title in
                        let row = shots.filter { $0.section == key }
                        if !row.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(title.uppercased()).font(.inter(size: 10, .semibold, relativeTo: .caption2))
                                    .tracking(0.4).foregroundStyle(Palette.faint)
                                HStack(spacing: 6) {
                                    ForEach(row) { shot in
                                        Button { withAnimation(Brand.spring) { picked = shot.id } } label: {
                                            ShotThumb(shot: shot, recorded: takes[shot.id] != nil,
                                                      noted: shot.comments.contains(where: \.open),
                                                      on: shot.id == current, ns: ns)
                                        }
                                        .buttonStyle(.press)
                                        .id(shot.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                guard let id else { return }
                withAnimation(Brand.spring) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private var empty: some View {
        MascotEmpty(title: "No storyboard yet", message: "Takes writes the script and sketches each shot, so you see how to film it.") {
            Button("Storyboard this video") {
                asked = true
                Task {
                    _ = await model.say("Storyboard this video. Use the storyboard skill.", in: sessionID, from: "Board")
                    toChat()
                }
            }
            .buttonStyle(.pill()).disabled(asked)
        }
        .frame(maxHeight: .infinity)
    }

    static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    static func sectionTitle(_ key: String) -> String { sections.first { $0.0 == key }?.1 ?? key.capitalized }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "MG": return Palette.accent
        case "B-ROLL", "BROLL": return Color(red: 0.545, green: 0.361, blue: 0.965)
        case "SCREEN": return Palette.ink
        case "WALK", "OUTSIDE": return Palette.live
        default: return Palette.ink
        }
    }
}

/// The kind of a shot (DESK, MG, SCREEN…) as a soft tinted chip, readable in light and dark.
struct KindChip: View {
    var kind: String

    var body: some View {
        let color = BoardView.color(kind)
        Text(kind).font(.inter(size: 10, .bold, relativeTo: .caption2)).tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// One small card in the strip: the sketch, a green check once recorded, a blue dot for an open note.
private struct ShotThumb: View {
    @EnvironmentObject var model: Model
    let shot: Shot
    let recorded: Bool
    let noted: Bool
    let on: Bool
    let ns: Namespace.ID

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(Palette.paper)
            if let image = shot.image {
                RemoteImage(url: model.api.thumb(image, width: 160)) { $0.resizable().scaledToFill() } placeholder: { Palette.well }
            } else if shot.error != nil {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warn)
            } else {
                WorkingDots(color: Palette.faint)
            }
        }
        // The video's shape (16:9, 9:16…): the same height for every card, as on the Mac.
        .frame(width: min(133, max(42, 75 * shot.shape)), height: 75)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.border))
        .overlay(alignment: .topTrailing) {
            if recorded {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Palette.live, in: Circle()).padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if noted { Circle().fill(Palette.accent).frame(width: 8, height: 8).padding(5) }
        }
        .overlay {
            if on {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent, lineWidth: 2)
                    .padding(-3)
                    .matchedGeometryEffect(id: "shot", in: ns)
            }
        }
        .scaleEffect(on ? 1.06 : 1)
        .opacity(on ? 1 : 0.72)
        .padding(.vertical, 3)
        .accessibilityLabel("Shot \(shot.kind.lowercased())\(recorded ? ", recorded" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The picked shot, big: its frame, what to say, how to film it, the takes and the notes for Takes.
private struct ShotPage: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let shot: Shot
    let number: Int
    let count: Int
    let takes: [RemoteFile]
    let on: Bool
    let show: (RemoteFile) -> Void
    let record: () -> Void
    let reload: () async -> Void
    let toChat: () -> Void
    @AppStorage("storyboardSound") private var sound = false
    @State private var showHow = false
    @State private var showResolved = false
    /// A variant tried in the frame, not the one in the video (2026-10-09, as the Mac's letters).
    @State private var tried: String?
    /// The take whose card is open, and what went wrong.
    @State private var takeCard: RemoteFile?
    @State private var failed: String?

    private var section: String { BoardView.sectionTitle(shot.section) }
    /// The picture or clip on show: the one tried, else the one in the video.
    private var shown: String? { tried ?? shot.image }
    private var clip: String? { shown.flatMap { Shot.isClip($0) ? $0 : nil } }
    private var variants: [String] { shot.variants ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                frame
                if variants.count > 1 { letters }
                if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(Palette.danger) }
                top
                if !shot.say.isEmpty {
                    Text(shot.say).font(.nunito(size: 23, relativeTo: .title2)).foregroundStyle(Palette.ink)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !shot.how.isEmpty { how }
                if !takes.isEmpty { takeStrip }
                ShotNotes(sessionID: sessionID, shot: shot, showResolved: $showResolved, reload: reload)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: shot.video) { tried = nil }
        .overlay {
            if let t = takeCard {
                TakeCard(sessionID: sessionID, take: t, play: { takeCard = nil; show(t) }, close: { takeCard = nil }, reload: reload)
                    .id(t.id)
            }
        }
        .animation(Brand.quick, value: takeCard?.id)
    }

    /// A B C… under the frame: tap one to try it, then use it or go back. A GPT Image draft also
    /// gets Make Final, which asks Takes for the 4K Nano Banana 2.1 final (the Mac's tryingButtons).
    private var letters: some View {
        let inVideo = shot.video ?? shot.image
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(variants.enumerated()), id: \.element) { i, v in
                    let on = v == shown
                    let picked = v == inVideo
                    Button { Brand.select(); withAnimation(Brand.quick) { tried = v == inVideo ? nil : v } } label: {
                        HStack(spacing: 4) {
                            if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
                            Text(Self.letter(i))
                        }
                        .font(.inter(.subheadline, on ? .semibold : .medium)).monospacedDigit()
                        .foregroundStyle(on ? Palette.accentInk : picked ? Palette.accent : Palette.muted)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(on ? Palette.accentSoft : Palette.well, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(picked ? "\(Self.letter(i)): in the video" : "Try \(Self.letter(i))")
                }
                Spacer(minLength: 0)
                if shot.generating == true {
                    HStack(spacing: 6) { WorkingDots(color: Palette.muted); Text("Making").font(.inter(.footnote)) }.foregroundStyle(Palette.muted)
                }
            }
            let draft = shown.flatMap { shot.finals?[$0] }
            if tried != nil || draft != nil {
                HStack(spacing: 10) {
                    if let tried, let i = variants.firstIndex(of: tried) {
                        Button("Use \(Self.letter(i)) in the video") { pick(tried) }.buttonStyle(.pill(.ink, small: true))
                    }
                    if let draft {
                        Button("Make Final") { final(draft) }.buttonStyle(.pill(.soft, small: true))
                    }
                    if tried != nil, let v = inVideo, let i = variants.firstIndex(of: v) {
                        Button("Back to \(Self.letter(i))") { withAnimation(Brand.quick) { tried = nil } }
                            .buttonStyle(.plain).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func letter(_ i: Int) -> String { i < 26 ? String(UnicodeScalar(65 + i)!) : "\(i + 1)" }

    private func pick(_ path: String) {
        Task {
            if let e = await model.tryAct("/api/shot", ["id": sessionID], ["action": "pick", "shot": shot.id, "path": path]) { failed = e; return }
            failed = nil
            Brand.select()
            await reload()
        }
    }

    /// The Mac sends the ask in the chat and opens it; so does the phone.
    private func final(_ ask: String) {
        Task {
            if await model.say(ask, in: sessionID) { toChat() } else { failed = "The chat did not take it. Try again." }
        }
    }

    private var top: some View {
        HStack(spacing: 8) {
            Text("\(section) · \(number) of \(count)").font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
            KindChip(kind: shot.kind)
            Text("\(BoardView.clock(shot.start)) · \(Int(shot.seconds.rounded())) s")
                .font(.inter(.caption)).monospacedDigit().foregroundStyle(Palette.faint)
            Spacer(minLength: 0)
            Button(action: record) {
                Circle().fill(.white).frame(width: 13, height: 13)
                    .frame(width: 40, height: 40)
                    .background(Palette.danger, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.press)
            .accessibilityLabel(takes.isEmpty ? "Record this shot" : "Record this shot again")
        }
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Brand.spring) { showHow.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showHow ? 90 : 0))
                    Text(shot.howTitle).font(.inter(.footnote, .medium))
                }
                .foregroundStyle(Palette.muted)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showHow {
                Text(shot.how).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    /// 264 × 330 for a 4:5 shot; a wide one takes the screen's width, a tall one stays as high.
    private var frameSize: CGSize {
        let w = min(340, 330 * shot.shape)
        return CGSize(width: w, height: w / shot.shape)
    }

    private var frame: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        // Small enough that the line to say shows under it without a scroll.
        return ZStack {
            shape.fill(Palette.paper)
            if let image = shown {
                RemoteImage(url: model.api.thumb(image, width: 900)) { $0.resizable().scaledToFill() } placeholder: { Palette.paper }
            } else if let err = shot.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warn)
                    Text(err).font(.inter(.caption)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }
                .padding(20)
            } else {
                VStack(spacing: 8) { WorkingDots(); Text("Drawing").font(.inter(.caption, .medium)).foregroundStyle(Palette.muted) }
            }
            // The clip plays on its own, muted and looping, while its page shows.
            if let clip, on { ClipLoop(url: model.api.media(clip), sound: sound) }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.border))
            .shadow(color: Palette.shadow, radius: 14, y: 6)
            .overlay(alignment: .topTrailing) {
                if takes.contains(where: { $0.keeper == true }) {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(.yellow)
                        .padding(7).background(.black.opacity(0.55), in: Circle()).padding(10)
                        .accessibilityLabel("This shot has a keeper take")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip != nil {
                    Button { sound.toggle() } label: {
                        Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.55), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.press)
                    .padding(12)
                    .accessibilityLabel(sound ? "Mute the clips" : "Play the clips with sound")
                }
            }
            .frame(maxWidth: .infinity)
    }

    private var takeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(takes.count) take\(takes.count == 1 ? "" : "s")").font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(takes) { t in
                        Button { Brand.select(); takeCard = t } label: {
                            ZStack(alignment: .bottomLeading) {
                                RemoteImage(url: model.api.thumb(t.path, width: 200)) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                                HStack(spacing: 2) {
                                    if t.keeper == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                    Text("\(t.take ?? 0)")
                                }
                                .font(.inter(size: 10, .semibold, relativeTo: .caption2)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(4)
                            }
                            .frame(width: 64, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) { if let c = t.cut { CutBadge(cut: c).padding(4) } }
                        }
                        .buttonStyle(.press)
                        .accessibilityLabel("Take \(t.take ?? 0)")
                    }
                }
            }
        }
    }
}

/// The notes on one shot for Takes, and one rounded field with a mic and a send arrow, as on the Mac.
private struct ShotNotes: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let shot: Shot
    @Binding var showResolved: Bool
    let reload: () async -> Void
    @State private var draft = ""
    @State private var sending = false
    @State private var voice = VoiceNote()
    @FocusState private var typing: Bool

    private var open: [Comment] { shot.comments.filter(\.open) }
    private var resolved: [Comment] { shot.comments.filter { !$0.open } }
    private var canSend: Bool { voice.recording || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(open) { note($0) }
            if showResolved { ForEach(resolved) { note($0) } }
            field
            if !resolved.isEmpty {
                Button { withAnimation(Brand.spring) { showResolved.toggle() } } label: {
                    Text(showResolved ? "Hide resolved" : "\(resolved.count) resolved")
                        .font(.inter(.caption, .medium)).foregroundStyle(Palette.faint)
                        .padding(.vertical, 4).padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { voice.cancel() }
    }

    private func note(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.text).font(.inter(.subheadline)).foregroundStyle(c.open ? Palette.ink : Palette.faint)
            ForEach(Array((c.replies ?? []).enumerated()), id: \.offset) { _, r in
                Text((r.by == "claude" ? "Takes: " : "You: ") + r.text).font(.inter(.footnote)).foregroundStyle(Palette.muted)
            }
            if !c.open { Text("Resolved").font(.inter(.caption, .semibold)).foregroundStyle(Palette.live) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.open ? Palette.accentSoft : Palette.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if voice.recording {
                Button { voice.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(width: 28, height: 32)
                }
                .accessibilityLabel("Discard recording")
                VoiceBars(levels: voice.levels).foregroundStyle(Palette.ink).frame(height: 32)
                Spacer(minLength: 0)
            } else {
                TextField("Note for Takes: what should change?", text: $draft, axis: .vertical)
                    .font(.inter(.callout)).foregroundStyle(Palette.ink)
                    .lineLimit(1...6).focused($typing)
                    .padding(.vertical, 7)
                    .onSubmit(send)
                Button { Task { await toggleVoice() } } label: {
                    Image(systemName: "mic").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Voice note")
            }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Palette.paper : Palette.faint)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Palette.ink : Palette.well, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.press)
            .disabled(!canSend || sending)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(typing || voice.recording ? Palette.accent.opacity(0.5) : Palette.border, lineWidth: typing || voice.recording ? 1.5 : 1))
        .animation(Brand.quick, value: typing)
        .animation(Brand.quick, value: voice.recording)
    }

    /// Stopping puts what was said into the field, after anything already typed, to check.
    private func toggleVoice() async {
        guard voice.recording else {
            typing = false
            await voice.start()
            if let e = voice.error { model.error = e }
            return
        }
        let said = await voice.stop()
        guard !said.isEmpty else { return }
        let have = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = have.isEmpty ? said : have + " " + said
    }

    /// The arrow while recording stops, adds the words and sends in one tap.
    private func send() {
        Task {
            if voice.recording { await toggleVoice() }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            sending = true
            draft = ""
            if await model.comment(sessionID, shot: shot.id, text: text) == nil { draft = text }
            sending = false
            typing = false
            await reload()
        }
    }
}

/// A clip that loops on its own, filling its frame. Muted, it mixes with your music.
struct ClipLoop: UIViewRepresentable {
    let url: URL
    var sound = false
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    final class Box: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> Box {
        let v = Box()
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player = v.player
        v.player.isMuted = !sound
        AVAudioSession.sharedInstance().use(sound ? .playback : .ambient, sound ? [] : .mixWithOthers)
        v.looper = AVPlayerLooper(player: v.player, templateItem: AVPlayerItem(url: url))
        v.player.play()
        return v
    }

    func updateUIView(_ v: Box, context: Context) {
        guard v.player.isMuted == sound else { return }
        v.player.isMuted = !sound
        AVAudioSession.sharedInstance().use(sound ? .playback : .ambient, sound ? [] : .mixWithOthers)
    }

    static func dismantleUIView(_ v: Box, coordinator: ()) {
        v.player.pause()
        v.looper = nil
    }
}

/// The scissors on a take: grey for Gemini's first guess, green once Takes checked it, orange when
/// it failed or not every word is clean. The Mac's TakeThumb badge.
struct CutBadge: View {
    let cut: Cut
    var body: some View {
        Image(systemName: cut.state == "running" ? "ellipsis" : cut.state == "failed" ? "exclamationmark" : "scissors")
            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(cut.state == "failed" || cut.clean == false ? Palette.warn : cut.by == "agent" ? Palette.live : Color.gray, in: Circle())
            .accessibilityLabel(cut.by == "agent" ? "Best cut checked by Takes" : "Best cut")
    }
}

/// A take's card on the Board: what its best cut is, and the Mac's take menu as rows.
struct TakeCard: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let take: RemoteFile
    let play: () -> Void
    let close: () -> Void
    let reload: () async -> Void
    @State private var failed: String?

    private var n: Int { take.take ?? 0 }
    private var cut: Cut? { take.cut }

    var body: some View {
        CardOverlay(close: close) {
            VStack(alignment: .leading, spacing: 4) {
                Text(take.name).font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                Text(line).font(.inter(.subheadline)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                if let failed { Text(failed).font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger) }
                PanelRow(icon: "play.fill", title: "Play", action: play)
                PanelRow(icon: take.keeper == true ? "star.slash" : "star", title: take.keeper == true ? "Unstar" : "Star as the keeper") { run("star") }
                PanelRow(icon: "scissors", title: cut == nil ? "Find the Best Cut" : "Find the Best Cut Again", enabled: cut?.state != "running") { run("cut") }
                PanelDivider()
                PanelRow(icon: "rectangle.badge.minus", title: "Take it off this shot") { run("unlink") }
            }
        }
    }

    private var line: String {
        var s = take.duration.map { BoardView.clock($0) } ?? ""
        switch cut?.state {
        case "running": s += "\nGemini is finding the best cut…"
        case "failed": s += "\nNo best cut: \(cut?.error ?? "it failed")"
        case "done":
            let who = cut?.by == "agent" ? "Best cut, checked by Takes" : "Gemini's first suggestion (Takes checks it before cutting)"
            if let r = cut?.range { s += "\n\(who): \(r)\(cut?.clean == false ? " (not every word clean)" : "")" }
            if let w = cut?.why { s += ": \(w)" }
        default: break
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ action: String) {
        Task {
            if let e = await model.tryAct("/api/shot", ["id": sessionID], ["action": action, "take": String(n)]) { failed = e; return }
            close()
            await reload()
        }
    }
}
