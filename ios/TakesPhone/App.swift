import SwiftUI
import UIKit

@main
struct TakesPhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = Model()
    @Environment(\.scenePhase) private var scene

    init() { Brand.registerFonts() }

    var body: some Scene {
        WindowGroup {
            Root()
                .environmentObject(model)
                .environmentObject(model.live)
                .tint(Palette.accent)
                .font(.inter(.body))
                .foregroundStyle(Palette.ink)
                .preferredColorScheme(Look.shared.mode.scheme)
                .onAppear { delegate.model = model }
        }
        .onChange(of: scene) { _, p in model.scene(p) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: Model?

    /// iOS woke the app because background uploads finished.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard let model = self.model else { completionHandler(); return }
            model.uploads.backgroundDone = completionHandler
            _ = model.uploads.session
        }
    }
}

enum Palette {
    // The look picked on this phone (Look.swift): the Takes brand kit unless changed. Reading a
    // color makes the view redraw when the look changes.
    private static var c: LookColors { Look.shared.colors }
    static var accent: Color { c.accent }
    static var accentInk: Color { c.accentInk }
    static var paper: Color { c.paper }
    static var canvas: Color { c.canvas }
    static var well: Color { c.well }
    static var ink: Color { c.ink }
    static var muted: Color { c.muted }
    static var faint: Color { c.faint }
    static var border: Color { c.border }
    static var surface: Color { c.surface }
    static let live = Color(light: 0x16A36A, dark: 0x4FD69A)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { t in
            let v = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

struct Root: View {
    @EnvironmentObject var model: Model

    var body: some View {
        if model.phase == .pairing {
            PairView()
        } else {
            // The relock covers the screens instead of ending them: after Face ID, the user is back
            // on the same video, tab and scroll place, and nothing loads again (2026-10-08).
            ZStack {
                if model.opened {
                    Tabs()
                        .allowsHitTesting(model.phase == .open)
                        .accessibilityHidden(model.phase != .open)
                }
                if model.phase == .locked { LockView().transition(.opacity) }
            }
            .animation(Brand.quick, value: model.phase)
        }
    }
}

/// Videos, the comment copilot and the numbers, as on the Mac. The system tab bar is hidden: each
/// main screen carries the brand's floating bar, so it goes away when a video opens.
struct Tabs: View {
    @EnvironmentObject var model: Model
    /// Always opens on the list of videos, as the Mac opens on its sidebar: with no tab bar, a
    /// remembered Comments page hid the list (2026-10-04).
    @State private var tab = "videos"
    private static let base: Set<String> = ["videos", "comments", "performance", "styles"]

    var body: some View {
        // Five pages at most: a sixth makes iOS add its own More list, with a stock back button
        // (2026-10-09). Search and the plugin screens share the last page.
        TabView(selection: Binding(get: { Self.base.contains(tab) ? tab : "extra" }, set: { if $0 != "extra" { tab = $0 } })) {
            SessionsView().toolbar(.hidden, for: .tabBar).tag("videos")
            CopilotView().toolbar(.hidden, for: .tabBar).tag("comments")
            NavigationStack { PerformanceView() }.toolbar(.hidden, for: .tabBar).tag("performance")
            NavigationStack { StylesView() }.toolbar(.hidden, for: .tabBar).tag("styles")
            Group {
                if tab.hasPrefix("plugin:") {
                    // The Mac plugins with a phone screen (2026-10-09): admin only, none in the public copy.
                    NavigationStack { PrivatePhone.screen(String(tab.dropFirst("plugin:".count))) }.id(tab)
                } else {
                    SearchView()
                }
            }
            .toolbar(.hidden, for: .tabBar).tag("extra")
        }
        .environment(\.tabBar, $tab)
    }
}

private struct TabBarKey: EnvironmentKey { static let defaultValue: Binding<String>? = nil }

extension EnvironmentValues {
    /// The selected main tab, for the floating bar on each main screen.
    var tabBar: Binding<String>? {
        get { self[TabBarKey.self] }
        set { self[TabBarKey.self] = newValue }
    }
}

extension View {
    /// A main screen: Videos, Comments or Performance.
    func withTabBar() -> some View { modifier(TabBarInset()) }
}

private struct TabBarInset: ViewModifier {
    func body(content: Content) -> some View {
        // No floating tab bar (2026-10-04): the list of videos leads to Comments and Performance,
        // as the Mac's sidebar does. Content fades out under the clock.
        content.overlay(alignment: .top) { TopFade() }
    }
}

// MARK: - Pair and lock

struct PairView: View {
    @EnvironmentObject var model: Model
    @State private var waiting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image("Mascot").resizable().scaledToFit().frame(width: 84, height: 84)
                    .shadow(color: Palette.shadow, radius: 10, y: 6)
                    .padding(.top, 60)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect to Takes").font(.nunito(size: 34, heavy: true, relativeTo: .largeTitle))
                    Text("Your Mac runs Takes. This phone reaches it over Tailscale, only from your own devices.")
                        .font(.inter(.callout)).foregroundStyle(Palette.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac address").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.muted)
                    TextField("https://…ts.net:8444", text: $model.server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .font(.inter(.callout))
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.border))
                }
                if waiting {
                    HStack(spacing: 10) {
                        WorkingDots()
                        Text("Click **Allow** in Takes on your Mac.").font(.inter(.callout))
                    }
                    .transition(.opacity)
                }
                if let e = model.error { Text(e).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
                Button {
                    waiting = true
                    Task { await model.pair(); waiting = false }
                } label: {
                    Text(waiting ? "Waiting for the Mac…" : "Connect")
                }
                .buttonStyle(.pill(wide: true)).disabled(waiting)
                Text("After this, Face ID opens the app.").font(.inter(.footnote)).foregroundStyle(Palette.faint)
            }
            .padding(24)
            .animation(Brand.quick, value: waiting)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }
}

struct LockView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            MascotEmpty(title: "Takes is locked", message: "Face ID opens it.") {
                Button { Task { await model.unlock() } } label: { Label("Unlock", systemImage: "faceid") }
                    .buttonStyle(.pill())
            }
            Spacer()
            Button("Forget this Mac", role: .destructive) { model.unpair() }
                .font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
                .buttonStyle(.press)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Palette.canvas.ignoresSafeArea())
        .task { await model.unlock() }
    }
}
