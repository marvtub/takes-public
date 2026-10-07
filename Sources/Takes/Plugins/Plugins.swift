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
    let board: @MainActor (AppModel) -> AnyView
}

enum Plugins {
    static var all: [TakesPlugin] { PrivatePlugins.list }
    static func named(_ id: String) -> TakesPlugin? { all.first { $0.id == id } }
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
