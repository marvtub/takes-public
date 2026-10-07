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

    static let minWidth: CGFloat = 460
    /// How far the text reaches past each side of the notch.
    static let wing: CGFloat = 130

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
        p.addLine(to: CGPoint(x: r.maxX - outer, y: r.minY + band))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + band + outer), control: CGPoint(x: r.maxX, y: r.minY + band))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - outer))
        p.addQuadCurve(to: CGPoint(x: r.maxX - outer, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + outer, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - outer), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + band + outer))
        p.addQuadCurve(to: CGPoint(x: r.minX + outer, y: r.minY + band), control: CGPoint(x: r.minX, y: r.minY + band))
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
    static let fontSize: Double = 19
    private var panel: NSPanel?
    private weak var app: AppModel?
    private var screenWatch: NSObjectProtocol?

    var shown: Bool { panel?.isVisible == true }

    func toggle(_ app: AppModel) { shown ? hide() : show(app) }

    func show(_ app: AppModel) {
        self.app = app
        let p = panel ?? make()
        panel = p
        place()
        // Front without making Takes the active app: the app you show keeps the keyboard.
        p.orderFrontRegardless()
        if screenWatch == nil {
            screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
    }

    func hide() { panel?.orderOut(nil) }

    var contentForTest: NSView? { panel?.contentView }

    /// The built-in display (the one with the notch), else the main one.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The text part's height for a number of lines, with the bar under it.
    static func body(lines: Int) -> CGFloat {
        let line = fontSize * 1.35 + 0.5
        return (CGFloat(lines) * line).rounded() + 14 + NotchView.barHeight
    }

    /// Sizes the panel for its screen and line count, and draws it new for that shape.
    func place() {
        guard let panel, let app, let screen = Self.screen else { return }
        let lines = UserDefaults.standard.object(forKey: "notchLines") as? Int ?? 3
        let layout = NotchLayout.make(for: screen, body: Self.body(lines: lines))
        panel.contentView = NSHostingView(rootView: NotchView(layout: layout, close: { [weak self] in self?.hide() }).environment(app))
        panel.setFrame(layout.frame, display: true)
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
    @State private var hover = false
    let layout: NotchLayout
    let close: () -> Void
    static let barHeight: CGFloat = 30

    var body: some View {
        let size = NotchPanel.fontSize
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.band)
            Prompter(text: .constant(app.promptText), contentKey: "notch#" + app.promptKey, fontSize: size,
                     scrolling: app.scrolling && !hover, speed: app.speed * size / max(app.fontSize, 1),
                     editable: false, resetToken: app.resetToken, dark: true,
                     voice: app.following ? app.voice : nil, readingLine: 0,
                     inset: NSSize(width: 24, height: 2), darkPage: .black)
                .padding(.top, 8)
                // The last line fades into the bar instead of being cut.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    if case .countdown(let n) = app.phase {
                        Text("\(n)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
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
    }

    private var bar: some View {
        HStack(spacing: 4) {
            record
            Spacer(minLength: 4)
            button(app.scrolling ? "pause.fill" : "play.fill",
                   app.following ? (app.scrolling ? "Stop listening" : "Listen and follow") : (app.scrolling ? "Pause" : "Scroll")) {
                app.scrolling.toggle()
            }
            button("waveform", app.followVoice ? "Follows your voice. Click to scroll at a set speed." : "Scrolls at a set speed. Click to follow your voice.",
                   on: app.followVoice) { app.followVoice.toggle() }
            button("arrow.up.to.line", "Back to the top") { app.resetToken += 1 }
            button("minus", "Fewer lines") { lines = max(2, lines - 1) }.disabled(lines <= 2)
            button("plus", "More lines") { lines = min(6, lines + 1) }.disabled(lines >= 6)
            button("xmark", "Close") { close() }
        }
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
            .frame(height: 24).padding(.horizontal, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.isRecording ? "Stop the take" : "Record a take (camera and mic, as on Record)")
        .animation(Theme.motion, value: app.isRecording)
    }

    private func button(_ icon: String, _ help: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(on ? Theme.accent.opacity(0.55) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
