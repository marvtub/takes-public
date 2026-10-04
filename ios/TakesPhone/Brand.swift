import CoreText
import SwiftUI
import UIKit

// The Takes brand on the phone (2026-10-03: "too many default iOS buttons … make them feel like
// the Takes brand"). Same kit as the Mac's Theme: Deep Navy ink on Cloud White, Clear Blue for
// meaning, Fresh Mint for "it went out", Nunito for titles, Inter for the rest, the mascot on
// empty screens. Everything a person taps gives a little press and a light tap back.

extension Palette {
    static var accentSoft: Color { Look.shared.colors.accentSoft }
    static let liveSoft = Color(light: 0xDFF7E9, dark: 0x153829)
    static let danger = Color(light: 0xE5484D, dark: 0xFF6B6F)
    static let dangerSoft = Color(light: 0xFDECEC, dark: 0x3A1D24)
    static let warn = Color(light: 0xE08A00, dark: 0xFFB547)
    /// Soft navy shadow under things that float on the canvas.
    static var shadow: Color { Look.shared.colors.shadow }
}

enum Brand {
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)
    static let quick = Animation.snappy(duration: 0.22)

    /// Call once at launch: the fonts ship inside the app.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL else { return }
        for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold", "Nunito-VF"] {
            let url = dir.appending(path: name + ".ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        fontsReady = UIFont(name: "Inter-Regular", size: 12) != nil
        // Bars and controls UIKit still draws (menus aside) speak the same type.
        if fontsReady, let inter = UIFont(name: "Inter-Medium", size: 13) {
            UISegmentedControl.appearance().setTitleTextAttributes([.font: inter], for: .normal)
        }
    }

    nonisolated(unsafe) private(set) static var fontsReady = false

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Type

extension Font {
    /// Inter at a text style's size, growing with Dynamic Type.
    static func inter(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        let (size, base) = Self.metrics(style)
        return inter(size: size, weight ?? base, relativeTo: style)
    }

    static func inter(size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        guard Brand.fontsReady else { return .system(size: size, weight: weight) }
        let name = switch weight {
        case .bold, .heavy, .black: "Inter-Bold"
        case .semibold: "Inter-SemiBold"
        case .medium: "Inter-Medium"
        default: "Inter-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// Nunito, rounded like the mascot: titles, names, big numbers and empty states.
    static func nunito(_ style: Font.TextStyle, heavy: Bool = false) -> Font {
        nunito(size: Self.metrics(style).size + 1, heavy: heavy, relativeTo: style)
    }

    static func nunito(size: CGFloat, heavy: Bool = false, relativeTo style: Font.TextStyle = .title3) -> Font {
        guard Brand.fontsReady else { return .system(size: size, weight: heavy ? .heavy : .bold, design: .rounded) }
        return .custom(heavy ? "Nunito-ExtraBold" : "Nunito-Bold", size: size, relativeTo: style)
    }

    private static func metrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (34, .bold)
        case .title: (28, .bold)
        case .title2: (22, .bold)
        case .title3: (20, .semibold)
        case .headline: (17, .semibold)
        case .callout: (16, .regular)
        case .subheadline: (15, .regular)
        case .footnote: (13, .regular)
        case .caption: (12, .regular)
        case .caption2: (11, .regular)
        default: (17, .regular)
        }
    }
}

// MARK: - Buttons

/// Anything tappable: a quick squeeze and a light tap back.
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down && haptic { Brand.tap() } }
    }
}

extension ButtonStyle where Self == Pressable {
    static var press: Pressable { Pressable() }
}

/// The brand's pill: solid blue for the one thing to do, soft tints for the rest.
struct Pill: ButtonStyle {
    enum Kind { case primary, soft, quiet, record, recordSoft, ink }
    var kind = Kind.primary
    var small = false
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.inter(small ? .footnote : .callout, .semibold))
            .labelStyle(PillLabel())
            .lineLimit(1)
            .foregroundStyle(fg)
            .padding(.horizontal, small ? 12 : 18)
            .frame(minHeight: small ? 32 : 42)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(bg, in: Capsule())
            .overlay { if kind == .quiet { Capsule().strokeBorder(Palette.border) } }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in if down { Brand.tap() } }
            .contentShape(Capsule())
    }

    private var fg: Color {
        switch kind {
        case .primary, .record: .white
        case .soft: Palette.accent
        case .quiet: Palette.ink
        case .recordSoft: Palette.danger
        case .ink: Palette.paper
        }
    }

    private var bg: Color {
        switch kind {
        case .primary: Palette.accent
        case .soft: Palette.accentSoft
        case .quiet: Palette.paper
        case .record: Palette.danger
        case .recordSoft: Palette.dangerSoft
        case .ink: Palette.ink
        }
    }
}

/// Icon and words a little closer than iOS puts them.
struct PillLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 14, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == Pill {
    static func pill(_ kind: Pill.Kind = .primary, small: Bool = false, wide: Bool = false) -> Pill { Pill(kind: kind, small: small, wide: wide) }
}

/// An icon button as on the Mac (2026-10-04: "get rid of default iOS elements"): a plain glyph
/// in the second strength, no circle, no shadow. Filled: a small solid dot of the tint (record).
struct RoundIcon: View {
    let icon: String
    var tint: Color = Palette.muted
    var size: CGFloat = 40
    var filled = false
    var label: String

    var body: some View {
        Group {
            if filled {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint, in: Circle())
            } else {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }
}

// MARK: - Bars

/// The top of a pushed screen, as the Mac's session header: a plain back chevron, the title in
/// Nunito on the left with its meta line under it, actions on the right. A hairline under it.
/// The system bar is hidden; the back swipe still works (see the navigation controller below).
struct TopBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.muted)
                    .frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "New video" : title).font(.nunito(size: 21, relativeTo: .headline))
                    .foregroundStyle(Palette.ink).lineLimit(1)
                if let subtitle { Text(subtitle).font(.inter(.footnote)).foregroundStyle(Palette.faint).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) { trailing() }
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 8)
    }
}

/// The top of Comments and Performance: back to the list of videos (as the Mac's sidebar), the
/// page's own buttons on the right.
struct ScreenHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.tabBar) private var tab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                if let tab {
                    Button { Brand.select(); tab.wrappedValue = "videos" } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            Text("Takes").font(.inter(.body, .medium))
                        }
                        .foregroundStyle(Palette.muted)
                        .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Back to videos")
                }
                leading()
                Spacer()
                trailing()
            }
            .frame(minHeight: 44)
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.nunito(size: 26, relativeTo: .title)).foregroundStyle(Palette.ink)
                    if let subtitle { Text(subtitle).font(.inter(.footnote)).foregroundStyle(Palette.faint) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 2)
    }
}

/// Tabs inside a screen (Chat, Files, Script, Board, Post): a white pill slides to the one you tap.
struct Segments<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button {
                    guard !on else { return }
                    Brand.select()
                    withAnimation(Brand.spring) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.inter(.subheadline, .medium))
                        .foregroundStyle(on ? Palette.ink : Palette.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.paper)
                                    .shadow(color: Palette.shadow, radius: 3, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Search, as the Mac's find field: a soft well with a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.faint)
            TextField(prompt, text: $text)
                .font(.inter(.callout)).foregroundStyle(Palette.ink)
                .focused($focused).submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { withAnimation(Brand.quick) { text = "" } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Palette.faint)
                }
                .buttonStyle(.press)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Palette.muted.opacity(0.35) : .clear, lineWidth: 1))
        .animation(Brand.quick, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

// MARK: - Empty and waiting

/// The mascot with a line or two, instead of a grey icon: an empty list, nothing written yet.
struct MascotEmpty<Action: View>: View {
    let title: String
    var message: String? = nil
    var mood = Mood.happy
    @ViewBuilder var action: () -> Action

    enum Mood { case happy, sorry }

    var body: some View {
        VStack(spacing: 10) {
            // Bobs by the clock (see WorkingDots for why not repeatForever).
            TimelineView(.animation) { context in
                let k = (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 1.8)) / 2
                Image("Mascot").resizable().scaledToFit().frame(width: 96, height: 96)
                    .rotationEffect(.degrees(mood == .sorry ? -8 : 0))
                    .offset(y: 2 - 6 * k)
            }
            .shadow(color: Palette.shadow, radius: 10, y: 6)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            Text(title).font(.nunito(size: 22, relativeTo: .title3)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(message).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            action().padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

extension MascotEmpty where Action == EmptyView {
    init(title: String, message: String? = nil, mood: Mood = .happy) {
        self.init(title: title, message: message, mood: mood) { EmptyView() }
    }
}

/// Three dots that breathe while Claude works, in place of a grey spinner.
/// Driven by the clock, not a repeatForever animation: that one also animates
/// the dots' position, so dots that appear mid-layout swing around forever.
struct WorkingDots: View {
    var color: Color = Palette.accent

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    // 0...1 and back every 1.2 s, each dot 0.18 s behind the one before.
                    let k = (1 - cos((t - Double(i) * 0.18) * .pi / 0.6)) / 2
                    Circle().fill(color).frame(width: 6, height: 6)
                        .scaleEffect(0.5 + 0.5 * k).opacity(0.35 + 0.65 * k)
                }
            }
        }
        .accessibilityLabel("Working")
    }
}

/// A sheet's own top bar: Cancel on the left, the title, the main action on the right.
struct SheetBar<Action: View>: View {
    let title: String
    var cancel: String = "Cancel"
    let close: () -> Void
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack {
            Button(cancel, action: close).buttonStyle(.pill(.quiet, small: true))
            Spacer()
            action()
        }
        .overlay { Text(title).font(.nunito(size: 17, relativeTo: .headline)).foregroundStyle(Palette.ink).lineLimit(1).padding(.horizontal, 90) }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
    }
}

// MARK: - Back swipe with the bar hidden

/// SwiftUI turns off the edge swipe back when a screen hides its navigation bar. Keep it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

// MARK: - Sheets

/// A labelled card in a sheet, in place of a grey Form section.
struct FormCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.inter(.footnote, .semibold)).foregroundStyle(Palette.muted).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
        }
    }
}

/// A sheet laid out the brand's way: its bar, then cards on the canvas.
struct BrandSheet<Action: View, Content: View>: View {
    let title: String
    var cancel = "Cancel"
    let close: () -> Void
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: title, cancel: cancel, close: close, action: action)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }
}
