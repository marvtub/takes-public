import SwiftUI

/// A board that one person adds to Takes for their own work (2026-10-05): it gets a sidebar row,
/// a ⇧⌘ shortcut in the Window menu and the window in place of the sessions. The plugin brings its
/// own data and can run its own agent (another CLI or model than the chat).
///
/// Private plugins live in Plugins/Private. The public copy leaves that folder out and gets an
/// empty `PrivatePlugins.list` (scripts/public/export.py), so their code never ships. To make one
/// public, move its file up to Plugins/ and add it to `Plugins.available` here.
///
/// The Plugins board (sidebar foot, 2026-10-08) turns them on and off and holds their settings.
/// An off plugin keeps its code and files, but loses its sidebar row, tabs and buttons until it is
/// on again. Feedback, Replicate, Higgsfield and Voices are public plugins (Plugins/Feedback.swift,
/// Replicate.swift, Higgsfield.swift and ElevenLabs.swift); the last two were Settings pages before.
struct TakesPlugin: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// ⇧⌘ and this key opens the board.
    let key: Character
    let help: String
    /// The right side of the sidebar row: a count, or a spinner while the plugin works.
    let badge: @MainActor (AppModel) -> AnyView
    /// The board. None: the plugin lives elsewhere (on the Post tab, say) and gets no sidebar
    /// row, shortcut or ⌘K entry.
    let board: (@MainActor (AppModel) -> AnyView)?
    /// More sides for a session's Post tab, after LinkedIn, X and the rest.
    var postSides: [PostSide] = []
    /// Its settings on the Plugins board, under its title, while it is on (the Higgsfield sign-in,
    /// the voices, the Skills plugin's list of skills).
    var settings: (@MainActor (AppModel) -> AnyView)? = nil
    /// Its part of the Record stage (2026-10-08, Reactions).
    var record: RecordHook? = nil
    /// Its screen on the iPhone (2026-10-09): the routes the phone's screen calls. The phone lists
    /// the plugins that have one (GET /api/plugins) and draws the screen itself.
    var phone: PhoneHook? = nil
}

/// A plugin's part of the phone server. `route` answers the requests it knows (with the library
/// root), nil for the rest.
struct PhoneHook {
    let route: @Sendable (_ request: PhoneRequest, _ root: URL) async -> PhoneResponse?
}

/// A plugin screen the phone can show, for its list's foot.
struct PhonePluginInfo: Codable, Hashable {
    var id: String
    var title: String
    var icon: String
}

/// A plugin on the Record stage. With `active`, its view takes the stage, the camera moves to a
/// corner of it, and Space goes to the plugin, not the script. It hears each take start and end.
struct RecordHook {
    /// The plugin has something on the stage for this session.
    let active: @MainActor (_ session: URL) -> Bool
    /// The view on the stage, under the camera.
    let stage: @MainActor (_ app: AppModel, _ session: URL) -> AnyView
    /// A small button on the stage while it is not active (how to start it).
    let button: @MainActor (_ app: AppModel, _ session: URL) -> AnyView
    /// Space on Record.
    let space: @MainActor (_ app: AppModel) -> Void
    /// A take starts (`started` is its first frame) or ends.
    let take: @MainActor (_ moment: TakeMoment) -> Void
}

struct TakeMoment {
    let session: URL
    let number: Int
    let started: Date?
    var ended: Bool { started == nil }
}

/// A side a plugin adds to the Post tab's switch (2026-10-07). Its id is kept in "postPlatform"
/// like a platform's.
struct PostSide: Identifiable {
    let id: String
    let name: String
    let help: String
    /// The small logo in the switch.
    let mark: @MainActor () -> AnyView
    /// The session has a post on this side: the switch marks it with a dot.
    let has: @MainActor (_ session: URL) -> Bool
    /// The pane. `switcher` is the Post tab's switch, for the pane's top bar.
    let pane: @MainActor (_ session: URL, _ switcher: AnyView) -> AnyView
    /// What the session's chat hears while this side is open.
    let context: @MainActor (_ session: URL) -> String
    /// The session's posts on this side for the phone's Post tab (2026-10-07). None: the phone
    /// does not show the side.
    var phone: (@MainActor (_ session: URL) -> [PhoneSidePost])? = nil
    /// A change from the phone: {"file", and "title", "text" or "status", "base"}. Nil when done,
    /// else what went wrong.
    var phoneSave: (@MainActor (_ session: URL, _ change: [String: String]) -> String?)? = nil
}

enum Plugins {
    /// Every plugin this build has, on or off: the public ones, then the user's.
    static var available: [TakesPlugin] { [Feedback.plugin, ReplicatePage.plugin, HiggsfieldPage.plugin, VoicesPage.plugin] + PrivatePlugins.list }
    /// The plugin the Plugins board shows.
    static let pickedKey = "pluginsPicked"
    /// The installed ones. Read from UserDefaults (not an observed model), so the phone server can
    /// ask off the main thread; views that list plugins watch the key with @AppStorage.
    static var all: [TakesPlugin] { available.filter { !removed.contains($0.id) } }
    static let removedKey = "pluginsRemoved"
    /// Plugins start installed: a removal is what is saved.
    static var removed: Set<String> {
        Set((UserDefaults.standard.string(forKey: removedKey) ?? "").split(separator: ",").map(String.init))
    }
    static func isInstalled(_ id: String) -> Bool { !removed.contains(id) }
    static func setInstalled(_ id: String, _ on: Bool) {
        var r = removed
        if on { r.remove(id) } else { r.insert(id) }
        UserDefaults.standard.set(r.sorted().joined(separator: ","), forKey: removedKey)
    }
    /// The plugins with a board of their own.
    static var boards: [TakesPlugin] { all.filter { $0.board != nil } }
    static func named(_ id: String) -> TakesPlugin? { all.first { $0.id == id } }
    static var postSides: [PostSide] { all.flatMap(\.postSides) }
    static var recordHooks: [RecordHook] { all.compactMap(\.record) }
    static var phoneHooks: [PhoneHook] { all.compactMap(\.phone) }
    /// The hook that has the stage for this session, if one has.
    @MainActor static func recordStage(_ session: URL?) -> RecordHook? {
        guard let session else { return nil }
        return recordHooks.first { $0.active(session) }
    }
    static func postSide(_ id: String) -> PostSide? { postSides.first { $0.id == id } }
    /// The user's own build (the public copy has no private plugins). Only his build looks in
    /// ~/Documents: on another Mac even a look there makes macOS ask for the folder.
    static var own: Bool { !PrivatePlugins.list.isEmpty }
    /// Only in the user's build: the public copy leaves Plugins/Private out (2026-10-08).
    static func adminOnly(_ p: TakesPlugin) -> Bool { PrivatePlugins.list.contains { $0.id == p.id } }
}

/// The sidebar row of a plugin, like Performance and Comments above it.
struct PluginRow: View {
    let plugin: TakesPlugin
    let app: AppModel
    let selected: Bool
    let open: () -> Void

    var body: some View {
        SideRow(selected: selected) {
            NavLabel(icon: plugin.icon, title: plugin.title, key: "⇧⌘\(plugin.key.uppercased())", active: selected) {
                plugin.badge(app)
            }
        }
        .onTapGesture(perform: open)
        .help(plugin.help)
    }
}

/// One line of Settings > Private (2026-10-07): a feature and how the public copy treats it.
/// The list lives in Plugins/Private/FeatureMap.swift; the public copy has none, so the page hides.
struct FeatureEntry: Identifiable {
    enum Kind: String, CaseIterable {
        /// The code is not in the public copy (Plugins/Private).
        case removed = "Removed from the public copy"
        /// The code ships, and a Features switch turns it off.
        case switchedOff = "Switched off in the public copy"
        /// Public code that reads files only this Mac has (gated by Plugins.own or a script).
        case ownFiles = "Uses files only your Mac has"
        /// In both versions.
        case shipped = "Public"
    }
    let name: String
    let icon: String
    let what: String
    let kind: Kind
    /// Where it lives: files, Features switches, plugin ids. The test checks that every private
    /// file, plugin and switch is named here.
    var code: [String] = []
    var id: String { name }
}

/// The Plugins board (2026-10-08): one row at the sidebar's foot, like Styles. Every plugin in a
/// short list on the left; on the right the picked one: what it does, its switch, and its settings.
/// The user asked for one simple place, out of Settings.
struct PluginsBoard: View {
    @Environment(AppModel.self) var app
    @AppStorage(Plugins.removedKey) private var removed = ""
    @AppStorage(Plugins.pickedKey) private var picked = ""

    var body: some View {
        let list = Plugins.available
        let current = list.first { $0.id == picked } ?? list.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plugins").font(Theme.display(22)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.bottom, 12)
                if Plugins.own {
                    // The user's build: public and admin-only plugins apart, so he sees what ships (2026-10-08).
                    group("Public", list.filter { !Plugins.adminOnly($0) }, current)
                    group("Admin only", list.filter(Plugins.adminOnly), current).padding(.top, 14)
                } else {
                    ForEach(list) { p in listRow(p, selected: p.id == current?.id) }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 28)
            .frame(width: 210)
            .background(Theme.surface)
            Rule(vertical: true)
            if let current { detail(current).id(current.id) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func group(_ title: String, _ items: [TakesPlugin], _ current: TakesPlugin?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Theme.sans(10.5, .semibold)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(items) { p in listRow(p, selected: p.id == current?.id) }
        }
    }

    /// Admin build only: whether the public app has this plugin.
    private func scope(_ p: TakesPlugin) -> some View {
        let admin = Plugins.adminOnly(p)
        return Text(admin ? "Admin only · not in the public app" : "Public · in the public app")
            .font(Theme.sans(11, .semibold))
            .foregroundStyle(admin ? Theme.accentInk : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(admin ? Theme.accentSoft : Theme.hover))
    }

    private func isOn(_ p: TakesPlugin) -> Bool { !removed.split(separator: ",").contains(Substring(p.id)) }

    private func listRow(_ p: TakesPlugin, selected: Bool) -> some View {
        let on = isOn(p)
        return Button { withAnimation(Theme.motion) { picked = p.id } } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon).font(.system(size: 12.5)).foregroundStyle(on ? Theme.accentInk : Theme.faint).frame(width: 16)
                Text(p.title).font(Theme.sans(13, selected ? .semibold : .regular)).foregroundStyle(on ? Theme.ink : Theme.muted)
                Spacer(minLength: 4)
                if !on { Text("Off").font(Theme.sans(11.5)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(p.help)
    }

    private func detail(_ p: TakesPlugin) -> some View {
        let on = isOn(p)
        let adds = Self.adds(p)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: p.icon).font(.system(size: 18)).foregroundStyle(Theme.accentInk)
                        .frame(width: 42, height: 42)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.title).font(Theme.display(26)).foregroundStyle(Theme.ink)
                        if Plugins.own { scope(p).padding(.bottom, 2) }
                        Text(p.help).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: Binding(get: { on }, set: { v in withAnimation(Theme.motion) { Plugins.setInstalled(p.id, v) } }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                        .help(on ? "On. Off hides it; its files and sign-ins stay." : "Off. Turn it on to use it.")
                        .padding(.top, 6)
                }
                if !adds.isEmpty {
                    HStack(spacing: 10) {
                        Text(adds).font(Theme.sans(12)).foregroundStyle(Theme.faint)
                        if on, p.board != nil {
                            Button("Open") { app.board = .plugin(p.id) }.buttonStyle(.link).font(Theme.sans(12))
                        }
                    }
                }
                if !on {
                    Text("Off: Takes hides it. Its files and sign-ins stay.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                } else if let settings = p.settings {
                    settings(app)
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            // The page uses the room it has (2026-10-09). The scroll view spans the whole pane, so
            // no scroll bar sits in the middle of it, and the bar stays hidden.
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }

    /// Where the plugin shows up in Takes, in one line.
    static func adds(_ p: TakesPlugin) -> String {
        var parts: [String] = []
        if p.board != nil { parts.append("Its own board in the sidebar, ⇧⌘\(p.key.uppercased())") }
        if !p.postSides.isEmpty { parts.append("Post tab: " + p.postSides.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
