import AVFoundation
import SwiftUI

/// Plugins › Sound FX (2026-10-19; public 2026-10-22): sound effects made in code on demand, for the
/// chat's edits. earshot (github.com/Leonxlnx/earshot, MIT) does the work from its own venv; the takes
/// server's sfx_sounds, make_sfx and design_sfx call it (mcp/takes_mcp.py, Sound FX). Off here, the
/// server lists none of them. The card installs earshot in two parts: the 201 ready sounds (about
/// 300 MB, no models) and sound design (torch and two models, about 2 GB more).
///
/// The page leads with the sounds, not the install (2026-10-22, designed on the canvas first): before
/// the install a hero with one button and six sounds to play (assets/sfx, bundled); after it, the
/// sound library, with sound design offered where a new sound is described.
struct SoundFXPage: View {
    @ObservedObject var setup: SoundFXSetup
    @ObservedObject var bank: SoundBank
    @ObservedObject var player: SoundFXPlayer
    /// Puts a line in the open session's chat box; nil when no session is open.
    var ask: ((String) -> Void)?
    /// Snapshots: text boxes drawn as text (ImageRenderer cannot draw an AppKit field).
    var still = false
    @State private var describe = ""
    @State private var search = ""
    @State private var group: String?

    static let plugin = TakesPlugin(
        id: "sfx", title: "Sound FX", icon: "waveform.badge.plus", key: " ",
        help: "Sound effects for your edits, made in code on this Mac.",
        badge: { _ in AnyView(EmptyView()) }, board: nil,
        settings: { app in AnyView(SoundFXPage(ask: SoundFXPage.asker(app))) })

    @MainActor init(ask: ((String) -> Void)? = nil) {
        _setup = ObservedObject(wrappedValue: .shared)
        _bank = ObservedObject(wrappedValue: .shared)
        _player = ObservedObject(wrappedValue: .shared)
        self.ask = ask
    }
    init(setup: SoundFXSetup, bank: SoundBank, player: SoundFXPlayer, ask: ((String) -> Void)? = nil, still: Bool = false) {
        self.still = still
        _setup = ObservedObject(wrappedValue: setup)
        _bank = ObservedObject(wrappedValue: bank)
        _player = ObservedObject(wrappedValue: player)
        self.ask = ask
    }

    /// The open session's chat gets the line in its box, for the user to finish and send.
    @MainActor static func asker(_ app: AppModel) -> ((String) -> Void)? {
        guard let doc = app.library.current else { return nil }
        return { text in
            app.chats.chat(doc.url).draft = text
            app.board = nil
            app.chats.open = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if setup.python == nil {
                hero
                hearAFew
                teaser
            } else {
                makeNew
                library
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
        .onAppear {
            guard setup === SoundFXSetup.shared else { return }
            setup.refresh()
            if let py = setup.python { bank.load(py) }
        }
        .onChange(of: setup.python) { _, py in if let py, bank === SoundBank.shared { bank.load(py) } }
        .onDisappear { player.stop() }
    }

    // MARK: Before the install

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("201 SOUNDS · MADE IN CODE").font(Theme.sans(10.5, .semibold)).tracking(0.8)
                    .foregroundStyle(hex(0xBFD4FF))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(hex(0x7FB2FF).opacity(0.16)))
                Text("Sounds that land on the cut.").font(Theme.display(30, .heavy)).foregroundStyle(.white)
                Text("Whooshes, hits, risers and clicks, timed to the frame. Takes makes them on this Mac, free and with no account.")
                    .font(Theme.sans(13.5)).lineSpacing(3).foregroundStyle(hex(0xC9D6EE))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560, alignment: .leading)
            HeroWave(progress: setup.running == .sounds ? setup.progress : setup.failed[.sounds] != nil ? setup.failedAt : nil,
                     failed: setup.failed[.sounds] != nil)
                .frame(height: 64)
            heroAction.frame(minHeight: 40)
        }
        .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 24)
        .background(RoundedRectangle(cornerRadius: 16).fill(SFXColor.navy))
    }

    @ViewBuilder private var heroAction: some View {
        if setup.running == .sounds {
            HStack(spacing: 12) {
                Spinner(color: hex(0x7FB2FF))
                Text("Installing").font(Theme.sans(14, .semibold)).foregroundStyle(.white)
                Text(setup.stepLine).font(Theme.sans(12.5)).foregroundStyle(hex(0xA9BCDD))
            }
        } else {
            HStack(spacing: 14) {
                let failed = setup.failed[.sounds]
                Button { setup.install(.sounds) } label: {
                    Text(failed != nil ? "Try again" : "Install Sound FX")
                        .font(Theme.sans(14, .semibold)).foregroundStyle(SFXColor.navy)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(setup.running != nil)
                Text(failed.map { $0 + " Check the connection, then try again." } ?? "About 300 MB · about a minute")
                    .font(Theme.sans(12.5)).foregroundStyle(failed != nil ? hex(0xFFB4B6) : hex(0xA9BCDD))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hearAFew: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Hear a few").font(Theme.display(16)).foregroundStyle(Theme.ink)
                Text(setup.running == .sounds ? "Try them while Takes installs." : "Play them before you install.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(SoundFXPreview.all) { p in
                    SoundTile(name: p.name, detail: p.kind.label, kind: p.kind, bars: p.bars(16),
                              playing: player.playing == p.id, loading: false, use: nil) { player.toggle(p.id, file: p.file) }
                }
            }
        }
    }

    private var teaser: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(SFXKind.riser.ink)
                .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(SFXKind.riser.soft))
            VStack(alignment: .leading, spacing: 3) {
                Text("Make your own sounds").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Describe a sound and Takes designs it in about a minute. You can add this after the install.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text("“A soft paper swish, like turning a page”").font(Theme.sans(12).italic()).foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
    }

    // MARK: After the install

    private var makeNew: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(hex(0xC4A8FF))
                    .help("Make a new sound")
                field($describe, "Make a new sound: a soft paper swish, like turning a page", hex(0x8FA3C7))
                    .font(Theme.sans(13)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.14)))
                    .onSubmit { if setup.canDesign { design() } }
                if setup.running != .design {
                    navyButton(setup.canDesign ? "Design" : setup.failed[.design] != nil ? "Try again" : "Add sound design") {
                        if setup.canDesign { design() } else { setup.install(.design) }
                    }
                    .disabled(setup.running != nil || (setup.canDesign && (ask == nil || describe.trimmingCharacters(in: .whitespaces).isEmpty)))
                    .help(setup.canDesign && ask == nil ? "Open a session first: the sound goes into its chat." : "")
                }
            }
            designFoot.padding(.leading, 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(SFXColor.navy))
    }

    @ViewBuilder private var designFoot: some View {
        if setup.running == .design {
            VStack(alignment: .leading, spacing: 8) {
                Segments(count: setup.stepCount, at: setup.stepIndex)
                Text("Adding sound design · " + setup.stepLine).font(Theme.sans(12)).foregroundStyle(hex(0xA9BCDD))
            }
        } else if let e = setup.failed[.design] {
            Text(e).font(Theme.sans(12)).foregroundStyle(hex(0xFFB4B6)).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(setup.canDesign ? "About a minute per sound. You can give it a sound to match, too."
                                 : "First, Takes gets two AI models that hear sounds. About 2 GB, a few minutes, one time.")
                .font(Theme.sans(11.5)).foregroundStyle(hex(0xA9BCDD)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func field(_ text: Binding<String>, _ prompt: String, _ promptColor: Color) -> some View {
        if still {
            Text(prompt).foregroundStyle(promptColor).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(promptColor)).textFieldStyle(.plain)
        }
    }

    private func design() {
        let text = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let ask else { return }
        ask("Design a new sound effect: \(text)")
        describe = ""
    }

    private func navyButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.sans(13.5, .semibold)).foregroundStyle(SFXColor.navy)
                .padding(.horizontal, 16).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private var library: some View {
        // One group at a time keeps the page short; a search looks in all of them.
        let pick = group ?? bank.groups.first ?? ""
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = bank.rows.filter { r in words.isEmpty ? (pick == SoundBank.all || r.group == pick) : r.key.contains(words) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Sound library").font(Theme.display(16)).foregroundStyle(Theme.ink)
                if !bank.rows.isEmpty {
                    Text("\(bank.rows.count) sounds").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 12)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.faint)
                    field($search, "Search all sounds", Theme.faint)
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 11).frame(width: 220, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
            if let e = bank.error {
                Text(e).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            } else if bank.rows.isEmpty {
                HStack(spacing: 10) { Spinner(color: Theme.accent); Text("Reading the sounds…").font(Theme.sans(12)).foregroundStyle(Theme.muted) }
            } else {
                Flow(spacing: 6) {
                    ForEach(bank.groups + [SoundBank.all], id: \.self) { g in
                        pill(g, count: g == SoundBank.all ? bank.rows.count : bank.counts[g] ?? 0, on: words.isEmpty && g == pick) {
                            group = g; search = ""
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 4) {
                    ForEach(shown) { r in
                        SFXSoundRow(row: r, player: player, playing: player.playing == r.id, loading: player.loading == r.id,
                                 use: ask.map { ask in { ask("Use the Sound FX sound \(r.id) (\(r.name)) in this edit: ") } }) {
                            if let py = setup.python { player.toggle(r.id, python: py) }
                        }
                    }
                }
                if shown.isEmpty {
                    Text("No sound matches “\(search)”.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                Text("To use one, ask the chat: “Put Punch on the title card.” Takes times it to the frame.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint).padding(.top, 2)
            }
        }
    }

    private func pill(_ name: String, count: Int, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.motion) { action() } } label: {
            HStack(spacing: 5) {
                Text(name).font(Theme.sans(12, .medium)).foregroundStyle(on ? Theme.paper : Theme.ink)
                Text("\(count)").font(Theme.sans(11.5)).foregroundStyle(on ? Theme.paper.opacity(0.7) : Theme.faint)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(on ? Theme.ink : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Theme.ink : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Parts

/// One sound: a play button, its name, what it is, and its waveform. Hover shows Use when a session is open.
private struct SoundTile: View {
    let name: String
    let detail: String
    let kind: SFXKind
    let bars: [CGFloat]
    let playing: Bool
    let loading: Bool
    let use: (() -> Void)?
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: play) {
                    ZStack {
                        if loading { Spinner(color: kind.ink, size: 14) }
                        else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 11)).foregroundStyle(kind.ink) }
                    }
                    .frame(width: 30, height: 30).background(Circle().fill(kind.soft)).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(playing ? "Pause \(name)" : "Play \(name)")
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(detail).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let use, hover {
                    Button("Use", action: use).buttonStyle(.plain).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.accentInk)
                        .help("Put this sound in the open session's chat")
                }
            }
            Wave(bars: bars, rest: kind.ink.opacity(playing ? 1 : 0.55), lit: kind.ink).frame(height: 26)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(playing ? kind.ink : Theme.border, lineWidth: playing ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hover = $0 }
        .animation(Theme.motion, value: playing)
    }
}

/// One sound in the library: play, name, length and its shape. Hover shows Use when a session is open.
private struct SFXSoundRow: View {
    let row: SFXRow
    let player: SoundFXPlayer
    let playing: Bool
    let loading: Bool
    let use: (() -> Void)?
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                ZStack {
                    if loading { Spinner(color: row.kind.ink, size: 12) }
                    else {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9.5))
                            .foregroundStyle(playing ? row.kind.ink : Theme.muted)
                    }
                }
                .frame(width: 26, height: 26).background(Circle().fill(playing ? row.kind.soft : Theme.canvas)).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause \(row.name)" : "Play \(row.name)")
            Text(row.name).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let use, hover {
                Button("Use", action: use).buttonStyle(.plain).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.accentInk)
                    .help("Put this sound in the open session's chat")
            } else {
                Text(row.duration).font(Theme.sans(11).monospacedDigit()).foregroundStyle(Theme.faint)
            }
            Group {
                if playing {
                    TimelineView(.animation) { _ in Wave(bars: row.bars, rest: Theme.faint.opacity(0.45), lit: row.kind.ink, heard: player.heard) }
                } else {
                    Wave(bars: row.bars, rest: Theme.faint.opacity(hover ? 0.9 : 0.45), lit: Theme.faint)
                }
            }
            .frame(width: 96, height: 18)
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover || playing ? Theme.paper : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hover = $0 }
    }
}

/// A sound's shape, drawn in one pass. While it plays, the part already heard fills in.
private struct Wave: View {
    let bars: [CGFloat]
    let rest: Color
    let lit: Color
    var heard: Double = 0
    var body: some View {
        Canvas { ctx, size in
            let n = CGFloat(bars.count), gap: CGFloat = 2
            let w = max((size.width - gap * (n - 1)) / n, 1)
            for (i, h) in bars.enumerated() {
                let x = CGFloat(i) * (w + gap), bh = max(size.height * h, 2)
                let bar = Path(roundedRect: CGRect(x: x, y: size.height - bh, width: w, height: bh), cornerRadius: min(w / 2, 1.5))
                ctx.fill(bar, with: .color(Double((x + w / 2) / size.width) <= heard ? lit : rest))
            }
        }
    }
}

/// The hero's 64 bars: many colours at rest; while installing they fill as the install moves on.
private struct HeroWave: View {
    /// 0...1 while installing (or where a failed install stopped); nil at rest.
    let progress: Double?
    let failed: Bool
    static let palette: [UInt32] = [0x7FB2FF, 0xFFB547, 0xB794FF, 0x4FD6C4, 0xFF8FC1]
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<64, id: \.self) { i in
                let x = Double(i) / 63
                let h = max(0.1, 0.18 + 0.82 * abs(sin(Double(i) * 0.37) * cos(Double(i) * 0.113 + 0.6)))
                let color: Color = {
                    guard let progress else { return hex(Self.palette[(i / 13) % Self.palette.count]) }
                    return x <= progress ? hex(failed ? 0xFF8F92 : 0x7FB2FF) : Color.white.opacity(0.16)
                }()
                GeometryReader { g in
                    VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 3).fill(color).frame(height: g.size.height * h) }
                }
            }
        }
        .animation(.easeOut(duration: 0.6), value: progress)
    }
}

/// The install's steps as segments; the current one breathes.
private struct Segments: View {
    let count: Int
    let at: Int
    @State private var dim = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                Capsule().fill(i <= at ? hex(0x7FB2FF) : Color.white.opacity(0.16))
                    .opacity(i == at && dim ? 0.45 : 1)
                    .frame(height: 5)
            }
        }
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }
}

private struct Spinner: View {
    let color: Color
    var size: CGFloat = 20
    @State private var turn = false
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: size / 7)
            Circle().trim(from: 0, to: 0.22).stroke(color, style: StrokeStyle(lineWidth: size / 7, lineCap: .round))
                .rotationEffect(.degrees(turn ? 360 : 0))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turn)
        .onAppear { turn = true }
    }
}

/// Rows that wrap, for the group pills.
private struct Flow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + s.width <= width {
                rows[rows.count - 1] = (last.items + [i], last.width + spacing + s.width, max(last.height, s.height))
            } else {
                rows.append(([i], s.width, s.height))
            }
        }
        return rows
    }
}

// MARK: - Sounds

enum SFXColor {
    static let navy = hex(0x102A56)
}

/// What a sound is, for its colour and its label.
enum SFXKind: String {
    case whoosh, hit, riser, click, sting, drop, typing, glitch, pop, notify, other

    var label: String {
        switch self {
        case .whoosh: "Whoosh"; case .hit: "Hit"; case .riser: "Riser"; case .click: "Click"; case .sting: "Sting"
        case .drop: "Drop"; case .typing: "Typing"; case .glitch: "Glitch"; case .pop: "Pop"; case .notify: "Notification"
        case .other: "Sound"
        }
    }
    private var tones: (light: UInt32, dark: UInt32, soft: UInt32, softDark: UInt32) {
        switch self {
        case .whoosh: (0x2563EB, 0x7FB2FF, 0xE3EDFE, 0x1B2F55)
        case .hit: (0xC2410C, 0xFFB547, 0xFFF0DE, 0x3A2A14)
        case .riser: (0x7C3AED, 0xB794FF, 0xEFE7FF, 0x2A2150)
        case .click: (0x0F766E, 0x4FD6C4, 0xDDF6F2, 0x123533)
        case .sting: (0xDB2777, 0xFF8FC1, 0xFDE7F1, 0x3A1A2C)
        case .drop, .notify: (0x4338CA, 0x9C95FF, 0xE8E7FD, 0x221F4A)
        case .typing, .other: (0x475569, 0xA9B6CC, 0xEDF0F5, 0x1F2A3D)
        case .glitch: (0xDC2626, 0xFF8F92, 0xFDE8E8, 0x3A1D24)
        case .pop: (0xB45309, 0xFFB08A, 0xFFEDE3, 0x3A2218)
        }
    }
    var ink: Color { Theme.dynamic(tones.light, tones.dark) }
    var soft: Color { Theme.dynamic(tones.soft, tones.softDark) }
}

/// The library's groups: earshot's 36 categories in ten, with real counts from `sfx list`.
struct SFXGroup {
    let name: String
    let kind: SFXKind
    let categories: [String]

    static let all: [SFXGroup] = [
        SFXGroup(name: "Whooshes", kind: .whoosh, categories: ["whoosh_big", "whoosh_fast", "pro_whoosh_big", "swish", "swipe"]),
        SFXGroup(name: "Hits", kind: .hit, categories: ["impact", "pro_impact", "sub_drop", "pro_sub_drop"]),
        SFXGroup(name: "Clicks and taps", kind: .click, categories: ["click", "pro_click", "tap", "pro_tap", "hover_tick", "pro_hover_tick", "toggle"]),
        SFXGroup(name: "Glitch and shimmer", kind: .glitch, categories: ["glitch", "pro_glitch", "shimmer", "pro_shimmer"]),
        SFXGroup(name: "Typing", kind: .typing, categories: ["typing_key", "pro_typing_key", "pro_typing_run"]),
        SFXGroup(name: "Pops", kind: .pop, categories: ["pop", "pro_pop", "pro_pop_in"]),
        SFXGroup(name: "Risers", kind: .riser, categories: ["riser", "pro_riser", "downlifter"]),
        SFXGroup(name: "Notifications", kind: .notify, categories: ["notify", "pro_notify"]),
        SFXGroup(name: "Stings", kind: .sting, categories: ["logo_sting", "pro_logo_sting"]),
    ]
    static let more = SFXGroup(name: "More", kind: .other, categories: [])

    static func of(_ category: String) -> SFXGroup { all.first { $0.categories.contains(category) } ?? more }
}

/// One sound in earshot's bank (`sfx list --json`).
struct SFXSound: Identifiable, Decodable, Equatable {
    let id: String
    let category: String
    let dur_s: Double
    let onset_s: Double
    let peak_s: Double
    let end_s: Double

    var group: SFXGroup { SFXGroup.of(category) }
    var kind: SFXKind {
        let base = category.hasPrefix("pro_") ? String(category.dropFirst(4)) : category
        switch base {
        case "sub_drop": return .drop
        case "downlifter", "riser": return .riser
        case "notify": return .notify
        case "logo_sting": return .sting
        case "shimmer", "glitch": return .glitch
        case "typing_key", "typing_run": return .typing
        case "pop", "pop_in": return .pop
        case "impact": return .hit
        case "whoosh_big", "whoosh_fast", "swish", "swipe": return .whoosh
        case "click", "tap", "hover_tick", "toggle": return .click
        default:
            if id.hasPrefix("fit/") { return SFXSound.fitKind(id) }
            return .other
        }
    }
    /// "fit/whoosh.short/bamboo_swish": the middle says what it is.
    private static func fitKind(_ id: String) -> SFXKind {
        let mid = id.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        if mid.hasPrefix("whoosh") { return .whoosh }
        if mid.hasPrefix("hit") { return .hit }
        if mid.hasPrefix("pop") { return .pop }
        if mid.hasPrefix("snap") || mid.hasPrefix("click") { return .click }
        return .other
    }

    /// "pro_click/snap" → "Snap"; "fit/hit/bamboo_tok" → "Bamboo tok".
    var name: String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let words = last.replacingOccurrences(of: "_", with: " ")
        let n = words.prefix(1).uppercased() + words.dropFirst()
        return category.hasPrefix("pro_") ? n + " (pro)" : n
    }

    var duration: String { SFXSound.seconds(dur_s) }
    static func seconds(_ s: Double) -> String {
        s < 0.095 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }

    /// Its shape from the bank's numbers: quiet to the onset, up to the peak, then a decay to the end.
    func bars(_ n: Int) -> [CGFloat] {
        let seed = Double(id.utf8.reduce(5381) { ($0 &* 33 &+ Int($1)) & 0xFFFF })
        return (0..<n).map { i in
            let t = dur_s * (Double(i) + 0.5) / Double(n)
            var e: Double
            if t < onset_s { e = 0.06 }
            else if t <= peak_s { e = 0.2 + 0.8 * pow((t - onset_s) / max(peak_s - onset_s, 0.001), 0.7) }
            else { e = exp(-3.2 * (t - peak_s) / max(end_s - peak_s, 0.01)) * 0.95 + 0.05 }
            if kind == .glitch { e *= (i / 3) % 2 == 0 ? 1 : 0.35 }
            let jitter = 0.6 + 0.4 * abs(sin(Double(i) * 1.93 + seed) * cos(Double(i) * 0.71 + seed * 2.3))
            return CGFloat(max(0.08, min(1, e * jitter)))
        }
    }
}

/// The six sounds Takes ships (assets/sfx), to play before earshot is installed.
struct SoundFXPreview: Identifiable {
    let id: String
    let name: String
    let kind: SFXKind

    static let all: [SoundFXPreview] = [
        SoundFXPreview(id: "swish/stick", name: "Swish", kind: .whoosh),
        SoundFXPreview(id: "impact/punch", name: "Punch", kind: .hit),
        SoundFXPreview(id: "riser/tension", name: "Tension", kind: .riser),
        SoundFXPreview(id: "click/snap", name: "Snap", kind: .click),
        SoundFXPreview(id: "logo_sting/spark", name: "Spark", kind: .sting),
        SoundFXPreview(id: "sub_drop/808", name: "808", kind: .drop),
    ]

    /// In the app: Resources/SFX. In tests and `swift run`: the repo's assets/sfx.
    var file: URL? {
        let name = id.replacingOccurrences(of: "/", with: "-") + ".m4a"
        let dirs = [Bundle.main.resourceURL?.appending(path: "SFX"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../assets/sfx").standardized]
        return dirs.compactMap { $0?.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The real shape of the file, n bars of its peaks.
    func bars(_ n: Int) -> [CGFloat] {
        if let cached = Self.cache[id + "\(n)"] { return cached }
        var out = [CGFloat](repeating: 0.1, count: n)
        if let file, let f = try? AVAudioFile(forReading: file),
           let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
           (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] {
            let count = Int(buf.frameLength)
            let per = max(count / n, 1)
            var peaks = (0..<n).map { b -> Float in
                var m: Float = 0
                for i in (b * per)..<min((b + 1) * per, count) { m = max(m, abs(ch[i])) }
                return m
            }
            let top = peaks.max() ?? 1
            if top > 0 { peaks = peaks.map { $0 / top } }
            out = peaks.map { CGFloat(max(0.08, sqrt($0))) }
        }
        Self.cache[id + "\(n)"] = out
        return out
    }
    nonisolated(unsafe) private static var cache: [String: [CGFloat]] = [:]
}

/// A sound as the library shows it, worked out once when the bank loads.
struct SFXRow: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: SFXKind
    let group: String
    let duration: String
    let bars: [CGFloat]
    /// Lowercased name, id and kind, for the search.
    let key: String

    init(_ s: SFXSound) {
        id = s.id; name = s.name; kind = s.kind; group = s.group.name; duration = s.duration; bars = s.bars(28)
        key = (s.name + " " + s.id + " " + s.kind.label + " " + s.group.name).lowercased()
    }
}

/// earshot's bank, read once from `sfx list --json`.
@MainActor
final class SoundBank: ObservableObject {
    static let shared = SoundBank()
    /// The last pill: every sound.
    static let all = "All"
    @Published private(set) var rows: [SFXRow] = []
    /// Group names in page order, only those with sounds.
    private(set) var groups: [String] = []
    private(set) var counts: [String: Int] = [:]
    @Published private(set) var error: String?
    private var loading = false

    private init() {}
    /// A fixed list, for snapshots.
    init(sounds: [SFXSound]) { set(sounds) }

    private func set(_ sounds: [SFXSound]) {
        let order = (SFXGroup.all + [SFXGroup.more]).map(\.name)
        let made = sounds.map(SFXRow.init)
        counts = Dictionary(grouping: made, by: \.group).mapValues(\.count)
        groups = order.filter { counts[$0] != nil }
        // Group order, so the first pill's sounds are the first ones made ahead.
        rows = made.sorted { (order.firstIndex(of: $0.group) ?? 99) < (order.firstIndex(of: $1.group) ?? 99) }
    }

    func load(_ python: String) {
        guard rows.isEmpty, !loading else { return }
        loading = true
        error = nil
        Task.detached {
            let (out, ok) = SoundFXSetup.earshot(python, ["sfx", "list", "--json"])
            struct List: Decodable { let sounds: [SFXSound] }
            let list = ok ? (try? JSONDecoder().decode(List.self, from: out))?.sounds : nil
            await MainActor.run {
                self.loading = false
                if let list {
                    self.set(list)
                    SoundFXPlayer.shared.makeAhead(self.rows.map(\.id), python: python)
                } else {
                    self.error = "Takes could not read the sounds. Turn Sound FX off and on, or install it again."
                }
            }
        }
    }
}

/// Plays one sound at a time: a bundled preview, or a bank sound earshot renders on the first play.
@MainActor
final class SoundFXPlayer: ObservableObject {
    static let shared = SoundFXPlayer()
    @Published private(set) var playing: String?
    @Published private(set) var loading: String?
    private var audio: AVAudioPlayer?
    private var watch: Timer?

    private init() {}
    /// A fixed state, for snapshots.
    init(playing: String?) { self.playing = playing }

    nonisolated static let cache = URL(fileURLWithPath: ("~/Library/Caches/Takes/sfx" as NSString).expandingTildeInPath)
    private var ahead = false

    /// How much of the playing sound is heard, 0...1.
    var heard: Double { audio.map { $0.currentTime / max($0.duration, 0.01) } ?? 0 }

    nonisolated static func file(_ id: String) -> URL { cache.appending(path: id.replacingOccurrences(of: "/", with: "-") + ".wav") }

    /// Makes every sound not in the cache yet, in one quiet background process, so a play starts at once.
    /// One process: starting earshot costs more than most sounds.
    func makeAhead(_ ids: [String], python: String) {
        guard !ahead else { return }
        let todo = ids.filter { !FileManager.default.fileExists(atPath: Self.file($0).path) }
        guard !todo.isEmpty else { return }
        ahead = true
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
            let pairs = todo.map { [$0, Self.file($0).path] }
            let list = String(decoding: (try? JSONSerialization.data(withJSONObject: pairs)) ?? Data("[]".utf8), as: UTF8.self)
            _ = SoundFXSetup.earshot(python, [], code: Self.aheadScript, input: list)
        }
    }

    /// Reads [[id, path], ...] on stdin; writes each WAV beside its path and moves it in, so a half-made file never plays.
    nonisolated static let aheadScript = """
    import json, os, sys
    os.environ.setdefault("EARSHOT_THREADS", "1")
    try: os.nice(15)
    except Exception: pass
    from earshot.forge.sfx import sfx_render
    for sid, path in json.load(sys.stdin):
        if os.path.exists(path): continue
        try:
            sfx_render(sid, out=path + ".part.wav", sr=44100)
            os.replace(path + ".part.wav", path)
        except Exception as e:
            print(sid, e, file=sys.stderr)
    """

    func toggle(_ id: String, file: URL?) {
        if playing == id { stop(); return }
        guard let file else { return }
        play(id, file)
    }

    func toggle(_ id: String, python: String) {
        if playing == id || loading == id { stop(); loading = nil; return }
        let file = Self.file(id)
        if FileManager.default.fileExists(atPath: file.path) { play(id, file); return }
        stop()
        loading = id
        Task.detached {
            try? FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
            let part = file.path + ".one.wav"
            let (_, made) = SoundFXSetup.earshot(python, ["sfx", "render", id, "-o", part, "--sr", "44100"])
            let ok = made && rename(part, file.path) == 0
            await MainActor.run {
                guard self.loading == id else { return }
                self.loading = nil
                if ok { self.play(id, file) }
            }
        }
    }

    private func play(_ id: String, _ file: URL) {
        stop()
        audio = try? AVAudioPlayer(contentsOf: file)
        guard let audio else { return }
        audio.play()
        playing = id
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.audio?.isPlaying == false { self?.stop() } }
        }
    }

    func stop() {
        audio?.stop()
        audio = nil
        watch?.invalidate()
        watch = nil
        playing = nil
    }
}

private func hex(_ v: UInt32) -> Color { Color(nsColor: NSColor(hex: v)) }

/// Where earshot is and installing it. The takes server looks in the same places (sfx_python).
@MainActor
final class SoundFXSetup: ObservableObject {
    static let shared = SoundFXSetup()
    enum Part: String { case sounds, design }

    /// Takes' own install. EARSHOT_HOME (its model cache) is home/ next to the venv.
    nonisolated static let dir = ("~/Library/Application Support/Takes/earshot" as NSString).expandingTildeInPath
    /// The pinned earshot: a new version is a change here, tested first.
    nonisolated static let source = "earshot @ https://github.com/Leonxlnx/earshot/archive/925ebe56a1b755e5d354ab642bb8f344440cfa9c.tar.gz"

    static var candidates: [String] {
        var c = [dir + "/.venv/bin/python"]
        if let e = ProcessInfo.processInfo.environment["TAKES_EARSHOT"], !e.isEmpty { c.insert(e, at: 0) }
        return c
    }

    @Published private(set) var python: String?
    @Published private(set) var canDesign = false
    @Published private(set) var running: Part?
    @Published private(set) var step = ""
    @Published private(set) var failed: [Part: String] = [:]
    /// Where the last failed install stopped, 0...1, for the hero's bars.
    @Published private(set) var failedAt: Double = 0

    /// Each part's steps, as the script prints them; uv comes first only when it is missing.
    nonisolated static let steps: [Part: [String]] = [
        .sounds: ["Getting uv…", "Making its Python…", "Getting earshot…", "Checking the sounds…"],
        .design: ["Getting uv…", "Getting torch, about 400 MB…", "Getting the AI models, about 1.1 GB…"],
    ]
    var stepCount: Int { running.flatMap { Self.steps[$0]?.count } ?? 0 }
    var stepIndex: Int { running.flatMap { Self.steps[$0]?.firstIndex(of: step) } ?? 0 }
    /// 0...1 through the running install, the middle of the current step.
    var progress: Double { stepCount == 0 ? 0 : (Double(stepIndex) + 0.5) / Double(stepCount) }
    /// "Step 3 of 4 · Getting earshot".
    var stepLine: String {
        guard stepCount > 0, Self.steps[running ?? .sounds]?.contains(step) == true else { return step }
        return "Step \(stepIndex + 1) of \(stepCount) · " + step.replacingOccurrences(of: "…", with: "")
    }

    private init() { refresh() }

    /// A fixed state, for snapshots of the card.
    init(python: String?, canDesign: Bool, running: Part? = nil, step: String = "", failed: [Part: String] = [:], failedAt: Double = 0) {
        self.python = python; self.canDesign = canDesign; self.running = running; self.step = step; self.failed = failed
        self.failedAt = failedAt
    }

    func refresh() {
        python = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        canDesign = python.map(Self.hasTorch) ?? false
    }

    /// torch is what sound design adds; the ready sounds run without it.
    nonisolated static func hasTorch(_ python: String) -> Bool {
        let lib = URL(fileURLWithPath: python).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []
        return versions.contains { FileManager.default.fileExists(atPath: lib.path + "/\($0)/site-packages/torch") }
    }

    func install(_ part: Part) {
        guard running == nil else { return }
        running = part
        failed[part] = nil
        step = "Starting…"
        // Design adds to the venv this card shows; with none yet, it goes into Takes' own.
        let venvPython = part == .design ? (python ?? Self.dir + "/.venv/bin/python") : Self.dir + "/.venv/bin/python"
        let script = Self.script(part, venvPython: venvPython)
        Task.detached {
            let result = Self.run(script) { line in Task { @MainActor in SoundFXSetup.shared.step = line } }
            await MainActor.run {
                let s = SoundFXSetup.shared
                if let error = result { s.failed[part] = error; s.failedAt = s.progress }
                s.running = nil
                s.refresh()
            }
        }
    }

    /// The install as one shell script. Lines that start with "STEP " show on the card.
    nonisolated static func script(_ part: Part, venvPython: String) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let venv = URL(fileURLWithPath: venvPython).deletingLastPathComponent().deletingLastPathComponent().path
        var s = """
        set -e
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        UV=$(command -v uv || true)
        if [ -z "$UV" ]; then
          echo "STEP Getting uv…"
          curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null
          UV="$HOME/.local/bin/uv"
        fi
        PY=\(q(venvPython))
        export EARSHOT_HOME=\(q(dir + "/home"))

        """
        switch part {
        case .sounds:
            s += """
            echo "STEP Making its Python…"
            rm -rf \(q(venv))
            mkdir -p \(q(dir))
            "$UV" venv -q --python 3.12 \(q(venv))
            echo "STEP Getting earshot…"
            "$UV" pip install -q --python "$PY" --no-deps \(q(source))
            "$UV" pip install -q --python "$PY" numpy scipy soundfile soxr librosa pyloudnorm
            echo "STEP Checking the sounds…"
            EARSHOT_OFFLINE=1 "$PY" -I -m earshot sfx list --json >/dev/null

            """
        case .design:
            s += """
            echo "STEP Getting torch, about 400 MB…"
            "$UV" pip install -q --python "$PY" torch --index-url https://download.pytorch.org/whl/cpu
            "$UV" pip install -q --python "$PY" transformers scikit-learn pillow matplotlib
            echo "STEP Getting the AI models, about 1.1 GB…"
            "$PY" -I -m earshot doctor --fetch >/dev/null

            """
        }
        return s
    }

    /// Runs earshot from its venv, offline, with Takes' model cache: its stdout, and whether it worked.
    /// With `code`, runs that Python instead of the CLI, with `input` on its stdin.
    nonisolated static func earshot(_ python: String, _ args: [String], code: String? = nil, input: String? = nil) -> (Data, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = code.map { ["-I", "-c", $0] } ?? (["-I", "-m", "earshot"] + args)
        var env = ProcessInfo.processInfo.environment
        env["EARSHOT_OFFLINE"] = "1"
        if env["EARSHOT_HOME"] == nil, python.hasPrefix(dir) { env["EARSHOT_HOME"] = dir + "/home" }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { p.standardInput = stdin }
        do { try p.run() } catch { return (Data(), false) }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, p.terminationStatus == 0)
    }

    /// Runs the script; nil when it worked, else its last error line.
    nonisolated static func run(_ script: String, step: @escaping (String) -> Void) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("STEP ") { step(String(line.dropFirst(5))) }
        }
        do { try p.run() } catch { return "Could not start the install: \(error.localizedDescription)" }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus == 0 { return nil }
        let last = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return "The install stopped: " + (last.isEmpty ? "it ended with code \(p.terminationStatus)." : String(last.prefix(160)))
    }
}
