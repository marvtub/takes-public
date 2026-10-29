import AppKit
import SwiftUI

// The script in the notch (2026-10-07, the user's favourite). A small black panel hangs from the
// notch, right under the camera, so your eyes stay near the lens. It follows your voice, shows
// over every app and Space, and never takes focus from the app you show. It can start a take.
//
// It stays out of Takes' own screen recordings: ScreenRecorder leaves out every Takes window.
// `sharingType = .none` asks other apps (calls, QuickTime) to leave it out too; whether they do
// depends on the macOS version and the app, so the site does not promise it.
//
// 2026-10-29 redesign (design: https://claude.ai/artifact/9hd9v7PyrWpQTAtUTnKJyQ): only the words
// on the black. The controls hang in a pill under the panel before a take and go during it (point
// at the panel for pause and stop). Mono, centred, read lines dim, a blue light under the text that
// follows your voice. Status (the take's time, the voice meter) sits beside the camera. The panel
// can move off the notch, and a menu bar item opens it.

/// Where the panel goes on a screen. Pure math, so a test can check it for any Mac.
struct NotchLayout: Equatable {
    /// The window, in screen coordinates.
    var frame: CGRect
    /// The black band behind the notch (zero on a screen with no notch).
    var band: CGFloat
    var notchWidth: CGFloat

    /// The width when you have not picked one: wide, so long lines fit (2026-10-29: The user kept it
    /// wider than the notch apps that hug the camera, and made it a setting).
    static let minWidth: CGFloat = 540
    /// How far the text reaches past each side of the notch.
    static let wing: CGFloat = 165
    /// The widths you can pick with the arrows in the controls.
    static let widths: ClosedRange<CGFloat> = 420...900

    /// `notch`: the gap between the two menu bar areas beside the camera, with the menu bar's
    /// height. Nil on a Mac or display with no notch: the panel sits under the menu bar.
    /// `width`: the width you picked; nil is the default.
    static func make(screen: CGRect, visibleTop: CGFloat, notch: CGSize?, body: CGFloat, width: CGFloat? = nil) -> NotchLayout {
        let notchWidth = notch?.width ?? 0
        let want = width.map { min(widths.upperBound, max(widths.lowerBound, $0)) } ?? max(minWidth, notchWidth + 2 * wing)
        let width = min(screen.width - 40, max(notchWidth + 120, want))
        let band = notch?.height ?? 0
        let top = notch == nil ? visibleTop : screen.maxY
        let height = band + body
        return NotchLayout(frame: CGRect(x: (screen.midX - width / 2).rounded(), y: top - height, width: width, height: height),
                           band: band, notchWidth: notchWidth)
    }

    @MainActor
    static func make(for screen: NSScreen, body: CGFloat, width: CGFloat? = nil) -> NotchLayout {
        var notch: CGSize?
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        return make(screen: screen.frame, visibleTop: screen.visibleFrame.maxY, notch: notch, body: body, width: width)
    }

    /// Off the notch: the same panel with no band, its top left at `topLeft` (screen points).
    static func floating(topLeft: CGPoint, width: CGFloat, body: CGFloat) -> NotchLayout {
        NotchLayout(frame: CGRect(x: topLeft.x, y: topLeft.y - body, width: width, height: body), band: 0, notchWidth: 0)
    }
}

/// The panel's shape: flat along the top edge of the screen, round corners at the bottom, and a
/// small inward curve where each side meets the top edge (2026-10-29), so the panel reads as the
/// notch grown down rather than a box under it. Off the notch: round on every corner.
struct NotchShape: Shape {
    var floating = false
    /// How far each curve reaches past the side: drawn in the clear margin round the panel.
    static let shoulder: CGFloat = 10

    func path(in r: CGRect) -> Path {
        if floating { return RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: r) }
        let s = Self.shoulder, c: CGFloat = 22
        var p = Path()
        p.move(to: CGPoint(x: r.minX - s, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + s), control: CGPoint(x: r.minX - s * 0.1, y: r.minY + s * 0.1))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + c, y: r.maxY), radius: c)
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY - c), radius: c)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX + s, y: r.minY), control: CGPoint(x: r.maxX + s * 0.1, y: r.minY + s * 0.1))
        p.closeSubpath()
        return p
    }
}

/// The blue light round the panel, with the clear margin it spreads into. It shows only outside
/// the panel: the panel is a little see-through, and blue under it lit the strip beside the
/// camera, where the screen's notch cut it in two (2026-10-09).
struct NotchGlow: View {
    let size: CGSize
    var floating = false

    var body: some View {
        let m = NotchView.margin
        ZStack {
            NotchShape(floating: floating).fill(Theme.accent).blur(radius: 22).opacity(0.7)
            NotchShape(floating: floating).stroke(Theme.accent, lineWidth: 3).blur(radius: 6)
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, m).padding(.bottom, m).padding(.top, floating ? m : 0)
        .mask(Outside(margin: m, floating: floating).fill(style: FillStyle(eoFill: true)))
    }

    /// All of the area but the panel.
    private struct Outside: Shape {
        let margin: CGFloat
        let floating: Bool
        func path(in r: CGRect) -> Path {
            var p = Path(r)
            let top = floating ? margin : 0
            p.addPath(NotchShape(floating: floating).path(in: CGRect(x: margin, y: top, width: r.width - 2 * margin, height: r.height - margin - top)))
            return p
        }
    }
}

/// Shows and hides the panel. One for the app.
@MainActor
final class NotchPanel {
    static let shared = NotchPanel()
    /// The text size, set with A− and A+ (2026-10-09: it was fixed at 21).
    static let fontKey = "notchFontSize"
    static let fontSizes: ClosedRange<Double> = 15...33
    static var fontSize: Double {
        let v = UserDefaults.standard.double(forKey: fontKey)
        return v == 0 ? 21 : min(fontSizes.upperBound, max(fontSizes.lowerBound, v))
    }
    /// Typewriter type (SF Mono) or Inter. Mono by default (2026-10-29).
    static let monoKey = "notchMono"
    static var mono: Bool { UserDefaults.standard.object(forKey: monoKey) as? Bool ?? true }
    static func font(_ size: Double, mono: Bool? = nil) -> NSFont {
        mono ?? Self.mono ? .monospacedSystemFont(ofSize: size, weight: .regular) : Theme.prompter(size)
    }
    /// The width you picked; 0 is the default (`NotchLayout.minWidth`).
    static let widthKey = "notchWidth"
    static var width: CGFloat? {
        let v = UserDefaults.standard.double(forKey: widthKey)
        return v == 0 ? nil : CGFloat(v)
    }
    /// Moved off the notch, and where: the panel's top left in screen points.
    static let floatKey = "notchFloating"
    static let floatXKey = "notchFloatX", floatTopKey = "notchFloatTop"
    static var floating: Bool { UserDefaults.standard.bool(forKey: floatKey) }

    private var panel: NSPanel?
    private weak var app: AppModel?
    private var screenWatch: NSObjectProtocol?
    private var moveWatch: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    /// The panel's black part now, in screen points, with the room of the controls under it.
    private var body: CGRect = .zero

    var shown: Bool { panel?.isVisible == true }

    /// Record opens the notch by itself (2026-10-08: a new user never found it). Closing it
    /// turns that off; opening it again turns it back on.
    static let autoKey = "notchOnRecord"
    static var auto: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    /// Record opened it, not you: it closes again when you leave Record.
    private(set) var autoOpened = false

    /// The notch and its tour wait for the first Record press (2026-10-12: on the first launch it
    /// opened by itself over the welcome and the demo, and new users found it all too much).
    /// Someone who took the tour, or opened the notch, has it armed already.
    static let armedKey = "notchArmed"
    static var armed: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: armedKey) || d.integer(forKey: NotchView.introKey) > 0
    }

    /// The first Record press with a script: the notch opens with its tour, and the take waits.
    /// The tour ends on ●. True when it opened.
    func firstRecord(_ app: AppModel) -> Bool {
        guard !Self.armed, Self.auto, !shown, !AppModel.testing,
              UserDefaults.standard.string(forKey: "rightTab") == SessionMode.record.rawValue,
              !app.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        UserDefaults.standard.set(true, forKey: Self.armedKey)
        show(app)
        autoOpened = true
        return true
    }

    /// The menu item, the menu bar item and the pill button: what you pick is what Record does
    /// next time.
    func toggle(_ app: AppModel) {
        UserDefaults.standard.set(true, forKey: Self.armedKey)
        UserDefaults.standard.set(!shown, forKey: Self.autoKey)
        shown ? hide() : show(app)
    }

    /// The panel's close button and "Show the script here instead".
    func close() {
        UserDefaults.standard.set(false, forKey: Self.autoKey)
        hide()
    }

    /// The waveform in the menu bar (2026-10-29): it opens and closes the notch from any app, so
    /// one you closed is one click away. Once, at launch.
    func menuBarItem(_ app: AppModel) {
        guard statusItem == nil, !AppModel.testing else { return }
        self.app = app
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Script in the notch")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Script in the notch (⌥⌘N)"
        item.button?.target = self
        item.button?.action = #selector(menuBarClicked)
        statusItem = item
    }

    @objc private func menuBarClicked() {
        guard let app else { return }
        toggle(app)
    }

    /// Record with a script shows (`on`) or goes away. Opens the notch if you have not turned that
    /// off, and fades it out on the way out, never during a take. 2026-10-09: it went only if Record
    /// had opened it, so one you opened yourself stayed over every other tab. It comes back on
    /// Record, since opening it turned `auto` on. Not under tests: the window pictures show Record
    /// with its own prompter.
    func follow(record on: Bool, _ app: AppModel) {
        if on {
            guard Self.auto, Self.armed, !shown || fading, !AppModel.testing else { return }
            show(app)
            autoOpened = true
        } else if shown, !fading, !app.isRecording {
            hide(animated: true)
        }
    }

    func show(_ app: AppModel) {
        self.app = app
        autoOpened = false
        let fresh = !shown || fading
        fade += 1
        fading = false
        // One prompter at a time: Record puts a small stand-in where the big script was.
        app.notchOpen = true
        let p = panel ?? make()
        panel = p
        place(glow: true)
        // Front without making Takes the active app: the app you show keeps the keyboard.
        if fresh { slide(p, in: true, then: nil) }
        p.orderFrontRegardless()
        if screenWatch == nil {
            screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        if moveWatch == nil {
            moveWatch = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.moved() }
            }
        }
    }

    /// `animated`: it fades and rises into the notch. Showing it again during the fade stops that.
    func hide(animated: Bool = false) {
        autoOpened = false
        app?.notchOpen = false
        app?.notchTour = false
        fade += 1
        guard animated, let p = panel, p.isVisible else { fading = false; panel?.orderOut(nil); return }
        let n = fade
        fading = true
        slide(p, in: false) { [weak self] in
            guard let self, self.fade == n else { return }
            self.fading = false
            p.orderOut(nil)
            p.alphaValue = 1
            self.place()
        }
    }

    /// Off the notch and back (2026-10-29): for a camera on top of another display, or to get it
    /// out of the way. Drag it by its top strip; it keeps its place.
    func setFloating(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.floatKey)
        place()
    }

    /// Counts shows and hides, so a fade that ends after the next show leaves the panel up.
    private var fade = 0
    /// Fading out: still on screen, but already on its way.
    private var fading = false
    /// Set while `place` moves the window, so its own move is not saved as yours.
    private var placing = false

    /// The gentle way in and out: a fade with a short drop from the notch, or a rise back into it.
    private func slide(_ p: NSPanel, in coming: Bool, then done: (() -> Void)?) {
        let rest = p.frame
        let up = rest.offsetBy(dx: 0, dy: 14)
        placing = true
        if coming { p.alphaValue = 0; p.setFrame(up, display: false) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = coming ? 0.32 : 0.26
            c.timingFunction = CAMediaTimingFunction(name: coming ? .easeOut : .easeIn)
            p.animator().alphaValue = coming ? 1 : 0
            p.animator().setFrame(coming ? rest : up, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.placing = false
                done?()
            }
        }
    }

    /// You dragged the floating panel: keep its place for next time.
    private func moved() {
        guard let p = panel, Self.floating, !placing else { return }
        let w = body.width
        let x = p.frame.midX - w / 2
        let top = p.frame.maxY - NotchView.margin
        UserDefaults.standard.set(Double(x), forKey: Self.floatXKey)
        UserDefaults.standard.set(Double(top), forKey: Self.floatTopKey)
        body = CGRect(x: x, y: top - body.height, width: w, height: body.height)
    }

    var contentForTest: NSView? { panel?.contentView }

    /// How far the prompter reaches down into `rect` (screen points), 0 when it is not over it.
    /// It counts the controls under the panel, so the stage does not jump when they go.
    func reach(into rect: CGRect) -> CGFloat {
        guard panel != nil, shown, !fading else { return 0 }
        guard body.minX < rect.maxX, body.maxX > rect.minX, body.minY < rect.maxY else { return 0 }
        return max(0, rect.maxY - body.minY)
    }

    /// The built-in display (the one with the notch), else the main one.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The text part's height for a number of lines.
    static func body(lines: Int) -> CGFloat {
        (CGFloat(lines) * line(fontSize)).rounded() + 24
    }

    /// One line of the prompter as it draws: the font's own line height plus the 0.35 spacing
    /// Prompter sets. A fixed 1.35 left out about a fifth of a line each, so bigger text showed
    /// fewer lines and the panel seemed not to grow (2026-10-11).
    static func line(_ size: Double, mono: Bool? = nil) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font(size, mono: mono)) + size * 0.35
    }

    static let maxLines = 8

    /// Sizes the panel for its screen and line count, and draws it new for that shape. `glow`:
    /// a soft blue light round the panel for a moment, to bring the eye up to the notch.
    func place(glow: Bool = false) {
        guard let panel, let app, let screen = Self.screen else { return }
        var lines = UserDefaults.standard.object(forKey: "notchLines") as? Int ?? 3
        // The tour needs five lines of room; the panel goes back to your size after it.
        if UserDefaults.standard.integer(forKey: NotchView.introKey) < NotchView.intro.count { lines = max(lines, 5) }
        let floating = Self.floating
        var layout = NotchLayout.make(for: screen, body: Self.body(lines: lines), width: Self.width)
        // No band beside a camera: a thin strip on top holds the status (and the grip, off the notch).
        if layout.band == 0 || floating {
            let body = Self.body(lines: lines) + NotchView.strip
            if floating {
                layout = NotchLayout.floating(topLeft: floatPlace(width: layout.frame.width, screen: screen), width: layout.frame.width, body: body)
            } else {
                layout = NotchLayout.make(for: screen, body: body, width: Self.width)
            }
        }
        let f = layout.frame
        let size = NotchView.window(for: layout, floating: floating)
        body = CGRect(x: f.minX, y: f.minY - NotchView.controls, width: f.width, height: f.height + NotchView.controls)
        let top = floating ? NotchView.margin : 0
        // The size first, then the view at that size (2026-10-14): the first time the window was
        // still zero wide, and the glow's animation on appear also grew the page in from the side.
        // Clear room round it for the glow and the controls. Clicks there go to the app under it.
        placing = true
        panel.setFrame(CGRect(x: f.midX - size.width / 2, y: f.maxY + top - size.height, width: size.width, height: size.height), display: false)
        placing = false
        panel.isMovable = floating
        let host = NSHostingView(rootView: NotchView(layout: layout, floating: floating, glow: glow,
                                                     close: { [weak self] in self?.close() }).environment(app))
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        panel.display()
    }

    /// Where the floating panel goes: where you left it, if that is still on a screen; else the
    /// top right of the notch's screen, under the menu bar.
    private func floatPlace(width: CGFloat, screen: NSScreen) -> CGPoint {
        let d = UserDefaults.standard
        if d.object(forKey: Self.floatXKey) != nil {
            let p = CGPoint(x: d.double(forKey: Self.floatXKey), y: d.double(forKey: Self.floatTopKey))
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 40, dy: 40).contains(CGPoint(x: p.x + 40, y: p.y - 20)) }) { return p }
        }
        let v = screen.visibleFrame
        return CGPoint(x: v.maxX - width - 24, y: v.maxY - 16)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // isFloatingPanel sets the floating level, under the menu bar: set the level after it.
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        // canJoinAllApplications: also over another app's full-screen window (2026-10-14: it showed
        // only on a Space without one).
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovable = false
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        return p
    }
}

/// What the panel shows: the script, two to eight lines, on black. The controls hang under it.
struct NotchView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("notchLines") private var lines = 3
    @AppStorage(NotchPanel.fontKey) private var fontSize = 21.0
    @AppStorage(NotchPanel.monoKey) private var mono = true
    @AppStorage(NotchPanel.widthKey) private var width = 0.0
    @AppStorage(NotchView.introKey) private var introStep = 0
    @State private var hover = false
    /// What the button under the pointer does. The panel never takes focus, so macOS does not
    /// show tooltips on it: a small label under the controls shows this text instead.
    @State private var tip: String?
    let layout: NotchLayout
    var floating = false
    var glow = false
    let close: () -> Void
    /// How bright the glow is now: 0 is off. A test can start it lit.
    @State var lit: Double = 0
    /// Solid black, one colour from the top edge down, so the screen's notch melts into it.
    /// 2026-10-09: 82% black showed the notch as a darker block; solid beside the camera over a
    /// see-through page then showed as a black bar across the top, over a light window.
    static let page = Color.black
    static func fill(band: CGFloat, height: CGFloat) -> Color { page }
    /// The clear room round the panel that the glow spreads into.
    static let margin: CGFloat = 28
    /// The status strip on top where no notch band is (another display, or off the notch).
    static let strip: CGFloat = 24
    /// The controls' room under the panel: a gap, the pill, and the tip under it.
    static let pill: CGFloat = 36
    static let controls: CGFloat = 8 + pill
    static let tipRoom: CGFloat = 28
    /// Wide enough for the pill with every button.
    static let leastWindow: CGFloat = 520

    /// The window round a panel: room for the glow, the controls and the tip.
    static func window(for l: NotchLayout, floating: Bool) -> CGSize {
        CGSize(width: max(l.frame.width + 2 * margin, leastWindow),
               height: (floating ? margin : 0) + l.frame.height + controls + tipRoom + 8)
    }

    /// The first-time tour: three steps, each with an icon and the buttons it talks about.
    /// The other buttons go dim, so the eye goes to the one that matters (2026-10-07: the first
    /// version was too quiet, and read as part of the panel, not as a tour).
    static let introKey = "notchIntroStep"
    static let intro: [(icon: String, title: String, text: String, buttons: Set<String>)] = [
        ("eye", "Look here while you talk", "Your script sits right under the camera, so your eyes stay on the lens.", []),
        ("waveform", "Press ▶ and just talk", "The text moves with your voice. There is no speed to set.", ["play", "voice"]),
        ("record.circle", "Press ● to record a take", "Point at any button to see what it does.", ["record"]),
    ]
    private var introOn: Bool { introStep < Self.intro.count }
    /// The band beside the camera, or the strip where there is none.
    private var top: CGFloat { layout.band > 0 ? layout.band : Self.strip }

    var body: some View {
        let size = Self.window(for: layout, floating: floating)
        ZStack(alignment: .top) {
            NotchGlow(size: layout.frame.size, floating: floating).opacity(lit).allowsHitTesting(false)
            VStack(spacing: 8) {
                panel.frame(width: layout.frame.width, height: layout.frame.height)
                controls.frame(height: Self.pill)
                tipLabel.frame(height: Self.tipRoom - 8)
            }
            .padding(.top, floating ? Self.margin : 0)
            .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear {
            guard glow else { return }
            // Calm: it swells, holds a moment, and fades.
            withAnimation(.easeOut(duration: 0.6)) { lit = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeInOut(duration: 1.4)) { lit = 0 }
            }
        }
    }

    private var panel: some View {
        let size = NotchPanel.fontSize
        let lineHeight = NotchPanel.line(size)
        let shown = CGFloat(max(1, lines))
        return ZStack(alignment: .top) {
            NotchVoiceLight(width: layout.frame.width)
            VStack(spacing: 0) {
                status.frame(height: top)
                Prompter(text: .constant(app.promptText), contentKey: "notch#" + app.promptKey, fontSize: size,
                         scrolling: app.scrolling && !hover, speed: app.speed * size / max(app.fontSize, 1),
                         editable: false, resetToken: app.resetToken, dark: true,
                         voice: app.following ? app.voice : nil,
                         // One line read stays in sight above the line to read, from three lines up.
                         readingLine: lines >= 3 ? min(0.4, lineHeight / (shown * lineHeight + 8)) : 0,
                         inset: NSSize(width: 24, height: 2), darkPage: .clear,
                         font: NotchPanel.font(size, mono: mono), centered: true, focusLine: true)
                    .padding(.top, 6)
                    // The first and last lines fade into the black instead of being cut.
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .black, location: 0.12),
                                                 .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        if case .countdown(let n) = app.phase {
                            Text("\(n)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                        } else if introOn {
                            introCard
                        } else if app.promptText.isEmpty {
                            Text("Write a script in Takes, and it shows here.")
                                .font(Theme.sans(13)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
            }
        }
        .background(NotchShape(floating: floating).fill(Self.fill(band: layout.band, height: layout.frame.height)))
        .clipShape(NotchShape(floating: floating))
        .environment(\.colorScheme, .dark)
        // The panel draws a new view for the new size: not in the middle of this one's update.
        .onChange(of: lines) { DispatchQueue.main.async { NotchPanel.shared.place() } }
        // The panel grows or shrinks so the same number of lines still fits.
        .onChange(of: fontSize) { DispatchQueue.main.async { NotchPanel.shared.place() } }
        .onChange(of: mono) { DispatchQueue.main.async { NotchPanel.shared.place() } }
        .onChange(of: width) { DispatchQueue.main.async { NotchPanel.shared.place() } }
        .onChange(of: introOn) { _, on in DispatchQueue.main.async { NotchPanel.shared.place(glow: on) } }
        .onChange(of: introOn, initial: true) { _, on in
            let tour = on && app.notchOpen
            DispatchQueue.main.async { if app.notchTour != tour { app.notchTour = tour } }
        }
    }

    /// Beside the camera: the take's time on the left, the voice meter on the right. Never over
    /// the text. Off the notch, a grip in the middle to drag the panel by.
    private var status: some View {
        let wing = max(0, (layout.frame.width - layout.notchWidth) / 2)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if case .recording(let since) = app.phase {
                    Circle().fill(Theme.danger).frame(width: 7, height: 7).shadow(color: Theme.danger.opacity(0.8), radius: 4)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(since)))
                        Text("\(s / 60):\(String(format: "%02d", s % 60))")
                            .font(Theme.sans(12, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.88))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .frame(width: layout.notchWidth > 0 ? wing : nil)
            .frame(maxWidth: layout.notchWidth > 0 ? nil : .infinity)
            if layout.notchWidth > 0 {
                Spacer(minLength: 0)
            } else if floating {
                Capsule().fill(.white.opacity(0.28)).frame(width: 36, height: 4)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if app.following && app.scrolling { NotchMeter() }
            }
            .padding(.trailing, 20)
            .frame(width: layout.notchWidth > 0 ? wing : nil)
            .frame(maxWidth: layout.notchWidth > 0 ? nil : .infinity)
        }
        .background { if floating { WindowDragArea() } }
    }

    private var introCard: some View {
        let step = Self.intro[min(introStep, Self.intro.count - 1)]
        let last = introStep == Self.intro.count - 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("QUICK TOUR · \(introStep + 1) OF \(Self.intro.count)")
                .font(Theme.sans(10.5, .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Theme.accent.opacity(0.18), in: Capsule())
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: step.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title).font(Theme.sans(17, .semibold)).foregroundStyle(.white)
                    Text(step.text).font(Theme.sans(13)).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button("Skip tour") { introStep = Self.intro.count }
                    .buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(.white.opacity(0.5))
                    .opacity(last ? 0 : 1)
                Spacer()
                Button { withAnimation(Theme.motion) { introStep += 1 } } label: {
                    HStack(spacing: 5) {
                        Text(last ? "Start using it" : "Next")
                        if !last { Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)) }
                    }
                    .font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
    }

    /// During the tour, the buttons a step does not name go dim.
    private func dim(_ id: String) -> Double { introOn && !ring(id) ? 0.3 : 1 }

    private func ring(_ id: String) -> Bool { introOn && Self.intro[introStep].buttons.contains(id) }

    /// Before a take: every control, always in sight. During it: none, and pause and stop when
    /// you point at the panel (2026-10-29: buttons over a take only pull the eye off the lens).
    /// With the screen pill up, the pill has record, stop and close: the notch shows only the
    /// words, its other controls come when you point at it, and none of the pill's come twice
    /// (2026-10-29: "overwhelming and redundant" in a screen recording).
    @ViewBuilder private var controls: some View {
        let quiet = app.screenPillOpen && !introOn
        if !app.isRecording, !quiet || hover {
            pillBox { allButtons }.transition(.opacity.combined(with: .offset(y: -6)))
        } else if hover, case .recording = app.phase {
            pillBox {
                button(app.scrolling ? "pause.fill" : "play.fill", app.scrolling ? "Pause the text" : "Go on with the text") {
                    app.scrolling.toggle()
                }
                if !app.screenPillOpen { record }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
        } else {
            Color.clear
        }
    }

    private func pillBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 8).frame(height: Self.pill)
            .background(Capsule().fill(Color(white: 0.06).opacity(0.92)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var allButtons: some View {
        // The tour still points at it.
        if !app.screenPillOpen || introOn {
            record
            divider
        }
        button(app.scrolling ? "pause.fill" : "play.fill",
               app.following ? (app.scrolling ? "Stop listening" : "Start: the text follows your voice")
                             : (app.scrolling ? "Pause" : "Start scrolling"), id: "play") {
            app.scrolling.toggle()
        }
        button("waveform", app.followVoice ? "Voice follow is on. Click to scroll at a set speed." : "Voice follow is off. Click to follow your voice.",
               on: app.followVoice, id: "voice") { app.followVoice.toggle() }
        button("arrow.up.to.line", "Back to the top") { app.resetToken += 1 }
        divider
        let sizes = NotchPanel.fontSizes
        button("textformat.size.smaller", fontSize <= sizes.lowerBound ? "Smaller text (this is the smallest)" : "Smaller text") {
            fontSize = max(sizes.lowerBound, fontSize - 2)
        }
        .disabled(fontSize <= sizes.lowerBound)
        button("textformat.size.larger", fontSize >= sizes.upperBound ? "Bigger text (this is the biggest)" : "Bigger text") {
            fontSize = min(sizes.upperBound, fontSize + 2)
        }
        .disabled(fontSize >= sizes.upperBound)
        button("textformat", mono ? "Typewriter type. Click for Inter." : "Inter. Click for typewriter type.") { mono.toggle() }
        button("rectangle.compress.vertical", lines <= 2 ? "Fewer lines (2 is the least)" : "Fewer lines") { lines = max(2, lines - 1) }
            .disabled(lines <= 2)
        let most = NotchPanel.maxLines
        button("rectangle.expand.vertical", lines >= most ? "More lines (\(most) is the most)" : "More lines") { lines = min(most, lines + 1) }
            .disabled(lines >= most)
        let widths = NotchLayout.widths
        let w = layout.frame.width
        button("arrow.right.and.line.vertical.and.arrow.left", w <= widths.lowerBound ? "Narrower (this is the narrowest)" : "Narrower") {
            width = Double(max(widths.lowerBound, w - 40))
        }
        .disabled(w <= widths.lowerBound)
        button("arrow.left.and.line.vertical.and.arrow.right", w >= widths.upperBound ? "Wider (this is the widest)" : "Wider") {
            width = Double(min(widths.upperBound, w + 40))
        }
        .disabled(w >= widths.upperBound)
        divider
        button(floating ? "pip.enter" : "pip.exit", floating ? "Back to the notch" : "Move it off the notch. Drag it by its top.") {
            NotchPanel.shared.setFloating(!floating)
        }
        button("questionmark", "Take the quick tour again", id: "tour") { introStep = 0 }
        if !app.screenPillOpen {
            button("xmark", "Close. The waveform in the menu bar opens it again (⌥⌘N).") { close() }
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    @ViewBuilder private var tipLabel: some View {
        if let tip, !app.isRecording {
            Text(tip).font(Theme.sans(11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: 20)
                .background(Capsule().fill(Color(white: 0.06).opacity(0.88)))
                .transition(.opacity)
        } else {
            Color.clear
        }
    }

    /// Record from the notch: a red dot that turns into a square while a take runs.
    private var record: some View {
        Button { app.toggleRecord() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5).frame(width: 16, height: 16)
                RoundedRectangle(cornerRadius: app.isRecording ? 2 : 5)
                    .fill(Theme.danger)
                    .frame(width: app.isRecording ? 7 : 10, height: app.isRecording ? 7 : 10)
            }
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { if ring("record") { Ring().frame(width: 30, height: 30) } }
        .opacity(dim("record"))
        .onHover { tipFor(app.isRecording ? "Stop the take" : "Record a take with your camera and mic", $0) }
        .animation(Theme.motion, value: app.isRecording)
    }

    private func tipFor(_ text: String, _ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if inside { tip = text } else if tip == text { tip = nil }
        }
    }

    private func button(_ icon: String, _ help: String, on: Bool = false, id: String = "", _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(on ? Theme.accent.opacity(0.55) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { if ring(id) { Ring().frame(width: 30, height: 30) } }
        .opacity(id == "tour" ? 1 : dim(id))
        .onHover { tipFor(help, $0) }
    }
}

/// The blue light under the text (2026-10-29): it rises from the bottom while you talk and sinks
/// when you stop, so you see the prompter hear you. Its own view: only it draws again 15 times a
/// second, not the text.
struct NotchVoiceLight: View {
    @Environment(AppModel.self) private var app
    let width: CGFloat
    /// A test draws the light at this level without a microphone.
    nonisolated(unsafe) static var testLevel: Double?

    var body: some View {
        let on = Self.testLevel != nil || (app.following && app.scrolling)
        let level = Self.testLevel ?? (on ? Double(app.voice.level) : 0)
        let w = min(width * 0.62, 360)
        Ellipse()
            .fill(RadialGradient(colors: [Theme.accent, Theme.accent.opacity(0.6), Theme.accent.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: w / 2))
            .frame(width: w, height: 150)
            .blur(radius: 10)
            .scaleEffect(0.82 + level * 0.3)
            .opacity(on ? max(0.1, min(1, level * 1.2)) : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: 82)
            .animation(.linear(duration: 0.12), value: level)
            .animation(.easeOut(duration: 0.4), value: on)
            .allowsHitTesting(false)
    }
}

/// Five small bars beside the camera that move with your voice while Takes listens.
struct NotchMeter: View {
    @Environment(AppModel.self) private var app
    private static let shape: [Double] = [0.55, 0.9, 1, 0.75, 0.5]

    var body: some View {
        let level = Double(app.voice.level)
        let talking = level > 0.08
        HStack(spacing: 2.5) {
            ForEach(Self.shape.indices, id: \.self) { i in
                Capsule().fill(talking ? Theme.accent : .white.opacity(0.35))
                    .frame(width: 2.5, height: 3 + (talking ? level * 11 * Self.shape[i] : 0))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// Off the notch: drag the panel by its top strip. The panel never takes focus, and a drag here
/// moves the window without making Takes the active app.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Grip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// A soft pulsing ring round the button an intro step talks about.
private struct Ring: View {
    @State private var big = false
    var body: some View {
        Circle().strokeBorder(Theme.accent, lineWidth: 2)
            .scaleEffect(big ? 1.12 : 0.92).opacity(big ? 0.5 : 1)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { big = true } }
    }
}

/// The prompter in a window of its own (2026-10-07): put it on any display, make it full screen,
/// and mirror it for a glass rig. It reads, it does not edit.
struct PrompterWindowView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("prompterMirror") private var mirror = false
    @AppStorage("prompterFlip") private var flip = false
    @AppStorage("prompterWindowFont") private var size = 56.0
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .top) {
            // The reading line flips with the text, so it stays beside the line to read.
            ZStack(alignment: .topLeading) {
                Prompter(text: .constant(app.promptText), contentKey: "window#" + app.promptKey, fontSize: size,
                         scrolling: app.scrolling, speed: app.speed * size / max(app.fontSize, 1),
                         editable: false, resetToken: app.resetToken, dark: true,
                         voice: app.following ? app.voice : nil, readingLine: 0.3,
                         inset: NSSize(width: 64, height: 40), darkPage: .black)
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(0.9))
                        .frame(width: 5, height: size * 1.3)
                        .offset(x: 24, y: g.size.height * 0.3)
                }
                .allowsHitTesting(false)
            }
            .scaleEffect(x: mirror ? -1 : 1, y: flip ? -1 : 1)
            if hover || app.promptText.isEmpty { toolbar.padding(.top, 10).transition(.opacity) }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onHover { h in withAnimation(Theme.motion) { hover = h } }
        .frame(minWidth: 420, minHeight: 260)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            chip("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", on: $mirror)
                .help("Flip left to right, for a glass rig")
            chip("Upside down", "arrow.up.and.down.righttriangle.up.righttriangle.down", on: $flip)
                .help("Flip top to bottom, for rigs that need it")
            Divider().frame(height: 16)
            Button { size = max(24, size - 6) } label: { Image(systemName: "textformat.size.smaller").frame(width: 26, height: 24) }
                .help("Smaller text")
            Button { size = min(140, size + 6) } label: { Image(systemName: "textformat.size.larger").frame(width: 26, height: 24) }
                .help("Larger text")
            Divider().frame(height: 16)
            Button { app.scrolling.toggle() } label: {
                Image(systemName: app.scrolling ? "pause.fill" : "play.fill").frame(width: 26, height: 24)
            }
            .help(app.following ? "Listen and follow your voice" : "Play / pause")
        }
        .buttonStyle(.plain)
        .font(Theme.sans(12, .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule())
    }

    private func chip(_ title: String, _ icon: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                .foregroundStyle(on.wrappedValue ? Theme.accent : .white.opacity(0.85))
                .padding(.horizontal, 6).frame(height: 24)
        }
    }
}

/// How far the notch prompter reaches into the view it sits behind, so the view can keep clear
/// of it. `open`: app.notchOpen, which measures again when the prompter comes or goes.
struct NotchReach: NSViewRepresentable {
    @Binding var reach: CGFloat
    let open: Bool

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {
        v.report = { r in if abs(reach - r) > 1 { reach = r } }
        // After the panel has its place for this change.
        DispatchQueue.main.async { v.measure() }
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        override func layout() { super.layout(); DispatchQueue.main.async { [weak self] in self?.measure() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measure() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func measure() {
            guard let w = window else { return }
            report?(NotchPanel.shared.reach(into: w.convertToScreen(convert(bounds, to: nil))))
        }
    }
}
