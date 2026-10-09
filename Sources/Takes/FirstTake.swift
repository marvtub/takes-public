import AVFoundation
import AppKit
import SwiftUI

/// The first take (2026-10-08, from the "Takes First Take Moment" prototype). After the first take
/// someone ever records, a card over the window: 1, a small party (the take shrinks into a tile,
/// the mascot jumps, confetti, a chime, the numbers count up); 2, the next step: ask Takes for the
/// edit. "Ask Takes to edit" sends that ask with the take to the session's chat, opens Assets
/// (where the edit lands) with the chat beside it, and puts "Your first video" in the sidebar:
/// Record, Ask for the edit, Post it. Each step ticks off by itself; the guide goes after the
/// first post. Shown once. Help › Show First Take Again shows it for the open session.
@MainActor @Observable
final class FirstTake {
    static let shared = FirstTake()
    static let doneKey = "firstTakeDone"
    /// The session folder the sidebar guide follows. Nil: no guide.
    static let guideKey = "firstVideoGuide"
    static let ask = "Make the first edit of this take: cut the pauses and add captions."

    /// The take the card shows.
    struct Moment {
        let session: URL
        let title: String
        let number: Int
        let camera: URL
        let screen: URL?
        let duration: Double
        let words: Int
    }

    var shown = false
    /// True from the card's start until the confetti has fallen: it plays once, not again on Back.
    var confetti = false
    var scene = 0
    var forward = true
    private(set) var moment: Moment?
    var guide: URL? = UserDefaults.standard.string(forKey: guideKey).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(guide?.path, forKey: Self.guideKey) }
    }

    /// At launch: a library that has takes already belongs to someone past their first one.
    func settle(_ library: Library) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.doneKey) else { return }
        if library.grouped.values.joined().contains(where: { $0.takeCount > 0 }) { d.set(true, forKey: Self.doneKey) }
    }

    /// After a take is saved (AppModel.stop): the party, if it was the first take ever.
    func afterTake(_ doc: SessionDoc, number: Int, library: Library) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.doneKey) else { return }
        d.set(true, forKey: Self.doneKey)
        let others = library.grouped.values.joined().contains { $0.takeCount > 0 && Store.dir($0.url) != Store.dir(doc.url) }
        guard number == 1, !others else { return }
        show(doc, number: number)
    }

    /// The card for a take of a session: the newest one when `number` is nil.
    func show(_ doc: SessionDoc, number: Int? = nil) {
        let takes = doc.meta.takes
        guard let n = number ?? takes.map(\.number).max(),
              let cam = takes.first(where: { $0.number == n && $0.kind == .camera }) else { return }
        let screen = takes.first { $0.number == n && $0.kind == .screen }
        let script = cam.script.flatMap { s in doc.variants.first { $0.slug == s }?.text } ?? doc.script
        moment = Moment(session: doc.url, title: doc.meta.title, number: n,
                        camera: doc.url.appending(path: cam.file),
                        screen: screen.map { doc.url.appending(path: $0.file) },
                        duration: cam.duration ?? 0,
                        words: script.split { $0.isWhitespace }.count)
        scene = 0; forward = true; confetti = true
        withAnimation(Theme.spring) { shown = true }
    }

    func go(_ to: Int) {
        guard (0...1).contains(to) else { return }
        forward = to > scene
        if to > 0 { confetti = false }
        withAnimation(Theme.spring) { scene = to }
    }

    /// Later: no chat, but the guide stays so the next step is still in sight.
    func later() {
        if let m = moment { guide = m.session }
        close()
    }

    func close() { withAnimation(Theme.motion) { shown = false } }

    /// The chat edits only when Claude Code is in, signed in, and ffmpeg is there (Setup).
    var canEdit: Bool {
        let s = Setup.shared
        return s.claude == .ok && s.signedIn == .ok && s.ffmpeg == .ok
    }

    /// The ask goes to the session's chat with the take (its screen recording too). Assets opens
    /// with the chat beside it: the edit shows up there when Takes is done.
    func askForEdit(app: AppModel) {
        guard let m = moment else { return }
        Self.open(m.session, .assets, chat: true, app: app)
        let files = [m.camera] + (m.screen.map { [$0] } ?? [])
        app.chats.chat(m.session).send(ChatAttach.message(Self.ask, files: files), title: m.title, onStage: nil)
        guide = m.session
        close()
    }

    /// Opens a tab of the session, with the chat docked beside it when `chat`. select does
    /// nothing when the session is open already.
    static func open(_ session: URL, _ mode: SessionMode, chat: Bool, app: AppModel) {
        app.library.select(session)
        app.board = nil
        app.preview = nil
        if chat { app.chats.docked = true; app.chats.open = true }
        SessionMode.set(mode)
    }
}

/// The dim layer and the card, over the whole window (like OnboardingLayer).
struct FirstTakeLayer: View {
    var flow = FirstTake.shared

    var body: some View {
        ZStack {
            if flow.shown, let m = flow.moment {
                Theme.canvas.opacity(0.97).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}
                    .transition(.opacity)
                FirstTakeCard(flow: flow, moment: m)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: flow.shown)
    }
}

private struct FirstTakeCard: View {
    @Environment(AppModel.self) var app
    var flow: FirstTake
    let moment: FirstTake.Moment
    @FocusState private var focused: Bool
    @State private var setup = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if flow.scene == 0 { CelebrateScene(moment: moment) } else { NextScene(moment: moment) }
                }
                .id(flow.scene)
                .transition(.asymmetric(
                    insertion: .move(edge: flow.forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: flow.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Rule()
            footer
        }
        .frame(width: 760, height: 556)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        // The confetti falls over the whole card, once.
        .overlay { if flow.confetti { Confetti().allowsHitTesting(false) } }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; Chime.play() }
        // Setup checks at launch and again when Takes comes back to the front while a step is left.
        .task { if Setup.shared.claude == .unknown { await Setup.shared.check() } }
        .onKeyPress(.rightArrow) { flow.go(flow.scene + 1); return .handled }
        .onKeyPress(.leftArrow) { flow.go(flow.scene - 1); return .handled }
        .onExitCommand { flow.later() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Capsule().fill(i == flow.scene ? Theme.accent : Theme.border)
                        .frame(width: i == flow.scene ? 22 : 7, height: 7)
                        .onTapGesture { flow.go(i) }
                }
            }
            .animation(Theme.spring, value: flow.scene)
            Spacer()
            Button("Later") { flow.later() }.buttonStyle(BracketButtonStyle())
            if flow.scene == 0 {
                Button { flow.go(1) } label: {
                    HStack(spacing: 6) { Text("What's next"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)) }
                }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { flow.go(0) }.buttonStyle(AccentButtonStyle(kind: .quiet))
                if flow.canEdit {
                    Button { flow.askForEdit(app: app) } label: {
                        HStack(spacing: 6) { Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)); Text("Ask Takes to edit") }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                } else {
                    // Without setup the ask would only end in an error: finish it here first.
                    Button { setup = true } label: {
                        HStack(spacing: 6) { Image(systemName: "checklist").font(.system(size: 11, weight: .bold)); Text("Finish setup to edit") }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .popover(isPresented: $setup, arrowEdge: .top) { SetupPanel(setup: Setup.shared) }
                }
            }
        }
        .padding(.horizontal, 24).frame(height: 64)
        .background(Theme.canvas)
    }
}

// MARK: - 1. The party

private struct CelebrateScene: View {
    @Environment(\.accessibilityReduceMotion) var still
    let moment: FirstTake.Moment
    /// 0 recording, 1 saved and shrunk into its tile, 2 the mascot has landed.
    @State private var step = 0

    var body: some View {
        PageFrame(title: "Your first take is in.",
                  text: "You just did the hardest part. Most videos never get made because nobody hits record. Yours did.",
                  after: 2) {
            ZStack {
                Rings(on: step >= 1)
                HStack(alignment: .bottom, spacing: 26) {
                    TakeTile(moment: moment, saved: step >= 1)
                        .rotationEffect(.degrees(step >= 1 ? -3 : 0))
                        .scaleEffect(step >= 1 ? 1 : 1.12)
                    LiveMascot(mood: step == 1 ? .writing : .idle, size: 76)
                        .offset(y: step >= 1 ? 0 : 40)
                        .opacity(step >= 1 ? 1 : 0)
                        .padding(.bottom, 6)
                }
            }
            .padding(.top, 22)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Chip(icon: "video.fill", count: moment.duration, format: Self.time, text: "on camera")
                if moment.words > 0 {
                    Chip(icon: "text.alignleft", count: Double(moment.words), format: { "\(Int($0))" }, text: "words read")
                }
                Chip(icon: "checkmark", count: Double(moment.number), format: { "Take \(Int($0))" }, text: "saved", mint: true)
            }
            .arrive(4)
            .padding(.bottom, 26)
        }
        .task {
            if still { step = 2; return }
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { step = 1 }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.spring) { step = 2 }
        }
    }

    static func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// The take, playing without sound, in the shape it was recorded: wide, tall, or the screen with
/// the camera in a bubble.
private struct TakeTile: View {
    let moment: FirstTake.Moment
    var saved: Bool
    var small = false
    @State private var shape: CGFloat = 16 / 9
    @State private var main: AVQueuePlayer?
    /// A frame of each video, under the players: the tile is never black while they load.
    @State private var stills: [URL: NSImage] = [:]
    @State private var bubble: AVQueuePlayer?
    @State private var loops: [AVPlayerLooper] = []

    private var size: CGSize {
        let h: CGFloat = small ? 44 : 186
        let w = min(h * shape, small ? 80 : 330)
        return CGSize(width: w, height: w / shape)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.stage
            if let still = stills[moment.screen ?? moment.camera] {
                Image(nsImage: still).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
            }
            if let main { PostPlayerLayer(player: main) }
            if !small, moment.screen != nil {
                ZStack {
                    if let still = stills[moment.camera] { Image(nsImage: still).resizable().scaledToFill() }
                    if let bubble { PostPlayerLayer(player: bubble) }
                }
                    .frame(width: 58, height: 58).clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
            }
            if !small {
                HStack(spacing: 5) {
                    if saved { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)) }
                    else { Circle().fill(Theme.danger).frame(width: 7, height: 7) }
                    Text(saved ? "SAVED" : "REC").font(Theme.mono(10, .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(saved ? Theme.live : .black.opacity(0.4), in: Capsule())
                .padding(10)
                .animation(Theme.spring, value: saved)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            if !small && saved {
                HStack {
                    Text("Take \(moment.number)").font(Theme.sans(12, .semibold))
                    Spacer()
                    Text(CelebrateScene.time(moment.duration)).font(Theme.mono(11))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 8)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: small ? 7 : 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: small ? 7 : 14, style: .continuous)
            .strokeBorder(saved && !small ? Theme.live.opacity(0.9) : Theme.border, lineWidth: saved && !small ? 2 : 1))
        .shadow(color: .black.opacity(small ? 0 : 0.22), radius: 16, y: 8)
        .task { await load() }
        .onDisappear { main?.pause(); bubble?.pause() }
    }

    private func load() async {
        let video = moment.screen ?? moment.camera
        if let s = await Self.shape(of: video) { shape = s }
        for u in [video, moment.camera] where stills[u] == nil { stills[u] = await Self.still(u) }
        main = player(video)
        if moment.screen != nil, !small { bubble = player(moment.camera) }
    }

    /// Muted, and round again at the end: the looper must live as long as the player.
    private func player(_ url: URL) -> AVQueuePlayer {
        let p = AVQueuePlayer()
        p.isMuted = true
        loops.append(AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url)))
        p.play()
        return p
    }

    static func still(_ url: URL) async -> NSImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 800, height: 800)
        guard let (cg, _) = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Width over height, turned the way it plays.
    static func shape(of url: URL) async -> CGFloat? {
        guard let t = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (n, f) = try? await t.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: n).applying(f)
        return r.height > 0 ? abs(r.width) / abs(r.height) : nil
    }
}

/// Two soft rings that open out behind the tile when it is saved.
private struct Rings: View {
    var on: Bool
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle().strokeBorder(Theme.live.opacity(on ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 180, height: 180)
                    .scaleEffect(on ? 2.2 : 0.6)
                    .animation(.easeOut(duration: 1.3).delay(Double(i) * 0.25), value: on)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A number that counts up from zero once, then its words.
private struct Chip: View {
    @Environment(\.accessibilityReduceMotion) var still
    let icon: String
    let count: Double
    let format: (Double) -> String
    let text: String
    var mint = false
    @State private var shown: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(format(shown)).font(Theme.sans(12.5, .semibold)).monospacedDigit()
            Text(text).font(Theme.sans(12.5)).foregroundStyle(mint ? Theme.live : Theme.muted)
        }
        .foregroundStyle(mint ? Theme.live : Theme.ink)
        .padding(.horizontal, 12).frame(height: 30)
        .background(mint ? Theme.liveSoft : Theme.hover, in: Capsule())
        .task {
            if still { shown = count; return }
            try? await Task.sleep(for: .seconds(1.0))
            let steps = 24
            for i in 1...steps {
                // Ease out: fast first, then it settles on the number.
                let t = Double(i) / Double(steps)
                shown = count * (1 - pow(1 - t, 3))
                try? await Task.sleep(for: .milliseconds(30))
            }
            shown = count
        }
    }
}

/// Brand-coloured paper that bursts up and falls for three seconds, then is gone.
private struct Confetti: View {
    @Environment(\.accessibilityReduceMotion) var still
    @State private var start = Date()
    private static let colors: [Color] = [Theme.accent, Theme.live, Color(red: 0.06, green: 0.16, blue: 0.34),
                                          Color(red: 0.87, green: 0.97, blue: 0.91), Color(red: 1, green: 0.78, blue: 0.3)]
    /// In @State: a plain property would draw new pieces each time the card redraws.
    @State private var bits: [(x: Double, vx: Double, vy: Double, spin: Double, size: Double, color: Int, delay: Double)] =
        (0..<90).map { i in
            (x: .random(in: 0.3...0.7), vx: .random(in: -260...260), vy: .random(in: -620 ... -300),
             spin: .random(in: -9...9), size: .random(in: 5...9), color: i % 5, delay: .random(in: 0.6...0.9))
        }

    var body: some View {
        if !still {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let t = tl.date.timeIntervalSince(start)
                    for b in bits {
                        let a = t - b.delay
                        guard a > 0 else { continue }
                        let x = b.x * size.width + b.vx * a
                        let y = size.height * 0.42 + b.vy * a + 520 * a * a
                        let fade = max(0, 1 - max(0, a - 1.8) / 0.8)
                        guard fade > 0, y < size.height + 20 else { continue }
                        var c = ctx
                        c.opacity = fade
                        c.translateBy(x: x, y: y)
                        c.rotate(by: .radians(b.spin * a))
                        c.fill(Path(CGRect(x: -b.size / 2, y: -b.size / 4, width: b.size, height: b.size / 2)),
                               with: .color(Self.colors[b.color]))
                    }
                }
            }
            .task {
                // A TimelineView redraws every frame: end it once the last piece has faded.
                try? await Task.sleep(for: .seconds(3.6))
                FirstTake.shared.confetti = false
            }
        }
    }
}

/// Two soft notes, a fifth apart. Made in memory: no file to ship.
@MainActor
enum Chime {
    private static var player: AVAudioPlayer?

    static func play() {
        if player == nil { player = try? AVAudioPlayer(data: wav()) }
        player?.volume = 0.35
        player?.currentTime = 0
        player?.play()
    }

    private static func wav() -> Data {
        let rate = 44_100.0
        var samples = [Int16](repeating: 0, count: Int(rate * 1.1))
        for (freq, at) in [(880.0, 0.0), (1318.5, 0.14)] {
            let start = Int(at * rate)
            for i in 0..<(samples.count - start) {
                let t = Double(i) / rate
                let env = min(1, t / 0.008) * exp(-t * 5.5)
                let v = sin(2 * .pi * freq * t) * env * 0.32 + sin(4 * .pi * freq * t) * env * 0.06
                samples[start + i] = Int16(clamping: Int(samples[start + i]) + Int(v * 32_767))
            }
        }
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian); put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian); put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        d.append(contentsOf: Array("data".utf8)); put(bytes.littleEndian)
        samples.forEach { put($0.littleEndian) }
        return d
    }
}

// MARK: - 2. What's next

private struct NextScene: View {
    @Environment(\.accessibilityReduceMotion) var still
    let moment: FirstTake.Moment
    @State private var typed = 0
    /// 0 typing, 1 sent and Takes works, 2 the edit is back.
    @State private var stage = 0

    var body: some View {
        PageFrame(title: "Now ask Takes for the edit.",
                  text: "Say what you want in plain words. Takes cuts the pauses, adds captions and puts the video on Assets. Then it writes the post.",
                  note: FirstTake.shared.canEdit ? nil : "First, finish setup: two minutes, once.",
                  after: 3) {
            VStack(spacing: 16) {
                path.arrive(0)
                VStack(alignment: .leading, spacing: 10) {
                    askBox
                    reply.opacity(stage >= 1 ? 1 : 0).offset(y: stage >= 1 ? 0 : 8)
                }
                .frame(width: 520)
                .arrive(1)
            }
            .padding(.top, 30)
        }
        .task { await loop() }
    }

    private static let line = "Cut the pauses and add captions"

    private var path: some View {
        HStack(spacing: 10) {
            GuideDot(state: .done, n: 1); Text("Record").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.muted)
            Rule().frame(width: 22)
            GuideDot(state: .now, n: 2); Text("Ask for the edit").font(Theme.sans(12.5, .semibold))
            Rule().frame(width: 22)
            GuideDot(state: .later, n: 3); Text("Post it").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.faint)
        }
    }

    private var askBox: some View {
        HStack(spacing: 10) {
            TakeTile(moment: moment, saved: true, small: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Take \(moment.number)").font(Theme.sans(11, .semibold)).foregroundStyle(Theme.muted)
                HStack(spacing: 1) {
                    Text(Self.line.prefix(typed)).font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                    if typed < Self.line.count { Rectangle().fill(Theme.accent).frame(width: 1.5, height: 16) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(typed == Self.line.count ? 1 : 0.35), in: Circle())
                .scaleEffect(stage == 1 ? 1.1 : 1)
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
    }

    private var reply: some View {
        HStack(spacing: 10) {
            LiveMascot(mood: stage == 1 ? .working : .idle, size: 30)
            if stage < 2 {
                ProgressView().controlSize(.small)
                Text("Cutting the pauses and adding captions…").font(Theme.sans(13)).foregroundStyle(Theme.muted)
            } else {
                Text("Done.").font(Theme.sans(13, .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 10, weight: .bold))
                    Text("Edit v1 · captions").font(Theme.sans(12, .semibold))
                }
                .foregroundStyle(Theme.live)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.liveSoft, in: Capsule())
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .animation(Theme.spring, value: stage)
    }

    private func loop() async {
        if still { typed = Self.line.count; stage = 2; return }
        while !Task.isCancelled {
            typed = 0; stage = 0
            try? await Task.sleep(for: .seconds(0.6))
            while typed < Self.line.count && !Task.isCancelled {
                typed += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(Theme.spring) { stage = 1 }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(Theme.spring) { stage = 2 }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// A step's circle: a tick when done, the number in accent when it is next.
struct GuideDot: View {
    enum Step { case done, now, later }
    let state: Step
    let n: Int
    var body: some View {
        ZStack {
            Circle().fill(state == .done ? Theme.live : state == .now ? Theme.accent : Theme.hover)
            if state == .done { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
            else { Text("\(n)").font(Theme.mono(10.5, .bold)).foregroundStyle(state == .now ? .white : Theme.faint) }
        }
        .frame(width: 20, height: 20)
        .animation(Theme.spring, value: state)
    }
}

// MARK: - The guide in the sidebar

/// "Your first video": Record, Ask for the edit, Post it. It follows one session: the edit step
/// ticks when its edits/ folder has a video, the post step when the session is published. After
/// the post it says so for a moment, then goes.
struct FirstVideoGuide: View {
    @Environment(AppModel.self) var app
    var flow = FirstTake.shared
    @State private var edited = false

    var body: some View {
        if let session = flow.guide {
            let posted = app.library.grouped.values.joined().first { Store.dir($0.url) == Store.dir(session) }?.published ?? false
            let chat = app.chats.existing(session)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(posted ? "Your first video is out." : "Your first video").font(Theme.sans(12.5, .semibold))
                    Spacer()
                    Button { flow.guide = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Hide the guide")
                }
                Capsule().fill(Theme.hover).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Theme.live).frame(width: g.size.width * (posted ? 1 : edited ? 0.66 : 0.33))
                        }
                    }
                    .animation(Theme.spring, value: edited)
                    .animation(Theme.spring, value: posted)
                row(1, "Record", state: .done, detail: nil) {}
                row(2, "Ask for the edit", state: edited ? .done : .now,
                    detail: edited ? nil : chat?.running == true ? "Takes is editing…" : "Takes cuts it for you") {
                    open(session, .assets, chat: true)
                }
                row(3, "Post it", state: posted ? .done : edited ? .now : .later,
                    detail: edited && !posted ? "Takes writes the post" : nil) {
                    open(session, .post, chat: false)
                }
            }
            .padding(12)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            .padding(.horizontal, 10).padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            // Again for each session the guide follows: the view stays when the guide moves.
            .task(id: session) { edited = Self.hasEdit(session) }
            .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
                if FileWatch.touches(n, session) { withAnimation(Theme.spring) { edited = Self.hasEdit(session) } }
            }
            .task(id: Leave(session: session, posted: posted)) {
                guard posted else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { withAnimation(Theme.spring) { flow.guide = nil } }
            }
        }
    }

    private func row(_ n: Int, _ title: String, state: GuideDot.Step, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                GuideDot(state: state, n: n)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(12.5, state == .now ? .semibold : .regular))
                        .foregroundStyle(state == .later ? Theme.faint : state == .done ? Theme.muted : Theme.ink)
                        .strikethrough(state == .done, color: Theme.faint)
                    if let detail { Text(detail).font(Theme.sans(11)).foregroundStyle(Theme.faint) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state != .now)
    }

    private func open(_ session: URL, _ mode: SessionMode, chat: Bool) {
        FirstTake.open(session, mode, chat: chat, app: app)
    }

    /// The goodbye timer starts again when the guide follows another session.
    private struct Leave: Hashable { let session: URL; let posted: Bool }

    static func hasEdit(_ session: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: session.appending(path: "edits"), includingPropertiesForKeys: nil)) ?? []
        return files.contains { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
    }
}
