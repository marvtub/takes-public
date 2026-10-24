import Foundation
import Observation
import SwiftUI

/// Public view (2026-10-22): the admin build shows Takes as the public copy shows it. The admin
/// boards, plugins, menu items and chat tools go; the user's data, paths and background jobs stay.
/// The switch is live: views that read `PublicView.on` (or Features, Plugins.available) redraw when
/// it flips. The public copy has no private plugins, so there `on` is always false.
@Observable
final class PublicView: @unchecked Sendable {
    static let shared = PublicView()
    static let key = "publicView"
    /// The chat's takes server hides the admin tools when the app starts it with this set to "1".
    static let envKey = "TAKES_PUBLIC_VIEW"

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var stored = UserDefaults.standard.bool(forKey: PublicView.key)

    /// The saved switch. Safe from any thread (the phone server reads it too).
    var isOn: Bool {
        get { access(keyPath: \.isOn); return lock.withLock { stored } }
        set {
            withMutation(keyPath: \.isOn) {
                lock.withLock { stored = newValue }
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// True only in the admin build with the switch on.
    static var on: Bool { Plugins.own && (forced ?? shared.isOn) }

    /// Tests set this for their own task only, so tests that run beside them see the real switch.
    @TaskLocal static var forced: Bool?
}

extension PublicView {
    /// Turns Public view on or off from a menu, Settings or the sidebar pill. A board it hides closes.
    @MainActor static func set(_ on: Bool, _ app: AppModel) {
        guard Plugins.own, on != shared.isOn else { return }
        shared.isOn = on
        if on { app.closeHiddenBoard() }
        app.show(toast: on ? "Public view on" : "Public view off", icon: on ? "eye" : "eye.slash")
    }

    @MainActor static func binding(_ app: AppModel) -> Binding<Bool> {
        Binding(get: { shared.isOn }, set: { set($0, app) })
    }
}

extension AppModel {
    /// The open board, if Public view hides it now: Performance, Comments or an admin plugin board.
    func closeHiddenBoard() {
        switch board {
        case .performance?, .comments?: if !Features.socialBoards { board = nil }
        case .plugin(let id)?: if Plugins.named(id) == nil { board = nil }
        default: break
        }
    }
}

/// The sidebar foot while Public view is on (2026-10-22): says so, and Exit goes back.
struct PublicViewPill: View {
    @Environment(AppModel.self) var app
    @State private var hover = false

    var body: some View {
        Button { PublicView.set(false, app) } label: {
            HStack(spacing: 9) {
                Image(systemName: "eye").frame(width: 16)
                Text("Public view").font(Theme.sans(13, .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("Exit").font(Theme.sans(12, .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentInk.opacity(hover ? 0.22 : 0.14), in: Capsule())
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accentInk.opacity(hover ? 0.16 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("You see Takes as the public app shows it. Exit shows the admin parts again (⌥⌘P).")
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}
