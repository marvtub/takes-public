import SwiftUI
import UIKit

// The phone's own look (2026-10-04: "I wanna be able to choose so it shouldn't be coupled"): the
// same palettes and accents as the Mac's Settings › Appearance, picked here and kept on the phone.
// Palette reads its colors from here. Observable, so every view that draws with a Palette color
// redraws when the look changes.

@Observable
final class Look: @unchecked Sendable {
    static let shared = Look()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    }

    var mode: Mode { didSet { save("lookMode", mode.rawValue) } }
    var palette: ThemePalette { didSet { save("lookPalette", palette.rawValue); rebuild() } }
    /// Nil: the palette's own accent.
    var accent: ThemeAccent? { didSet { save("lookAccent", accent?.rawValue); rebuild() } }
    private(set) var colors: LookColors

    private init() {
        let d = UserDefaults.standard
        let palette = d.string(forKey: "lookPalette").flatMap(ThemePalette.init) ?? .takes
        let accent = d.string(forKey: "lookAccent").flatMap(ThemeAccent.init)
        mode = d.string(forKey: "lookMode").flatMap(Mode.init) ?? .system
        self.palette = palette
        self.accent = accent
        colors = LookColors(palette.spec, accent: accent)
    }

    var isDefault: Bool { mode == .system && palette == .takes && accent == nil }

    func reset() {
        mode = .system
        palette = .takes
        accent = nil
    }

    private func rebuild() { colors = LookColors(palette.spec, accent: accent) }

    private func save(_ key: String, _ value: String?) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// One color, light and dark.
struct Pair: Equatable {
    let light: UInt32
    let dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
    func value(dark d: Bool) -> UInt32 { d ? dark : light }
    var color: Color { Color(light: light, dark: dark) }
}

/// A palette: the page, the type and the accent that goes with them. The values are the Mac's.
struct PaletteSpec {
    var accent, accentInk, accentSoft: Pair
    var ink, muted, faint, paper, canvas, well, border: Pair
    /// The Mac's sidebar: the list of videos.
    var surface: Pair
}

enum ThemePalette: String, CaseIterable, Identifiable {
    case takes, graphite, sand, forest, plum
    var id: String { rawValue }

    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var blurb: String {
        switch self {
        case .takes: "Navy on white, clear blue"
        case .graphite: "Neutral grays, no tint"
        case .sand: "Warm paper, terracotta"
        case .forest: "Soft greens, calm"
        case .plum: "Violet, a little playful"
        }
    }

    var spec: PaletteSpec {
        switch self {
        case .takes:  // the brand kit (2026-10-02)
            PaletteSpec(accent: Pair(0x3B82F6, 0x5B9BFF), accentInk: Pair(0x2563EB, 0x8AB8FF), accentSoft: Pair(0xE8F0FE, 0x1A2B4A),
                        ink: Pair(0x102A56, 0xEEF2FA), muted: Pair(0x4A5B7C, 0xA9B4CA), faint: Pair(0x8E9AB2, 0x6B7791),
                        paper: Pair(0xFFFFFF, 0x131B2D), canvas: Pair(0xF6F8FC, 0x0F1626), well: Pair(0xEEF2F8, 0x1C2639),
                        border: Pair(0xE7ECF4, 0x222D44), surface: Pair(0xF1F4FA, 0x0C1220))
        case .graphite:
            PaletteSpec(accent: Pair(0x0A7AFF, 0x0A84FF), accentInk: Pair(0x0064D1, 0x64A8FF), accentSoft: Pair(0xE8F1FF, 0x16263A),
                        ink: Pair(0x1D1D1F, 0xF5F5F7), muted: Pair(0x55555A, 0xA1A1A6), faint: Pair(0x9A9AA0, 0x6E6E73),
                        paper: Pair(0xFFFFFF, 0x1E1E20), canvas: Pair(0xF5F5F7, 0x161618), well: Pair(0xEDEDF0, 0x2A2A2D),
                        border: Pair(0xE4E4E7, 0x2C2C2F), surface: Pair(0xEFEFF1, 0x111113))
        case .sand:
            PaletteSpec(accent: Pair(0xD9622B, 0xF0884F), accentInk: Pair(0xB4501F, 0xF5A97B), accentSoft: Pair(0xFBEBE1, 0x3A2418),
                        ink: Pair(0x2E2620, 0xF2EADF), muted: Pair(0x6B5F53, 0xB7AB9B), faint: Pair(0xA3978A, 0x7D7264),
                        paper: Pair(0xFFFDF9, 0x1F1B17), canvas: Pair(0xF7F2EA, 0x181512), well: Pair(0xF1EADF, 0x2B261F),
                        border: Pair(0xE9E0D2, 0x302A24), surface: Pair(0xF1EADF, 0x13110E))
        case .forest:
            PaletteSpec(accent: Pair(0x0F9F6E, 0x34D399), accentInk: Pair(0x0B7D57, 0x6EE7B7), accentSoft: Pair(0xE1F5EC, 0x12322A),
                        ink: Pair(0x133229, 0xE8F3EF), muted: Pair(0x4A665E, 0xA1BBB3), faint: Pair(0x8BA49C, 0x6A8179),
                        paper: Pair(0xFFFFFF, 0x12201C), canvas: Pair(0xF3F8F5, 0x0D1814), well: Pair(0xEAF2EE, 0x1B2D27),
                        border: Pair(0xDFEAE5, 0x1F312B), surface: Pair(0xECF3EF, 0x0A1310))
        case .plum:
            PaletteSpec(accent: Pair(0x8B5CF6, 0xA78BFA), accentInk: Pair(0x7C3AED, 0xC4B5FD), accentSoft: Pair(0xF1EBFE, 0x2A1F45),
                        ink: Pair(0x26173A, 0xF1EBF8), muted: Pair(0x625677, 0xB4A8C6), faint: Pair(0x9D91B0, 0x776B8A),
                        paper: Pair(0xFFFFFF, 0x1B1527), canvas: Pair(0xF8F5FC, 0x140F1E), well: Pair(0xF1ECF7, 0x271F35),
                        border: Pair(0xEAE4F3, 0x2D243B), surface: Pair(0xF2EEF8, 0x100C18))
        }
    }
}

enum ThemeAccent: String, CaseIterable, Identifiable {
    case blue, violet, green, orange, pink, teal
    var id: String { rawValue }
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var accent: Pair {
        switch self {
        case .blue: Pair(0x3B82F6, 0x5B9BFF)
        case .violet: Pair(0x8B5CF6, 0xA78BFA)
        case .green: Pair(0x10A36A, 0x34D399)
        case .orange: Pair(0xEA6A1F, 0xFB923C)
        case .pink: Pair(0xE64A8E, 0xF472B6)
        case .teal: Pair(0x0E9F9A, 0x2DD4BF)
        }
    }

    var ink: Pair {
        switch self {
        case .blue: Pair(0x2563EB, 0x8AB8FF)
        case .violet: Pair(0x7C3AED, 0xC4B5FD)
        case .green: Pair(0x0B7D57, 0x6EE7B7)
        case .orange: Pair(0xC2410C, 0xFDBA74)
        case .pink: Pair(0xBE185D, 0xF9A8D4)
        case .teal: Pair(0x0F766E, 0x5EEAD4)
        }
    }
}

/// The palette and accent as ready-made colors. Each one follows light and dark by itself.
struct LookColors {
    let spec: PaletteSpec
    let accent, accentInk, accentSoft, ink, muted, faint, paper, canvas, well, border, surface, shadow: Color

    init(_ base: PaletteSpec, accent pick: ThemeAccent?) {
        var s = base
        if let pick {
            s.accent = pick.accent
            s.accentInk = pick.ink
            // The soft fill: the accent faintly over the page, as on the Mac.
            s.accentSoft = Pair(Self.mix(pick.accent.light, over: s.paper.light, 0.11),
                                Self.mix(pick.accent.dark, over: s.paper.dark, 0.2))
        }
        spec = s
        accent = s.accent.color; accentInk = s.accentInk.color; accentSoft = s.accentSoft.color
        ink = s.ink.color; muted = s.muted.color; faint = s.faint.color; paper = s.paper.color
        canvas = s.canvas.color; well = s.well.color; border = s.border.color; surface = s.surface.color
        shadow = Color(light: s.ink.light, dark: 0x000000).opacity(0.10)
    }

    static func mix(_ top: UInt32, over bottom: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double(v >> shift & 0xFF) }
        var out: UInt32 = 0
        for shift in [UInt32(16), 8, 0] {
            let v = ch(bottom, shift) + (ch(top, shift) - ch(bottom, shift)) * t
            out |= UInt32(max(0, min(255, v.rounded()))) << shift
        }
        return out
    }
}

// MARK: - The picker

/// Mode, theme and accent for this phone, each with a small preview. The Mac keeps its own.
struct AppearanceSheet: View {
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var look: Look { Look.shared }

    var body: some View {
        BrandSheet(title: "Appearance", cancel: "Done", close: close) {
            Button("Reset") { withAnimation(Brand.quick) { look.reset() } }
                .buttonStyle(.pill(.quiet, small: true))
                .disabled(look.isDefault)
        } content: {
            FormCard(title: "Mode") {
                HStack(spacing: 10) {
                    ForEach(Look.Mode.allCases) { m in
                        tile(selected: look.mode == m, name: m.name) {
                            switch m {
                            case .light: MiniPhone(spec: look.colors.spec, dark: false)
                            case .dark: MiniPhone(spec: look.colors.spec, dark: true)
                            case .system:
                                ZStack {
                                    MiniPhone(spec: look.colors.spec, dark: false)
                                    MiniPhone(spec: look.colors.spec, dark: true).mask(HalfMask())
                                }
                            }
                        } action: { look.mode = m }
                    }
                }
            }
            FormCard(title: "Theme") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 14) {
                    ForEach(ThemePalette.allCases) { p in
                        tile(selected: look.palette == p, name: p.name) {
                            MiniPhone(spec: LookColors(p.spec, accent: look.accent).spec, dark: scheme == .dark)
                        } action: { look.palette = p }
                    }
                }
            }
            FormCard(title: "Accent") {
                HStack(spacing: 6) {
                    swatch(nil)
                    ForEach(ThemeAccent.allCases) { swatch($0) }
                }
                Text(look.accent?.name ?? "From the theme").font(.inter(.footnote)).foregroundStyle(Palette.muted)
                    .contentTransition(.opacity)
            }
            Text("Only for this iPhone. The Mac keeps its own look.")
                .font(.inter(.footnote)).foregroundStyle(Palette.faint).padding(.horizontal, 4)
        }
        .animation(Brand.quick, value: look.palette)
        .animation(Brand.quick, value: look.accent)
        .animation(Brand.quick, value: look.mode)
    }

    /// A preview with a name under it; the picked one gets an accent ring.
    private func tile(selected: Bool, name: String, @ViewBuilder preview: () -> some View, action: @escaping () -> Void) -> some View {
        Button {
            Brand.select()
            action()
        } label: {
            VStack(spacing: 6) {
                preview()
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 2))
                HStack(spacing: 4) {
                    Text(name).font(.inter(.footnote, .semibold)).foregroundStyle(Palette.ink)
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.accent) }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(_ a: ThemeAccent?) -> some View {
        let pair = a?.accent ?? look.palette.spec.accent
        let on = look.accent == a
        return Button {
            Brand.select()
            look.accent = a
        } label: {
            Circle().fill(pair.color)
                .frame(width: 30, height: 30)
                .overlay { if a == nil { Text("A").font(.inter(size: 12, .bold)).foregroundStyle(.white) } }
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Palette.ink.opacity(0.7) : .clear, lineWidth: 2))
                .frame(maxWidth: .infinity)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(haptic: false))
        .accessibilityLabel(a?.name ?? "The theme's own accent")
        .accessibilityAddTraits(on ? .isSelected : [])
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

/// A tiny Takes screen in one palette: a title, two cards with lines, the accent pill.
private struct MiniPhone: View {
    let spec: PaletteSpec
    let dark: Bool

    private func c(_ p: Pair) -> Color {
        let v = p.value(dark: dark)
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(c(spec.ink)).frame(width: 34, height: 5)
            ForEach(0..<2, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(c(spec.ink).opacity(0.8)).frame(width: [38, 30][i], height: 3)
                    Capsule().fill(c(spec.muted).opacity(0.5)).frame(width: [28, 34][i], height: 2.5)
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(c(spec.paper), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(c(spec.border), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
            Capsule().fill(c(spec.accent)).frame(width: 30, height: 9).frame(maxWidth: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c(spec.canvas))
    }
}

/// Private for now (2026-10-04), like Features on the Mac: the public export turns it off.
enum Features {
    static let socialBoards = false
    /// The blog's Article side of the Post tab (2026-10-09), as the Mac's Features.blog.
    static let blog = false
}
