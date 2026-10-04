import AppKit
import SwiftUI

/// The picked look (2026-10-04): light, dark or the system's mode, one of a few palettes, and an
/// accent. Settings › Appearance changes it; Theme reads its colors from here. Observable, so every
/// view that draws with a Theme color redraws when the look changes.
@Observable
final class Look: @unchecked Sendable {
    static let shared = Look()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var mode: Mode { didSet { save("lookMode", mode.rawValue); applyMode() } }
    var palette: ThemePalette { didSet { save("lookPalette", palette.rawValue); rebuild() } }
    /// Nil: the palette's own accent.
    var accent: ThemeAccent? { didSet { save("lookAccent", accent?.rawValue); rebuild() } }
    private(set) var colors: ThemeColors

    private init() {
        let d = UserDefaults.standard
        let mode = d.string(forKey: "lookMode").flatMap(Mode.init) ?? .system
        let palette = d.string(forKey: "lookPalette").flatMap(ThemePalette.init) ?? .takes
        let accent = d.string(forKey: "lookAccent").flatMap(ThemeAccent.init)
        self.mode = mode
        self.palette = palette
        self.accent = accent
        colors = ThemeColors(palette.spec, accent: accent)
    }

    var isDefault: Bool { mode == .system && palette == .takes && accent == nil }

    func reset() {
        mode = .system
        palette = .takes
        accent = nil
    }

    /// Light or dark for the whole app. Call once at launch, then it follows `mode`.
    func applyMode() {
        NSApp?.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func rebuild() { colors = ThemeColors(palette.spec, accent: accent) }

    private func save(_ key: String, _ value: String?) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// One color, light and dark.
struct Pair {
    let light: UInt32
    let dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }
    func value(dark d: Bool) -> UInt32 { d ? dark : light }
}

/// A palette: the page, the type and the accent that goes with them.
struct PaletteSpec {
    var accent, accentInk, accentSoft, secondary: Pair
    var ink, muted, faint, paper, canvas, surface, border: Pair
    /// A panel one step up from the page, in the palette's own hue: the chat.
    var raised: Pair
    /// The camera and prompter while you record: always dark.
    var stage: UInt32
}

enum ThemePalette: String, CaseIterable, Identifiable {
    case takes, graphite, sand, forest, plum
    var id: String { rawValue }

    var name: String {
        switch self {
        case .takes: "Takes"
        case .graphite: "Graphite"
        case .sand: "Sand"
        case .forest: "Forest"
        case .plum: "Plum"
        }
    }

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
                        secondary: Pair(0x102A56, 0xA9C1EC), ink: Pair(0x102A56, 0xEEF2FA), muted: Pair(0x4A5B7C, 0xA9B4CA),
                        faint: Pair(0x8E9AB2, 0x6B7791), paper: Pair(0xFFFFFF, 0x131B2D), canvas: Pair(0xF6F8FC, 0x0F1626),
                        surface: Pair(0xF1F4FA, 0x0C1220), border: Pair(0xE7ECF4, 0x222D44), raised: Pair(0xF7F9FE, 0x1B2640),
                        stage: 0x0A1222)
        case .graphite:
            PaletteSpec(accent: Pair(0x0A7AFF, 0x0A84FF), accentInk: Pair(0x0064D1, 0x64A8FF), accentSoft: Pair(0xE8F1FF, 0x16263A),
                        secondary: Pair(0x1D1D1F, 0xD1D1D6), ink: Pair(0x1D1D1F, 0xF5F5F7), muted: Pair(0x55555A, 0xA1A1A6),
                        faint: Pair(0x9A9AA0, 0x6E6E73), paper: Pair(0xFFFFFF, 0x1E1E20), canvas: Pair(0xF5F5F7, 0x161618),
                        surface: Pair(0xEFEFF1, 0x111113), border: Pair(0xE4E4E7, 0x2C2C2F), raised: Pair(0xFAFAFB, 0x262629),
                        stage: 0x0E0E10)
        case .sand:
            PaletteSpec(accent: Pair(0xD9622B, 0xF0884F), accentInk: Pair(0xB4501F, 0xF5A97B), accentSoft: Pair(0xFBEBE1, 0x3A2418),
                        secondary: Pair(0x3B2F25, 0xD9C9B5), ink: Pair(0x2E2620, 0xF2EADF), muted: Pair(0x6B5F53, 0xB7AB9B),
                        faint: Pair(0xA3978A, 0x7D7264), paper: Pair(0xFFFDF9, 0x1F1B17), canvas: Pair(0xF7F2EA, 0x181512),
                        surface: Pair(0xF1EADF, 0x13110E), border: Pair(0xE9E0D2, 0x302A24), raised: Pair(0xFFFCF5, 0x27221C),
                        stage: 0x15110D)
        case .forest:
            PaletteSpec(accent: Pair(0x0F9F6E, 0x34D399), accentInk: Pair(0x0B7D57, 0x6EE7B7), accentSoft: Pair(0xE1F5EC, 0x12322A),
                        secondary: Pair(0x143A30, 0xA7D3C4), ink: Pair(0x133229, 0xE8F3EF), muted: Pair(0x4A665E, 0xA1BBB3),
                        faint: Pair(0x8BA49C, 0x6A8179), paper: Pair(0xFFFFFF, 0x12201C), canvas: Pair(0xF3F8F5, 0x0D1814),
                        surface: Pair(0xECF3EF, 0x0A1310), border: Pair(0xDFEAE5, 0x1F312B), raised: Pair(0xF7FBF9, 0x182A25),
                        stage: 0x08130F)
        case .plum:
            PaletteSpec(accent: Pair(0x8B5CF6, 0xA78BFA), accentInk: Pair(0x7C3AED, 0xC4B5FD), accentSoft: Pair(0xF1EBFE, 0x2A1F45),
                        secondary: Pair(0x2A1640, 0xCDBEF0), ink: Pair(0x26173A, 0xF1EBF8), muted: Pair(0x625677, 0xB4A8C6),
                        faint: Pair(0x9D91B0, 0x776B8A), paper: Pair(0xFFFFFF, 0x1B1527), canvas: Pair(0xF8F5FC, 0x140F1E),
                        surface: Pair(0xF2EEF8, 0x100C18), border: Pair(0xEAE4F3, 0x2D243B), raised: Pair(0xFBF8FE, 0x231B33),
                        stage: 0x0F0A18)
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
struct ThemeColors {
    let spec: PaletteSpec
    let accent, accentInk, accentSoft, secondary: Color
    let ink, muted, faint, paper, canvas, surface, border, raised, hover, stage, shadow: Color
    let paperNS, inkNS, stageNS: NSColor

    init(_ base: PaletteSpec, accent pick: ThemeAccent?) {
        var s = base
        if let pick {
            s.accent = pick.accent
            s.accentInk = pick.ink
            // The soft fill: the accent faintly over the page.
            s.accentSoft = Pair(Self.mix(pick.accent.light, over: s.paper.light, 0.11),
                                Self.mix(pick.accent.dark, over: s.paper.dark, 0.2))
        }
        spec = s
        func c(_ p: Pair, _ alpha: CGFloat = 1) -> Color { Color(nsColor: Self.ns(p, alpha)) }
        accent = c(s.accent); accentInk = c(s.accentInk); accentSoft = c(s.accentSoft); secondary = c(s.secondary)
        ink = c(s.ink); muted = c(s.muted); faint = c(s.faint); paper = c(s.paper)
        canvas = c(s.canvas); surface = c(s.surface); border = c(s.border); raised = c(s.raised)
        hover = c(s.ink, 0.05)
        stageNS = NSColor(hex: s.stage)
        stage = Color(nsColor: stageNS)
        shadow = Color(nsColor: NSColor(hex: s.ink.light)).opacity(0.08)
        paperNS = Self.ns(s.paper)
        inkNS = Self.ns(s.ink)
    }

    static func ns(_ p: Pair, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { a in
            NSColor(hex: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark : p.light).withAlphaComponent(alpha)
        }
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
