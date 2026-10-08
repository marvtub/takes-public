import SwiftUI

/// A board that one person adds to Takes for their own work (2026-10-05): it gets a sidebar row,
/// a ⇧⌘ shortcut in the Window menu and the window in place of the sessions. The plugin brings its
/// own data and can run its own agent (another CLI or model than the chat).
///
/// Private plugins live in Plugins/Private. The public copy leaves that folder out and gets an
/// empty `PrivatePlugins.list` (scripts/public/export.py), so their code never ships. To make one
/// public, move its file up to Plugins/ and add it to `Plugins.all` here.
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
}

enum Plugins {
    static var all: [TakesPlugin] { PrivatePlugins.list }
    /// The plugins with a board of their own.
    static var boards: [TakesPlugin] { all.filter { $0.board != nil } }
    static func named(_ id: String) -> TakesPlugin? { all.first { $0.id == id } }
    static var postSides: [PostSide] { all.flatMap(\.postSides) }
    static func postSide(_ id: String) -> PostSide? { postSides.first { $0.id == id } }
    /// The user's own build (the public copy has no private plugins). Only his build looks in
    /// ~/Documents: on another Mac even a look there makes macOS ask for the folder.
    static var own: Bool { !PrivatePlugins.list.isEmpty }
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
