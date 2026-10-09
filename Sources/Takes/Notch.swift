import AppKit
import SwiftUI

// The script in the notch (2026-10-07, the user's favourite). A small black panel hangs from the
// notch, right under the camera, so your eyes stay near the lens. It follows your voice, shows
// over every app and Space, and never takes focus from the app you show. It can start a take.
//
// It stays out of Takes' own screen recordings: ScreenRecorder leaves out every Takes window.
// `sharingType = .none` asks other apps (calls, QuickTime) to leave it out too; whether they do
// depends on the macOS version and the app, so the site does not promise it.

/// Where the panel goes on a screen. Pure math, so a test can check it for any Mac.
struct NotchLayout: Equatable {
    /// The window, in screen coordinates.
    var frame: CGRect
    /// The black band behind the notch (zero on a screen with no notch).
    var band: CGFloat
    var notchWidth: CGFloat

    static let minWidth: CGFloat = 540
    /// How far the text reaches past each side of the notch.
    static let wing: CGFloat = 165

    /// `notch`: the gap between the two menu bar areas beside the camera, with the menu bar's
    /// height. Nil on a Mac or display with no notch: the panel sits under the menu bar.
    static func make(screen: CGRect, visibleTop: CGFloat, notch: CGSize?, body: CGFloat) -> NotchLayout {
        let notchWidth = notch?.width ?? 0
        let width = min(screen.width - 40, max(minWidth, notchWidth + 2 * wing))
        let band = notch?.height ?? 0
        let top = notch == nil ? visibleTop : screen.maxY
        let height = band + body
        return NotchLayout(frame: CGRect(x: (screen.midX - width / 2).rounded(), y: top - height, width: width, height: height),
                           band: band, notchWidth: notchWidth)
    }

    @MainActor
    static func make(for screen: NSScreen, body: CGFloat) -> NotchLayout {
        var notch: CGSize?
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        return make(screen: screen.frame, visibleTop: screen.visibleFrame.maxY, notch: notch, body: body)
    }
}

/// The black shape: a band as wide as the notch on top, the wider text part under it, with round
/// outer corners and soft inner ones, so it reads as the notch grown down.
struct NotchShape: Shape {
    var band: CGFloat
    var notchWidth: CGFloat

    func path(in r: CGRect) -> Path {
        let outer: CGFloat = 22, inner: CGFloat = 10
        var p = Path()
        guard band > 0, notchWidth > 0 else {
            return Path(UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: outer, bottomTrailing: outer)).path(in: r).cgPath)
        }
        let l = r.midX - notchWidth / 2, rt = r.midX + notchWidth / 2
        p.move(to: CGPoint(x: l, y: r.minY))
        p.addLine(to: CGPoint(x: rt, y: r.minY))
        p.addLine(to: CGPoint(x: rt, y: r.minY + band - inner))
        p.addQuadCurve(to: CGPoint(x: rt + inner, y: r.minY + band), control: CGPoint(x: rt, y: r.minY + band))
        // Square top corners: the panel reads as one piece with the top edge of the screen.
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + band))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - outer))
        p.addQuadCurve(to: CGPoint(x: r.maxX - outer, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + outer, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - outer), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + band))
        p.addLine(to: CGPoint(x: l - inner, y: r.minY + band))
        p.addQuadCurve(to: CGPoint(x: l, y: r.minY + band - inner), control: CGPoint(x: l, y: r.minY + band))
        p.closeSubpath()
        return p
    }
}

/// Shows and hides the panel. One for the app.
@MainActor
final class NotchPanel {
    static let shared = NotchPanel()
    static let fontSize: Double = 21
    private var panel: NSPanel?
    private weak var app: AppModel?
    private var screenWatch: NSObjectProtocol?

    var shown: Bool { panel?.isVisible == true }

    /// Record opens the notch by itself (2026-10-08: a new user never found it). Closing it
    /// turns that off; opening it again turns it back on.
    static let autoKey = "notchOnRecord"
    static var auto: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    /// Record opened it, not you: it closes again when you leave Record.
    private(set) var autoOpened = false

    /// The menu item and the bar button: what you pick is what Record does next time.
    func toggle(_ app: AppModel) {
        UserDefaults.standard.set(!shown, forKey: Self.autoKey)
        shown ? hide() : show(app)
    }

    /// The panel's close button and "Show the script here instead".
    func close() {
        UserDefaults.standard.set(false, forKey: Self.autoKey)
        hide()
    }

    /// Record with a script shows (`on`) or goes away. Opens the notch if you have not turned that
    /// off, and closes it on the way out only if it opened it, and never during a take. Not under tests:
    /// the window pictures show Record with its own prompter.
    func follow(record on: Bool, _ app: AppModel) {
        if on {
            guard Self.auto, !shown, !AppModel.testing else { return }
            show(app)
            autoOpened = true
        } else if autoOpened, shown, !app.isRecording {
            hide()
        }
    }

    func show(_ app: AppModel) {
        self.app = app
        autoOpened = false
        // One prompter at a time: Record puts a small stand-in where the big script was.
        app.notchOpen = true
        let p = panel ?? make()
        panel = p
        place(glow: true)
        // Front without making Takes the active app: the app you show keeps the keyboard.
        p.orderFrontRegardless()
        if screenWatch == nil {
            screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
    }

    func hide() {
        autoOpened = false
        panel?.orderOut(nil)
        app?.notchOpen = false
        app?.notchTour = false
    }

    var contentForTest: NSView? { panel?.contentView }

    /// The built-in display (the one with the notch), else the main one.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The text part's height for a number of lines, with the bar under it.
    static func body(lines: Int) -> CGFloat {
        let line = fontSize * 1.35 + 0.5
        return (CGFloat(lines) * line).rounded() + 24 + NotchView.barHeight
    }

    /// Sizes the panel for its screen and line count, and draws it new for that shape. `glow`:
    /// a soft blue light round the panel for a moment, to bring the eye up to the notch.
    func place(glow: Bool = false) {
        guard let panel, let app, let screen = Self.screen else { return }
        var lines = UserDefaults.standard.object(forKey: "notchLines") as? Int ?? 3
        // The tour needs five lines of room; the panel goes back to your size after it.
        if UserDefaults.standard.integer(forKey: NotchView.introKey) < NotchView.intro.count { lines = max(lines, 5) }
        let layout = NotchLayout.make(for: screen, body: Self.body(lines: lines))
        panel.contentView = NSHostingView(rootView: NotchView(layout: layout, glow: glow, close: { [weak self] in self?.close() }).environment(app))
        // Clear room round the sides and the bottom for the glow. Clicks there go to the app under it.
        let m = NotchView.margin
        let f = layout.frame
        panel.setFrame(CGRect(x: f.minX - m, y: f.minY - m, width: f.width + 2 * m, height: f.height + m), display: true)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // isFloatingPanel sets the floating level, under the menu bar: set the level after it.
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovable = false
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        return p
    }
}

/// What the panel shows: the script, two to six lines, and a small bar.
struct NotchView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("notchLines") private var lines = 3
    @AppStorage(NotchView.introKey) private var introStep = 0
    @State private var hover = false
    /// What the button under the pointer does. The panel never takes focus, so macOS does not
    /// show tooltips on it: the bar shows this text instead.
    @State private var tip: String?
    let layout: NotchLayout
    var glow = false
    let close: () -> Void
    /// How bright the glow is now: 0 is off. A test can start it lit.
    @State var lit: Double = 0
    static let barHeight: CGFloat = 34
    /// The clear room round the panel that the glow spreads into.
    static let margin: CGFloat = 28

    /// The first-time tour: three steps, each with an icon and the bar buttons it talks about.
    /// The other buttons go dim, so the eye goes to the one that matters (2026-10-07: the first
    /// version was too quiet, and read as part of the panel, not as a tour).
    static let introKey = "notchIntroStep"
    static let intro: [(icon: String, title: String, text: String, buttons: Set<String>)] = [
        ("eye", "Look here while you talk", "Your script sits right under the camera, so your eyes stay on the lens.", []),
        ("waveform", "Press ▶ and just talk", "The text moves with your voice. There is no speed to set.", ["play", "voice"]),
        ("record.circle", "Press ● to record a take", "Point at any button to see what it does.", ["record"]),
    ]
    private var introOn: Bool { introStep < Self.intro.count }

    var body: some View {
        let shape = NotchShape(band: layout.band, notchWidth: layout.notchWidth)
        ZStack(alignment: .top) {
            // The glow: two soft layers of the accent blue in the panel's shape, under it.
            ZStack {
                shape.fill(Theme.accent).blur(radius: 22).opacity(0.7)
                shape.stroke(Theme.accent, lineWidth: 3).blur(radius: 6)
            }
            .frame(width: layout.frame.width, height: layout.frame.height)
            .opacity(lit)
            .allowsHitTesting(false)
            panel.frame(width: layout.frame.width, height: layout.frame.height)
        }
        .padding(.horizontal, Self.margin).padding(.bottom, Self.margin)
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
        return VStack(spacing: 0) {
            Color.clear.frame(height: layout.band)
            Prompter(text: .constant(app.promptText), contentKey: "notch#" + app.promptKey, fontSize: size,
                     scrolling: app.scrolling && !hover, speed: app.speed * size / max(app.fontSize, 1),
                     editable: false, resetToken: app.resetToken, dark: true,
                     voice: app.following ? app.voice : nil, readingLine: 0,
                     inset: NSSize(width: 24, height: 2), darkPage: .black)
                .padding(.top, 12)
                // The last line fades into the bar instead of being cut.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
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
            bar.frame(height: Self.barHeight)
        }
        .background(NotchShape(band: layout.band, notchWidth: layout.notchWidth).fill(.black))
        .clipShape(NotchShape(band: layout.band, notchWidth: layout.notchWidth))
        .environment(\.colorScheme, .dark)
        .onHover { hover = $0 }
        // The panel draws a new view for the new size: not in the middle of this one's update.
        .onChange(of: lines) { DispatchQueue.main.async { NotchPanel.shared.place() } }
        .onChange(of: introOn) { _, on in DispatchQueue.main.async { NotchPanel.shared.place(glow: on) } }
        .onChange(of: introOn, initial: true) { _, on in
            let tour = on && app.notchOpen
            DispatchQueue.main.async { if app.notchTour != tour { app.notchTour = tour } }
        }
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

    private var bar: some View {
        HStack(spacing: 4) {
            record
            Spacer(minLength: 4)
            if let tip {
                Text(tip).font(Theme.sans(11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
            button(app.scrolling ? "pause.fill" : "play.fill",
                   app.following ? (app.scrolling ? "Stop listening" : "Start: the text follows your voice")
                                 : (app.scrolling ? "Pause" : "Start scrolling"), id: "play") {
                app.scrolling.toggle()
            }
            button("waveform", app.followVoice ? "Voice follow is on. Click to scroll at a set speed." : "Voice follow is off. Click to follow your voice.",
                   on: app.followVoice, id: "voice") { app.followVoice.toggle() }
            button("arrow.up.to.line", "Back to the top") { app.resetToken += 1 }
            button("rectangle.compress.vertical", lines <= 2 ? "Fewer lines (2 is the least)" : "Fewer lines") { lines = max(2, lines - 1) }
                .disabled(lines <= 2)
            button("rectangle.expand.vertical", lines >= 6 ? "More lines (6 is the most)" : "More lines") { lines = min(6, lines + 1) }
                .disabled(lines >= 6)
            button("questionmark", "Take the quick tour again", id: "tour") { introStep = 0 }
            button("xmark", "Close the panel (⌥⌘N)") { close() }
        }
        .animation(.easeOut(duration: 0.12), value: tip)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    /// Record from the notch: a red dot, and the time while a take runs.
    private var record: some View {
        Button { app.toggleRecord() } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5).frame(width: 16, height: 16)
                    RoundedRectangle(cornerRadius: app.isRecording ? 2 : 5)
                        .fill(Theme.danger)
                        .frame(width: app.isRecording ? 7 : 10, height: app.isRecording ? 7 : 10)
                }
                if case .recording(let since) = app.phase {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(since)))
                        Text("\(s / 60):\(String(format: "%02d", s % 60))")
                            .font(Theme.sans(12, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .frame(height: 26).padding(.horizontal, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { if ring("record") { Ring().frame(width: 30, height: 30).offset(x: app.isRecording ? -20 : 0) } }
        .opacity(dim("record"))
        .onHover { tipFor(app.isRecording ? "Stop the take" : "Record a take with your camera and mic", $0) }
        .animation(Theme.motion, value: app.isRecording)
    }

    private func tipFor(_ text: String, _ inside: Bool) {
        if inside { tip = text } else if tip == text { tip = nil }
    }

    private func button(_ icon: String, _ help: String, on: Bool = false, id: String = "", _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(on ? Theme.accent.opacity(0.55) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { if ring(id) { Ring().frame(width: 30, height: 30) } }
        .opacity(id == "tour" ? 1 : dim(id))
        .onHover { tipFor(help, $0) }
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
