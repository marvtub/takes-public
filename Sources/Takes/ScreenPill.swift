import AppKit
import AVFoundation
import SwiftUI

// The screen pill (2026-10-13, design A1 on the canvas). One small bar over every app: pick
// Screen + camera, Screen or Camera, open the script in the notch, pick the camera, see the mic,
// and record. While a take runs the same bar has the time, Start over and Stop. With the notch
// open, the notch has the time, so there is one timer on screen. A round camera bubble shows you.
//
// Both panels are Takes windows, so ScreenRecorder leaves them out of the screen file.
// 2026-10-14: the pill is the one way to record the screen (Record's "Screen" button opens it).
// The Takes window goes away while the pill is up, and comes back when you close it or a take
// ends, on the new take.

@MainActor
final class ScreenPill {
    static let shared = ScreenPill()

    private var panel: NSPanel?
    private var bubble: NSPanel?
    private weak var app: AppModel?
    /// The Takes windows the pill put away. They come back when it goes.
    private var hidden: [NSWindow] = []
    private var moves: [NSObjectProtocol] = []
    /// A take ran since the pill came up: back to idle then means it ended, not a cancelled count.
    private var took = false

    /// Clear room round the bar and the bubble, so their shadows fade out and are not cut off at
    /// the window's edge (2026-10-14: hard, edgy shadows).
    static let room: CGFloat = 32
    static let barHeight: CGFloat = 48
    static let size = NSSize(width: 460 + 2 * room, height: barHeight + 2 * room)
    static let bubbleSize: CGFloat = 170
    static var bubbleWindow: CGFloat { bubbleSize + 2 * room }
    // New keys with the room: the old places were for the smaller windows.
    static let originKey = "screenPillOrigin"
    static let bubbleKey = "screenPillBubbleOrigin"

    var shown: Bool { panel?.isVisible == true }
    /// The pill has the Takes window put away: Takes must not quit for that (AppDelegate).
    var holdsWindows: Bool { !hidden.isEmpty }
    /// The bubble keeps the camera on (AppModel.holdCamera).
    var bubbleShown: Bool { bubble?.isVisible == true }

    func toggle(_ app: AppModel) { shown ? hide() : show(app) }

    func show(_ app: AppModel) {
        self.app = app
        guard app.phase == .idle else { return }
        // Opening the pill means the screen: a camera-only mode becomes screen and camera.
        if !app.mode.hasScreen { app.mode = .cameraScreen }
        took = false
        let p = panel ?? make(movable: true)
        if panel == nil {
            let host = NSHostingView(rootView: ScreenPillView().environment(app))
            host.frame = NSRect(origin: .zero, size: Self.size)
            p.contentView = host
            p.setContentSize(Self.size)
            p.setFrameOrigin(Self.origin(Self.originKey) ?? Self.defaultOrigin())
            watch(p, key: Self.originKey)
            panel = p
        }
        p.orderFrontRegardless()
        app.screenPillOpen = true
        syncBubble()
        if hidden.isEmpty { putAway() }
        // Not under tests: listing windows asks for screen recording access.
        if !AppModel.testing { Task { await app.screen.refreshWindows() } }
    }

    /// Full-screen Takes windows the pill took out of full screen. They go back in on the way back.
    private var wasFull: [NSWindow] = []
    private var exits: [NSObjectProtocol] = []

    /// The Takes window goes away, so it is not in front of what you show. A full-screen window
    /// first leaves full screen: put away in full screen it left a black Space (2026-10-14).
    private func putAway() {
        hidden = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0 !== panel && $0 !== bubble }
        for w in hidden {
            guard w.styleMask.contains(.fullScreen) else { w.orderOut(nil); continue }
            wasFull.append(w)
            exits.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let p = ScreenPill.shared
                    if p.hidden.contains(where: { $0 === w }) { w.orderOut(nil) }
                }
            })
            w.toggleFullScreen(nil)
        }
    }

    private func bringBack() {
        exits.forEach(NotificationCenter.default.removeObserver)
        exits = []
        for w in hidden {
            w.makeKeyAndOrderFront(nil)
            if wasFull.contains(where: { $0 === w }), !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
        hidden = []
        wasFull = []
        NSApp.activate()
    }

    /// The pill goes, and the Takes window comes back. Record is camera only again: the screen
    /// is recorded only from the pill.
    func hide() {
        guard let app, app.phase == .idle else { return }
        panel?.orderOut(nil)
        bubble?.orderOut(nil)
        app.screenPillOpen = false
        app.mode = .camera
        app.screen.windowID = nil
        bringBack()
        app.holdCamera()
    }

    /// The bubble shows while the pill does, for a mode with the camera.
    func syncBubble() {
        guard let app, shown, app.mode.hasCamera else {
            bubble?.orderOut(nil)
            app?.holdCamera()
            return
        }
        let b = bubble ?? make(movable: true)
        if bubble == nil {
            let side = Self.bubbleWindow
            let host = NSHostingView(rootView: PillBubble(session: app.camera.session, rotation: app.camera.previewRotation).environment(app))
            host.frame = NSRect(x: 0, y: 0, width: side, height: side)
            b.contentView = host
            b.setContentSize(NSSize(width: side, height: side))
            b.setFrameOrigin(Self.origin(Self.bubbleKey) ?? Self.defaultBubbleOrigin())
            watch(b, key: Self.bubbleKey)
            bubble = b
        }
        b.orderFrontRegardless()
        Task { await app.camera.resume() }
    }

    func record() { app?.toggleRecord() }

    /// The phase changed. A take that ended closes the pill, and the Takes window comes back on
    /// it. A cancelled count keeps the pill up.
    func phase(_ now: Phase) {
        if case .recording = now { took = true }
        guard now == .idle, took, shown else { return }
        took = false
        hide()
    }

    private func watch(_ p: NSPanel, key: String) {
        moves.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            UserDefaults.standard.set([w.frame.origin.x, w.frame.origin.y], forKey: key)
        })
    }

    /// A saved place, if it is still on a screen.
    static func origin(_ key: String) -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 2 else { return nil }
        let p = NSPoint(x: a[0], y: a[1])
        return NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(p) } ? p : nil
    }

    static func defaultOrigin() -> NSPoint {
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: (f.midX - size.width / 2).rounded(), y: f.minY + 28 - room)
    }

    static func defaultBubbleOrigin() -> NSPoint {
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: f.minX + 32 - room, y: f.minY + 32 - room)
    }

    private func make(movable: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovableByWindowBackground = movable
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        return p
    }
}

/// The colours of the pill: dark on any wallpaper, like the notch.
private enum Pill {
    static let fill = Color(red: 0.118, green: 0.118, blue: 0.125)
    static let line = Color.white.opacity(0.14)
    static let on = Color.white.opacity(0.16)
    static let ink = Color.white
    static let dim = Color.white.opacity(0.55)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
}

struct ScreenPillView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 2) {
            switch app.phase {
            case .idle: idle
            case .warming, .countdown, .starting: counting
            case .recording(let since): recording(since)
            case .finishing:
                Text("Saving the take…").font(Theme.sans(12.5, .medium)).foregroundStyle(Pill.dim).padding(.horizontal, 14)
            }
        }
        .padding(.leading, 6).padding(.trailing, 5)
        .frame(height: ScreenPill.barHeight)
        .background {
            // A soft shadow that fits in the room round the bar, and a hairline inside the edge.
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Pill.fill)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Pill.line, lineWidth: 0.5))
        }
        .frame(width: ScreenPill.size.width, height: ScreenPill.size.height)
        .animation(Theme.motion, value: app.phase)
        .onChange(of: app.phase) { _, now in ScreenPill.shared.phase(now) }
        .onChange(of: app.mode) { ScreenPill.shared.syncBubble() }
    }

    @ViewBuilder private var idle: some View {
        ForEach([Mode.cameraScreen, .screen, .camera]) { m in
            round(icon(m), help: m == .cameraScreen ? "Screen and camera" : m == .screen ? "Screen only" : "Camera only",
                  on: app.mode == m) { app.mode = m }
        }
        divider
        round("text.alignleft", help: "Script in the notch (⌥⌘N)", on: app.notchOpen, accent: true) {
            NotchPanel.shared.toggle(app)
        }
        cameraMenu
        mic
        PillScreenMenu(screen: app.screen, on: app.mode.hasScreen)
        recordButton
        Button { ScreenPill.shared.hide() } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Pill.dim)
                .frame(width: 22, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Close the pill: back to Takes (⌥⌘R)")
    }

    private var counting: some View {
        HStack(spacing: 10) {
            Text(countText).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Pill.ink).frame(minWidth: 26)
            Text("Get ready").font(Theme.sans(12.5, .medium)).foregroundStyle(Pill.dim)
            round("xmark", help: "Cancel", on: false) { app.toggleRecord() }
        }
        .padding(.leading, 10)
    }

    private var countText: String {
        if case .countdown(let n) = app.phase { return "\(n)" }
        return "·"
    }

    private func recording(_ since: Date) -> some View {
        HStack(spacing: 2) {
            // One timer on screen: the notch has it while it is open.
            if !app.notchOpen {
                Circle().fill(Pill.red).frame(width: 8, height: 8).padding(.leading, 10)
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(since)))
                    Text("\(s / 60):\(String(format: "%02d", s % 60))")
                        .font(Theme.sans(14, .semibold)).monospacedDigit().foregroundStyle(Pill.ink)
                }
                .frame(width: 52, alignment: .leading).padding(.leading, 6)
            }
            round("arrow.counterclockwise", help: "Start over: this take goes away and the count runs again", on: false) {
                app.restartTake()
            }
            Button { app.toggleRecord() } label: {
                RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
                    .frame(width: 38, height: 38).background(Pill.red, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).padding(.leading, 4).help("Stop (⌘R)")
        }
    }

    private var recordButton: some View {
        Button { ScreenPill.shared.record() } label: {
            Circle().fill(.white).frame(width: 14, height: 14)
                .frame(width: 38, height: 38).background(Pill.red, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).padding(.leading, 4).help("Record")
    }

    private var cameraMenu: some View {
        let camera = app.camera
        return TakesMenuButton(help: "Which camera") {
            Image(systemName: "video").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(app.mode.hasCamera ? Pill.ink : Pill.dim)
                .frame(width: 38, height: 38).contentShape(Circle())
        } content: {
            for d in camera.videoDevices {
                MenuButton(d.localizedName, icon: "video", checked: d.uniqueID == camera.videoID) { camera.chooseVideo(d.uniqueID) }
            }
        }
        .opacity(app.mode.hasCamera ? 1 : 0.4)
        .disabled(!app.mode.hasCamera)
    }

    private var mic: some View {
        let camera = app.camera
        return TakesMenuButton(help: "Which microphone") {
            VStack(spacing: 3) {
                Image(systemName: "mic").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pill.ink)
                LevelMeter(meter: camera.meter, track: Pill.line, fill: Theme.live)
                    .frame(width: 16, height: 2).clipShape(Capsule())
            }
            .frame(width: 38, height: 38).contentShape(Circle())
        } content: {
            for d in camera.audioDevices {
                MenuButton(d.localizedName, icon: "mic", checked: d.uniqueID == camera.audioID) { camera.chooseAudio(d.uniqueID) }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Pill.line).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func icon(_ m: Mode) -> String {
        switch m {
        case .cameraScreen: "rectangle.inset.filled.and.person.filled"
        case .screen: "display"
        case .camera: "person.crop.square"
        }
    }

    private func round(_ icon: String, help: String, on: Bool, accent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Pill.ink : Pill.dim)
                .frame(width: 38, height: 38)
                .background(on ? (accent ? Theme.accent.opacity(0.55) : Pill.on) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// You, round, over every app. Drag it anywhere.
struct PillBubble: View {
    let session: AVCaptureSession
    var rotation: CGFloat = 0

    var body: some View {
        let side = ScreenPill.bubbleSize
        // The shadow on a plain circle under the camera: on the camera view itself it came out
        // cut off at the window's edge (2026-10-14).
        ZStack {
            Circle().fill(.black).shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            CameraPreview(session: session, fill: true, rotation: rotation, corner: (side - 8) / 2)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        }
        .frame(width: side - 8, height: side - 8)
        .frame(width: ScreenPill.bubbleWindow, height: ScreenPill.bubbleWindow)
    }
}

/// What the screen take records: the whole screen (which one, with more than one) or one app
/// window (2026-10-14: the pill had no way to choose). The window list is fresh when you point at
/// the button.
private struct PillScreenMenu: View {
    @ObservedObject var screen: ScreenRecorder
    let on: Bool

    var body: some View {
        let window = screen.windows.first { $0.id == screen.windowID }
        TakesMenuButton(help: window.map { "Recording \($0.app) only" } ?? "Recording the whole screen") {
            Image(systemName: window == nil ? "display" : "macwindow").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Pill.ink : Pill.dim)
                .frame(width: 38, height: 38).contentShape(Circle())
        } content: {
            MenuLabel("Whole screen")
            if screen.displays.count > 1 {
                for d in screen.displays {
                    MenuButton(d.name, icon: "display", checked: screen.windowID == nil && d.id == screen.displayID) {
                        screen.windowID = nil
                        screen.displayID = d.id
                    }
                }
            } else {
                MenuButton("Whole screen", icon: "display", checked: screen.windowID == nil) { screen.windowID = nil }
            }
            MenuLabel("One window")
            if screen.windows.isEmpty { MenuLabel("No windows open") }
            for w in screen.windows {
                MenuButton(w.title.isEmpty ? w.app : "\(w.app) – \(w.title)", icon: "macwindow", checked: w.id == screen.windowID) {
                    screen.windowID = w.id
                }
            }
        }
        .onHover { if $0 { Task { await screen.refreshWindows() } } }
        .opacity(on ? 1 : 0.4)
        .disabled(!on)
    }
}
