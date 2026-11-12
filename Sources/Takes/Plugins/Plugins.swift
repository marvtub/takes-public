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
/// on again. Feedback, Consistency, Replicate, Higgsfield and Voices are public plugins (Plugins/Feedback.swift, Consistency.swift,
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
    /// Turned on or off on the Plugins board (2026-10-09, Consistency marks its plan file off).
    var toggled: (@MainActor (AppModel, Bool) -> Void)? = nil
    /// What its board chat (hub.boardChat(id)) hears (2026-10-10, Ideas). With one, the phone can
    /// open that chat too, as board:<id>, before the board was ever shown on the Mac.
    var chatContext: (@MainActor () -> String)? = nil
    /// What one of its family chats hears (hub.boardChat("<id>.<key>"), 2026-11-10: a chat per goal), given the key.
    var chatFamily: (@MainActor (String) -> String)? = nil
    /// Runs once when the app starts, for work on a schedule that must not wait for the board
    /// (2026-10-13, a weekly check). The plugin shows the schedule on its board.
    var start: (@MainActor (AppModel) -> Void)? = nil
    /// Its part of the vertical post's card, under "Goes to" (2026-11-06, the admin trial reels): the
    /// session, the vertical edit on show, the caption, the app.
    var vertical: (@MainActor (_ session: URL, _ media: URL?, _ caption: String, _ app: AppModel) -> AnyView)? = nil
    /// Takes posts the post itself at its time (2026-10-25, the admin Zernio plugin): its part of the
    /// Schedule panel, the header button's label, and a layer over the window.
    var autopost: AutopostHook? = nil
    /// Its part of the Plan board, in place of the "Ready, waiting for a slot" list (2026-10-30,
    /// the admin Ready posts feed).
    var planReady: (@MainActor (_ c: PlanReadyContext) -> AnyView)? = nil
    /// Off until the user turns it on (2026-11-06, the admin Mods prototype). Takes marks it off the
    /// first time this build sees it; after that the Plugins board's switch decides, as for the rest.
    var startsOff = false
    /// Its part of a named place in the window (2026-11-06, the admin Mods slots: "performance",
    /// "plan", "home"), with how to open a takes:// link there. Nil: nothing in that place now.
    var slot: (@MainActor (_ name: String, _ open: @escaping (URL) -> Void) -> AnyView?)? = nil
    /// A short note every chat hears, or nil for none now (2026-11-07, the admin Mods: where the
    /// mods live and how to change Takes's own sidebar).
    var agentNote: (@MainActor () -> String?)? = nil
    /// Named board sections. A plugin may reorder them or put a mod around the original native part.
    var sections: (@MainActor (_ board: String, _ available: [String], _ snapshots: BoardSnapshotSource,
                               _ open: @escaping (URL) -> Void, _ native: @escaping (String) -> AnyView) -> AnyView?)? = nil
    /// Its slots and sections still draw in Public view (2026-11-08): the admin Mods then draws only
    /// the shipped mods, which are what users see.
    var drawsInPublicView = false
}

/// A board builds data only on request. A source may finish on the utility worker.
@MainActor struct BoardSnapshotSource {
    typealias Values = [String: [String: Any]]
    let load: (@escaping (Values) -> Void) -> Void
    init(_ snapshots: @escaping () -> Values) { load = { done in done(snapshots()) } }
    init(load: @escaping (@escaping (Values) -> Void) -> Void) { self.load = load }
}

/// Transparent to the board's own stack: no extra layout or spacing when no plugin handles it.
struct BoardSections<Content: View>: View {
    let board: String
    let available: [String]
    var snapshots: () -> [String: [String: Any]] = { [:] }
    var snapshotSource: BoardSnapshotSource? = nil
    var open: (URL) -> Void = { _ in }
    @ViewBuilder var content: (String) -> Content
    @Environment(\.boardSectionsOverride) private var override
    @AppStorage(Plugins.removedKey) private var pluginsRemoved = ""

    var body: some View {
        let _ = pluginsRemoved
        let source = snapshotSource ?? BoardSnapshotSource(snapshots)
        if let override {
            override(board, available, source, open, { AnyView(content($0)) })
        } else if Plugins.drawing.contains(where: { $0.sections != nil }),
           let custom = Plugins.sections(board, available: available, snapshots: source, open: open,
                                         native: { AnyView(content($0)) }) {
            custom
        } else {
            ForEach(available, id: \.self) { content($0) }
        }
    }
}

typealias BoardSectionsHook = @MainActor (String, [String], BoardSnapshotSource, @escaping (URL) -> Void,
                                         @escaping (String) -> AnyView) -> AnyView
private struct BoardSectionsOverrideKey: EnvironmentKey { static let defaultValue: BoardSectionsHook? = nil }
extension EnvironmentValues {
    /// Offscreen verification can supply its own mod store, without touching the app's running store.
    var boardSectionsOverride: BoardSectionsHook? {
        get { self[BoardSectionsOverrideKey.self] }
        set { self[BoardSectionsOverrideKey.self] = newValue }
    }
}

/// A snapshot of values already read by the board, with the same field names as its source file.
enum BoardSectionData {
    static func json<T: Encodable>(_ value: T) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return [:] }
        return object
    }
}

/// What the Plan board hands a plugin's part of it: the plan, what the board counts, and how to
/// open a post on its session's Post tab.
struct PlanReadyContext {
    let root: URL
    let plan: PostingPlan
    let stats: ConsistencyStats
    let openPost: (URL) -> Void
}

/// A plugin that posts for you. The Schedule panel and the header button ask it about each post;
/// nil everywhere means today's panel and button.
struct AutopostHook {
    /// Its part of the Schedule panel for this post. Nil: the panel as it is.
    let panel: @MainActor (_ c: AutopostContext) -> AutopostPanel?
    /// The header button's label for this post. Nil: today's label.
    let label: @MainActor (_ session: URL, _ platform: PostPlatform, _ content: PostFile.Content) -> AutopostLabel?
    /// Over the whole window, like the first take's card.
    let layer: @MainActor (_ app: AppModel) -> AnyView
    /// The same on the phone's Schedule panel (2026-10-30): its routes, with no screen in the list.
    var phone: PhoneHook? = nil
    /// It sends this post and marks it posted itself once it is live: the queue's 15 s settle
    /// leaves it alone, so a failure is not hidden as posted.
    var sends: @Sendable (_ content: PostFile.Content) -> Bool = { _ in false }
    /// It could not post this one: the Plan counts do not count it as out.
    var failed: @Sendable (_ content: PostFile.Content) -> Bool = { _ in false }
}

/// The post and the time on show in the Schedule panel. `save` writes that time to the post (after
/// what is being typed); `close` shuts the panel.
struct AutopostContext {
    let session: URL
    let platform: PostPlatform
    let content: PostFile.Content
    let date: Date
    let zone: TimeZone
    let app: AppModel
    let save: () -> Void
    let close: () -> Void
}

struct AutopostPanel {
    /// Under the time: the offer, the wait, or the account it posts as.
    var block: AnyView
    /// In place of the line under it. Nil: today's line.
    var note: String?
    /// In place of the Set time / Save button. Nil: that button.
    var primary: AnyView?
}

struct AutopostLabel {
    var view: AnyView
    var accent: Bool
    var help: String
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
    static var built: [TakesPlugin] { [Feedback.plugin, Consistency.plugin, ReplicatePage.plugin, HiggsfieldPage.plugin, VoicesPage.plugin, SoundFXPage.plugin, SkillsPlugin.plugin] + PrivatePlugins.list }
    /// The plugins the app shows: in Public view (2026-10-22) only the public ones. Background
    /// jobs and board chats use `built`, so the admin plugins keep running unseen.
    static var available: [TakesPlugin] { PublicView.on ? built.filter { !adminOnly($0) } : built }
    /// The plugin the Plugins board shows.
    static let pickedKey = "pluginsPicked"
    /// The installed ones. Read from UserDefaults (not an observed model), so the phone server can
    /// ask off the main thread; views that list plugins watch the key with @AppStorage.
    static var all: [TakesPlugin] { available.filter { !removed.contains($0.id) } }
    static let removedKey = "pluginsRemoved"
    /// Plugins start installed: a removal is what is saved.
    static var removed: Set<String> {
        _ = seededOff
        return Set((UserDefaults.standard.string(forKey: removedKey) ?? "").split(separator: ",").map(String.init))
    }
    /// The plugins that start off and were marked off once (so a later switch-on sticks).
    static let seenOffKey = "pluginsSeenOff"
    /// Once per launch: a startsOff plugin this Mac has not seen yet goes on the removed list.
    private static let seededOff: Void = {
        let d = UserDefaults.standard
        let seen = Set((d.string(forKey: seenOffKey) ?? "").split(separator: ",").map(String.init))
        let new = built.filter { $0.startsOff && !seen.contains($0.id) }.map(\.id)
        guard !new.isEmpty else { return }
        var r = Set((d.string(forKey: removedKey) ?? "").split(separator: ",").map(String.init))
        r.formUnion(new)
        d.set(r.sorted().joined(separator: ","), forKey: removedKey)
        d.set(seen.union(new).sorted().joined(separator: ","), forKey: seenOffKey)
    }()
    static func isInstalled(_ id: String) -> Bool { !removed.contains(id) }
    static func setInstalled(_ id: String, _ on: Bool) {
        var r = removed
        if on { r.remove(id) } else { r.insert(id) }
        UserDefaults.standard.set(r.sorted().joined(separator: ","), forKey: removedKey)
    }
    /// The plugins with a board of their own.
    static var boards: [TakesPlugin] { all.filter { $0.board != nil } }
    /// The installed plugins that draw in slots and board sections: `all`, and in Public view also a
    /// hidden one that draws what users see (`drawsInPublicView`).
    static var drawing: [TakesPlugin] {
        PublicView.on ? built.filter { !removed.contains($0.id) && (!adminOnly($0) || $0.drawsInPublicView) } : all
    }
    static func named(_ id: String) -> TakesPlugin? { all.first { $0.id == id } }
    /// An installed plugin whose board chat the phone may open.
    static func chatPlugin(_ id: String) -> TakesPlugin? { named(id).flatMap { $0.chatContext == nil ? nil : $0 } }
    /// The same, hidden ones too: a board chat's context while Public view hides its board (2026-10-22).
    /// Site stats and Ideas send to their chats in the background.
    static func builtChatPlugin(_ id: String) -> TakesPlugin? {
        built.first { $0.id == id && !removed.contains($0.id) && $0.chatContext != nil }
    }
    static var postSides: [PostSide] { all.flatMap(\.postSides) }
    /// The plugin that posts for you, if one is on.
    static var autopost: AutopostHook? { all.lazy.compactMap(\.autopost).first }
    /// The same while Public view hides it: its watcher still runs (`start` goes by `built`).
    static var builtAutopost: AutopostHook? { built.lazy.filter { isInstalled($0.id) }.compactMap(\.autopost).first }
    static var vertical: (@MainActor (URL, URL?, String, AppModel) -> AnyView)? { all.lazy.compactMap(\.vertical).first }
    static var planReady: (@MainActor (PlanReadyContext) -> AnyView)? { all.lazy.compactMap(\.planReady).first }
    /// What the plugins put in a named place, or nil for nothing (no spacing either).
    @MainActor static func slot(_ name: String, open: @escaping (URL) -> Void = { _ in }) -> AnyView? {
        let views = drawing.compactMap { $0.slot?(name, open) }
        return views.isEmpty ? nil : AnyView(VStack(alignment: .leading, spacing: 12) { ForEach(views.indices, id: \.self) { views[$0] } })
    }
    /// What the plugins tell every chat.
    @MainActor static var agentNotes: [String] { all.compactMap { $0.agentNote?() } }
    @MainActor static func sections(_ board: String, available: [String], snapshots: BoardSnapshotSource,
                                    open: @escaping (URL) -> Void = { _ in }, native: @escaping (String) -> AnyView) -> AnyView? {
        drawing.compactMap(\.sections).first.flatMap { $0(board, available, snapshots, open, native) }
    }
    static var recordHooks: [RecordHook] { all.compactMap(\.record) }
    static var phoneHooks: [PhoneHook] { all.compactMap(\.phone) + all.compactMap(\.autopost?.phone) }
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
    /// The help as the plugin's page says it: without the "(⇧⌘R)" at its end, since the line under it
    /// names the shortcut ("Its own board in the sidebar, ⇧⌘R"). Tooltips keep it.
    nonisolated static func pageHelp(_ help: String) -> String {
        guard help.hasSuffix(")"), let open = help.range(of: " (⇧⌘", options: .backwards),
              help.distance(from: open.upperBound, to: help.endIndex) <= 2 else { return help }
        return String(help[..<open.lowerBound])
    }

    static func adminOnly(_ p: TakesPlugin) -> Bool { PrivatePlugins.list.contains { $0.id == p.id } }
    /// Admin-only things the screen shows (2026-10-22): The user's build, not in Public view. `own`
    /// stays the check for his data and paths, which Public view does not change.
    static var showsAdmin: Bool { own && !PublicView.on }
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
                if Plugins.showsAdmin {
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

    private func isOn(_ p: TakesPlugin) -> Bool { _ = removed; return Plugins.isInstalled(p.id) }

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
                        if Plugins.showsAdmin { scope(p).padding(.bottom, 2) }
                        Text(p.board != nil ? Plugins.pageHelp(p.help) : p.help).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: Binding(get: { on }, set: { v in withAnimation(Theme.motion) { Plugins.setInstalled(p.id, v) }; p.toggled?(app, v) }))
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
