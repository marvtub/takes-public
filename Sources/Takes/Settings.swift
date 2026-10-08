import AppKit
import SwiftUI

/// Takes › Settings (⌘,): Appearance (mode, palette, accent, text size), Higgsfield (AI video,
/// 2026-10-06), Voices (ElevenLabs), the archived sessions, which the sidebar no longer shows, and
/// in the admin build what is private and what is public (2026-10-07).
struct SettingsView: View {
    var library: Library
    @AppStorage("settingsPage") private var page = SettingsPage.appearance.rawValue

    enum SettingsPage: String, CaseIterable, Identifiable {
        case appearance, search, higgsfield, voices, archived, privacy
        var id: String { rawValue }
        var name: String {
            switch self {
            case .appearance: return "Appearance"
            case .search: return "Search"
            case .higgsfield: return "Higgsfield"
            case .voices: return "Voices"
            case .archived: return "Archived"
            case .privacy: return "Private"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .search: return "magnifyingglass"
            case .higgsfield: return "sparkles"
            case .voices: return "waveform"
            case .archived: return "archivebox"
            case .privacy: return "lock"
            }
        }
        /// Private shows only where there is a list (the admin build).
        static var shown: [SettingsPage] { allCases.filter { $0 != .privacy || !PrivatePlugins.features.isEmpty } }
    }

    var body: some View {
        let current = SettingsPage(rawValue: page).flatMap { SettingsPage.shown.contains($0) ? $0 : nil } ?? .appearance
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(Theme.display(17)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.bottom, 12)
                ForEach(SettingsPage.shown) { p in
                    Button { withAnimation(Theme.motion) { page = p.rawValue } } label: {
                        Label(p.name, systemImage: p.icon)
                            .font(Theme.sans(13, p == current ? .semibold : .regular))
                            .foregroundStyle(p == current ? Theme.ink : Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(p == current ? Theme.hover : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 20)
            .frame(width: 180)
            .background(Theme.surface)
            Rule(vertical: true)
            Group {
                switch current {
                case .appearance: AppearancePage()
                case .search: SearchPage()
                case .higgsfield: HiggsfieldPage()
                case .voices: VoicesPage()
                case .archived: ArchivedPage(library: library)
                case .privacy: PrivatePage(features: PrivatePlugins.features)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .frame(width: 760, height: 560)
    }
}

/// The archived sessions: out of the sidebar, still on disk.
private struct ArchivedPage: View {
    @Environment(AppModel.self) var app
    @Environment(\.openWindow) private var openWindow
    var library: Library

    var body: some View {
        let archived = library.projects.flatMap { p in
            (library.grouped[p.url] ?? []).filter(\.archived).map { (project: p.name, session: $0) }
        }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Archived sessions").font(Theme.display(17)).foregroundStyle(Theme.ink)
                Text("Out of the sidebar, still on disk. Unarchive one to bring it back.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            .padding(20)
            Rule()
            if archived.isEmpty {
                Text("Nothing archived.").font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(archived, id: \.session.url) { item in
                            ArchivedRow(project: item.project, session: item.session, library: library) {
                                app.board = nil
                                library.select(item.session.url)
                                openWindow(id: "main")
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

private struct ArchivedRow: View {
    let project: String
    let session: SessionSummary
    var library: Library
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(project) · \(SessionList.when(session.createdAt)) · \(session.takeCount) take\(session.takeCount == 1 ? "" : "s")")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { library.reveal(session.url) } label: {
                Image(systemName: "folder").font(.system(size: 12)).frame(width: 26, height: 26)
            }
            .buttonStyle(IconButtonStyle())
            .help("Show in Finder")
            Button("Unarchive") {
                library.setArchived([session.url], false)
                open()
            }
            .help("Back into the sidebar, and open it")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.hover : .clear))
        .onHover { hover = $0 }
    }
}

// MARK: - Private

/// What is private and what is public (2026-10-07), from Plugins/Private/FeatureMap.swift.
struct PrivatePage: View {
    let features: [FeatureEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Private and public").font(Theme.display(17)).foregroundStyle(Theme.ink)
                Text("This build has everything. The public copy on GitHub has only what is public.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            .padding(20)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(FeatureEntry.Kind.allCases, id: \.self) { kind in
                        let rows = features.filter { $0.kind == kind }
                        if !rows.isEmpty { group(kind, rows) }
                    }
                }
                .padding(20)
            }
        }
    }

    private func group(_ kind: FeatureEntry.Kind, _ rows: [FeatureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(kind == .shipped ? Theme.live : kind == .ownFiles ? Theme.faint : Theme.accent).frame(width: 6, height: 6)
                Text(kind.rawValue.uppercased()).font(Theme.sans(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                Text("\(rows.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Rule().opacity(0.6) }
                    row(f)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func row(_ f: FeatureEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: f.icon).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                Text(f.what).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !f.code.isEmpty {
                Text(f.code.filter { !$0.hasPrefix("plugin ") }.joined(separator: "\n"))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

// MARK: - Appearance

/// Mode, palette, accent and text size, each with a small preview (2026-10-04, after Codex's page).
private struct AppearancePage: View {
    @Environment(\.colorScheme) private var scheme
    private var look: Look { Look.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Appearance").font(Theme.display(26)).foregroundStyle(Theme.ink)

                group("Mode") {
                    HStack(spacing: 14) {
                        ForEach(Look.Mode.allCases) { m in
                            tile(selected: look.mode == m, name: m.name) {
                                switch m {
                                case .light: MiniWindow(spec: look.colors.spec, dark: false)
                                case .dark: MiniWindow(spec: look.colors.spec, dark: true)
                                case .system:
                                    ZStack {
                                        MiniWindow(spec: look.colors.spec, dark: false)
                                        MiniWindow(spec: look.colors.spec, dark: true)
                                            .mask(HalfMask())
                                    }
                                }
                            } action: { look.mode = m }
                        }
                    }
                }

                group("Theme") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                        ForEach(ThemePalette.allCases) { p in
                            tile(selected: look.palette == p, name: p.name, blurb: p.blurb) {
                                MiniWindow(spec: ThemeColors(p.spec, accent: look.accent).spec, dark: scheme == .dark)
                            } action: { look.palette = p }
                        }
                    }
                }

                group("Accent") {
                    HStack(spacing: 12) {
                        swatch(nil)
                        ForEach(ThemeAccent.allCases) { swatch($0) }
                        Spacer(minLength: 0)
                        Text(look.accent?.name ?? "From the theme")
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            .contentTransition(.opacity)
                    }
                }

                group("Text size") {
                    Picker("", selection: Binding(get: { TextSize.shared.step }, set: { TextSize.shared.step = $0 })) {
                        ForEach(TextSize.factors.indices, id: \.self) { i in
                            Text(["Normal", "Large", "Larger"][i]).tag(i)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    .help("Also ⌘+ and ⌘−")
                }

                HStack {
                    Spacer()
                    Button("Reset to default") { withAnimation(Theme.motion) { look.reset() } }
                        .buttonStyle(BracketButtonStyle())
                        .disabled(look.isDefault)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            .animation(Theme.motion, value: look.palette)
            .animation(Theme.motion, value: look.accent)
            .animation(Theme.motion, value: look.mode)
        }
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    /// A preview with a name under it; the picked one gets an accent ring.
    private func tile(selected: Bool, name: String, blurb: String? = nil,
                      @ViewBuilder preview: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview()
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(name).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                    if let blurb { Text(blurb).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1) }
                }
                .padding(.horizontal, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .frame(maxWidth: 170)
    }

    private func swatch(_ a: ThemeAccent?) -> some View {
        let pair = a?.accent ?? look.palette.spec.accent
        let on = look.accent == a
        return Button { look.accent = a } label: {
            Circle().fill(Color(nsColor: ThemeColors.ns(pair)))
                .frame(width: 22, height: 22)
                .overlay {
                    if a == nil { Text("A").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                }
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Theme.ink.opacity(0.7) : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(a?.name ?? "The theme's own accent")
    }
}

/// The right half, slanted: the System tile shows light and dark side by side.
private struct HalfMask: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: g.size.width * 0.58, y: 0))
                p.addLine(to: CGPoint(x: g.size.width, y: 0))
                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                p.addLine(to: CGPoint(x: g.size.width * 0.42, y: g.size.height))
                p.closeSubpath()
            }
        }
    }
}

/// A tiny Takes window in one palette: sidebar, a card with lines, the accent button.
struct MiniWindow: View {
    let spec: PaletteSpec
    let dark: Bool

    private func c(_ p: Pair) -> Color { Color(nsColor: NSColor(hex: p.value(dark: dark))) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) {
                        Circle().fill(Color(nsColor: NSColor(hex: $0))).frame(width: 4, height: 4)
                    }
                }
                .padding(.bottom, 4)
                RoundedRectangle(cornerRadius: 2).fill(c(spec.ink).opacity(0.10)).frame(height: 7)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(c(spec.muted).opacity(0.55)).frame(width: [26, 20, 23][i], height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 44)
            .frame(maxHeight: .infinity)
            .background(c(spec.surface))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(c(spec.ink)).frame(width: 40, height: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(c(spec.muted).opacity(0.7)).frame(width: 56, height: 3)
                    Capsule().fill(c(spec.faint).opacity(0.7)).frame(width: 44, height: 3)
                    HStack(spacing: 4) {
                        Capsule().fill(c(spec.accent)).frame(width: 22, height: 7)
                        Capsule().fill(c(spec.accentSoft)).frame(width: 16, height: 7)
                    }
                    .padding(.top, 2)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(c(spec.paper)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(c(spec.border)))
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c(spec.canvas))
        }
    }
}
