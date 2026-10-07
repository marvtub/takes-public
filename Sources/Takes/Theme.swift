import AppKit
import CoreText
import SwiftUI

/// The look of Takes, in one place. Change a value here and the whole app follows.
///
/// Source: the Takes brand kit (2026-10-02). Cloud White, Deep Navy #102A56, Clear Blue #3B82F6,
/// Mist Gray #E7ECF4, Fresh Mint #DFF7E9. Nunito for headings, Inter for everything else.
/// Calm and friendly: navy ink on white, one blue accent for meaning, mint for "it went out".
/// That is the "Takes" palette; Settings › Appearance offers others (Look.swift).
enum Theme {
    // MARK: Colors
    // From the picked palette and accent (Look, Settings › Appearance). Each follows light and dark.
    private static var c: ThemeColors { Look.shared.colors }
    static var accent: Color { c.accent }          // ready, the hook, selection
    static var accentInk: Color { c.accentInk }    // small accent text, interaction
    static var accentSoft: Color { c.accentSoft }  // soft fill behind accent text
    static var secondary: Color { c.secondary }    // the ink as a colour, used sparingly
    static let live       = dynamic(0x16A36A, 0x4FD69A)  // published (Fresh Mint, deep enough for text)
    static let liveSoft   = dynamic(0xDFF7E9, 0x153829)  // Fresh Mint fill
    static let warn       = dynamic(0xE08A00, 0xFFB547)  // needs attention: "needs update"
    static let danger     = dynamic(0xE5484D, 0xFF6B6F)  // recording, clipping, destructive
    static var ink: Color { c.ink }          // strong type
    static var muted: Color { c.muted }      // second strength: labels, meta
    static var faint: Color { c.faint }      // third strength: hints, counts
    static var paper: Color { c.paper }      // the page
    static var canvas: Color { c.canvas }    // behind cards (post, assets, sound)
    static var surface: Color { c.surface }  // the sidebar and quiet bars
    static var border: Color { c.border }    // hairlines
    static var raised: Color { c.raised }    // a panel one step up, same hue: the chat
    static var hover: Color { c.hover }      // hover and wells
    /// Camera and teleprompter background while you record. Always dark.
    static var stage: Color { c.stage }
    static var stageNS: NSColor { c.stageNS }
    /// The prompter's page and type while you prepare: the app's own paper and ink.
    static var paperNS: NSColor { c.paperNS }
    static var inkNS: NSColor { c.inkNS }

    // MARK: Shape and motion
    static let radius: CGFloat = 12
    static let motion = Animation.easeOut(duration: 0.18)
    /// Things that move: the mode indicator, drawers, the record button. A little overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    /// Soft ink-tinted shadow under cards that float on the canvas.
    static var shadow: Color { c.shadow }

    // MARK: Type
    /// Inter, bundled in Resources/Fonts. Falls back to the system font if missing.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let size = size * TextSize.shared.factor
        return fontsReady ? .custom(interName(weight), size: size) : .system(size: size, weight: weight)
    }
    /// Nunito Bold: titles, names and empty states. Rounded and friendly, like the mascot.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        // Sizes were picked for Instrument Serif, which runs small; Nunito Bold reads bigger.
        let size = size * 0.8 * TextSize.shared.factor
        let name = weight == .black || weight == .heavy ? "Nunito-ExtraBold" : "Nunito-Bold"
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: .bold, design: .rounded)
    }
    /// Numbers and small meta. Inter with even-width digits.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        sans(size, weight).monospacedDigit()
    }
    /// Teleprompter text.
    static func prompter(_ size: CGFloat) -> NSFont {
        NSFont(name: "Inter-Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }
    static var body: Font { sans(13) }

    // MARK: Setup

    private(set) static var fontsReady = false

    /// Call once at launch.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appending(path: "Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where ["otf", "ttf"].contains(f.pathExtension) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
        fontsReady = NSFont(name: "Inter-Regular", size: 12) != nil
    }

    private static func interName(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "Inter-Bold"
        case .semibold: return "Inter-SemiBold"
        case .medium: return "Inter-Medium"
        default: return "Inter-Regular"
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light, dark, alpha: alpha))
    }

    private static func dynamicNS(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        ThemeColors.ns(Pair(light, dark), alpha)
    }
}

/// The app's text size: ⌘+ and ⌘− step through three sizes, ⌘0 goes back to normal.
/// Observable, so every view that asks Theme for a font redraws when it changes.
@Observable
final class TextSize: @unchecked Sendable {
    static let shared = TextSize()
    static let factors: [CGFloat] = [1, 1.12, 1.25]
    var step = min(max(UserDefaults.standard.integer(forKey: "textSize"), 0), 2) {
        didSet { UserDefaults.standard.set(step, forKey: "textSize") }
    }
    var factor: CGFloat { Self.factors[step] }
    var name: String { ["Normal", "Large", "Larger"][step] }
    func bigger() { step = min(step + 1, Self.factors.count - 1) }
    func smaller() { step = max(step - 1, 0) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Building blocks

/// A quiet group label: "Sessions", "Published". Sentence case, third strength.
struct SectionLabel: View {
    var number: String? = nil  // kept for old call sites; not shown any more
    let text: String
    var body: some View {
        Text(text.prefix(1).uppercased() + text.dropFirst())
            .font(Theme.sans(11.5, .medium))
            .foregroundStyle(Theme.faint)
    }
}

/// A quiet text button (was "[ Label ]"). Active: ink on a soft well.
struct BracketButtonStyle: ButtonStyle {
    var active = false
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12.5, .medium))
            .foregroundStyle(active || hover ? Theme.ink : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(active || hover ? Theme.hover : .clear))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
    }
}

/// The primary action (solid ink), an accent button (white type in light and dark, 2026-10-06)
/// or a quiet outlined button.
struct AccentButtonStyle: ButtonStyle {
    enum Kind { case solid, quiet, accent }
    var kind: Kind = .solid
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(13, .semibold))
            .padding(.horizontal, 16).frame(minHeight: 32)
            .foregroundStyle(kind == .quiet ? Theme.ink : kind == .accent ? Color.white : Theme.paper)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(kind == .quiet ? Theme.border : .clear))
            .shadow(color: kind != .quiet && hover ? (kind == .accent ? Theme.accent : Theme.ink).opacity(0.3) : .clear, radius: 10, y: 4)
            .opacity(!enabled ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
            .animation(Theme.motion, value: configuration.isPressed)
    }

    private var fill: Color {
        switch kind {
        case .solid: return Theme.ink
        case .accent: return Theme.accent
        case .quiet: return hover ? Theme.hover : Theme.paper
        }
    }
}

/// Small rounded tag.
struct Tag: View {
    let text: String
    var accent = false
    var body: some View {
        Text(text)
            .font(Theme.sans(11, .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(accent ? Theme.accentInk : Theme.muted)
            .background(accent ? Theme.accentSoft : Theme.hover, in: Capsule())
    }
}

extension View {
    /// Paper card with a hairline and a soft shadow.
    func card(padding: CGFloat = 12) -> some View {
        // The shadow belongs to the card's shape, not to its content, and it is drawn once into
        // a bitmap. A live shadow has no fixed outline, so Core Animation blurred it again on
        // every frame of a scroll: the Performance board stuttered with ten of them (2026-10-03).
        self.padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.paper)
                    .shadow(color: Theme.shadow, radius: 14, y: 6)
                    .padding(32)  // room for the blur inside the bitmap
                    .drawingGroup()
                    .padding(-32)
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }

    /// A note set off by a thin line on the left.
    func builderBorder() -> some View {
        self.padding(.leading, 12)
            .overlay(alignment: .leading) { Capsule().fill(Theme.border).frame(width: 2) }
    }

    /// Fades and lifts in when `value` changes: titles, counts, swapped text.
    func swapIn<V: Hashable>(_ value: V) -> some View {
        self.id(value).transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity))
    }
}

/// Theme-colored divider.
struct Rule: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// The Takes friend: the white blob from the app icon. Empty states and quiet moments only.
struct Mascot: View {
    var size: CGFloat = 72
    static let image: NSImage? = Bundle.main.resourceURL
        .flatMap { NSImage(contentsOf: $0.appending(path: "Brand/mascot.png")) }
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size)
                .shadow(color: Theme.shadow, radius: size * 0.12, y: size * 0.06)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A soft drop shadow traced from `shape` alone and drawn in one GPU pass. A plain .shadow on a
    /// whole card traces every text run and video inside it, and the ⌘F snapshot draws that in
    /// software: 790 ms for 16 Storyboard-like cards, against 40 ms this way (2026-10-06).
    /// `fill` is the card's own colour; it sits under the card, so only the shadow shows.
    func cardShadow<S: Shape>(_ shape: S, fill: Color, color: Color = Theme.shadow, radius: CGFloat, y: CGFloat = 0) -> some View {
        let room = radius * 2 + abs(y)   // the offscreen pass is this much larger, so the blur is not cut
        return background {
            shape.fill(fill)
                .shadow(color: color, radius: radius, y: y)
                .padding(room)
                .drawingGroup()
                .padding(-room)
                .allowsHitTesting(false)
        }
    }
}
