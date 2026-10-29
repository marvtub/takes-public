import AppKit
import SwiftUI

// The frame of the app (redesign 2026-09-30): one sidebar (project switcher, sessions, boards) and
// one header per session (title, four modes, Schedule, ⋯). Everything else lives inside a mode.

/// The five things you do with a session. Stored in "rightTab" (old values: "script" is Record).
enum SessionMode: String, CaseIterable, Identifiable {
    case storyboard, write, record = "script", assets, sounds, broll, post
    var id: String { rawValue }

    var title: String {
        switch self {
        case .storyboard: return "Storyboard"
        case .write: return "Script"
        case .record: return "Record"
        case .assets: return "Assets"
        case .sounds: return "Sound"
        case .broll: return "B-roll"
        case .post: return "Post"
        }
    }

    var help: String {
        switch self {
        case .storyboard: return "The idea as sketches on a timeline, with the script under each shot (⌘5)"
        case .write: return "The script, with Takes beside it to write it (⌘7)"
        case .record: return "Camera, prompter and takes (⌘1)"
        case .assets: return "This video's files, your b-roll library, and its sound (⌘2; ⌘6 for b-roll, ⌘3 for sound)"
        case .sounds: return "Music and sound effects under the video (⌘3)"
        case .broll: return "Your own b-roll clips, by folder; add one to this session (⌘6)"
        case .post: return "The post for this video, as it looks in the feed (⌘4)"
        }
    }

    /// ⌘1–⌘4 stay where they were before the Storyboard tab came first (2026-10-03).
    var shortcut: Character {
        switch self {
        case .record: return "1"
        case .assets: return "2"
        case .sounds: return "3"
        case .post: return "4"
        case .storyboard: return "5"
        case .broll: return "6"
        case .write: return "7"
        }
    }

    /// The tabs in the header. B-roll (2026-10-03) and Sound (2026-10-04) live inside Assets,
    /// switched at its top.
    static let tabs: [SessionMode] = [.storyboard, .write, .record, .assets, .post]

    /// The header tab a mode shows under.
    var tab: SessionMode { self == .broll || self == .sounds ? .assets : self }

    @MainActor static func set(_ m: SessionMode) {
        Perf.mark("tab \(m.rawValue)")
        UserDefaults.standard.set(m.rawValue, forKey: "rightTab")
    }
}

// A plain key, not @Entry: build.sh builds with the Command Line Tools, which have no
// SwiftUI macro plugin (2026-10-02).
private struct PaneShownKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while a tab stays mounted under another one: it must not play or take keys.
    var paneShown: Bool {
        get { self[PaneShownKey.self] }
        set { self[PaneShownKey.self] = newValue }
    }
}

/// The tab and the open file each session showed last, by session folder ("sessionViews").
enum SessionView {
    static let key = "sessionViews"

    static func read(_ session: URL, defaults: UserDefaults = .standard) -> (mode: SessionMode, file: URL?, time: Double?) {
        let all = defaults.dictionary(forKey: key) ?? [:]
        // A session never shown here opens where its session.json says ("opens": {"tab", "file"}),
        // so the demo session starts on its finished edit, not on a dark camera (2026-10-08).
        guard let v = all[session.standardizedFileURL.path] as? [String: Any] ?? opens(session)
        else { return (.record, nil, nil) }
        let mode = SessionMode(rawValue: v["tab"] as? String ?? "") ?? .record
        let file = (v["file"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : session.appending(path: $0) }
        return (mode, file, v["time"] as? Double)
    }

    static func opens(_ session: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: session.appending(path: "session.json")),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return doc["opens"] as? [String: Any]
    }

    /// `defaults`: tests pass their own, since other tests write the shared one at the same time.
    static func write(_ session: URL, mode: SessionMode, file: URL?, time: Double?, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        var v: [String: Any] = ["tab": mode.rawValue]
        if let file {
            // Inside the session: kept relative, so it still works when the folder moves.
            let base = session.standardizedFileURL.path + "/", p = file.standardizedFileURL.path
            v["file"] = p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
        }
        if let time { v["time"] = time }
        let here = session.standardizedFileURL.path
        all[here] = v
        // Past 200 sessions, drop one whose folder is gone, never the one just written.
        if all.count > 200, let old = all.keys.first(where: { $0 != here && !FileManager.default.fileExists(atPath: $0) }) { all[old] = nil }
        defaults.set(all, forKey: key)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) var app
    var library: Library
    @State private var find = ""
    @State private var searching = false
    @FocusState private var finding: Bool

    var body: some View {
        let _ = Perf.body("Sidebar")
        // One grid (2026-10-03): every part sits 10 pt in from the sidebar's edges, and its own
        // content 10 pt further, so icons, chevrons, dots and buttons share one left and right line.
        VStack(spacing: 0) {
            BrandHeader(library: library, searching: $searching)
                .padding(.leading, 14).padding(.trailing, 6).padding(.bottom, 6)
            if searching || !find.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    TextField("Find a session", text: $find)
                        .textFieldStyle(.plain)
                        .focused($finding)
                        .onExitCommand { find = ""; finding = false }
                    if !find.isEmpty {
                        Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).transition(.opacity)
                    }
                }
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(finding ? Theme.muted.opacity(0.35) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { finding = true }
                .animation(Theme.motion, value: find.isEmpty)
                .animation(Theme.motion, value: finding)
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
            .onAppear { finding = true }
            .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // New session as a row, as New chat in Codex.
            SideRow(selected: false) {
                NavLabel(icon: "square.and.pencil", title: "New session", key: "⌘N")
            }
            .onTapGesture { if !library.isRecording { library.createSession() } }
            .help("New session (⌘N)")
            .padding(.horizontal, 6).padding(.bottom, 8)
            SessionList(library: library, queue: app.posts, filter: find)
            FirstVideoGuide()
                .animation(Theme.spring, value: FirstTake.shared.guide)
            BoardRows()
                .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 8)
        }
        .animation(Theme.motion, value: searching)
        .onExitCommand { searching = false; find = "" }
    }
}

/// Icon, title, and the shortcut on hover. Used by the rows at the foot of the sidebar.
struct NavLabel<Trailing: View>: View {
    let icon: String
    let title: String
    let key: String?
    /// Its board is open: ink title, accent icon.
    var active = false
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    init(icon: String, title: String, key: String?, active: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.title = title; self.key = key; self.active = active; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(active ? Theme.accent : Theme.muted).frame(width: 16)
            Text(title).font(Theme.sans(13, .medium)).foregroundStyle(hover || active ? Theme.ink : Theme.muted)
            Spacer(minLength: 4)
            trailing
            if let key {
                Text(key).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).opacity(hover ? 1 : 0)
            }
        }
        .onHover { h in withAnimation(Theme.motion) { hover = h } }
    }
}

/// Top of the sidebar (2026-10-02): the brand and a new session. Projects are sections below.
/// Update sits at the bottom, above Performance (2026-10-03): up here it had no room for its name.
struct BrandHeader: View {
    var library: Library
    /// The find field shows under the brand only while you search (2026-10-11).
    @Binding var searching: Bool

    var body: some View {
        let _ = Perf.body("BrandHeader")
        HStack(spacing: 4) {
            BrandMenu(library: library).padding(.leading, -6)  // the name stays on the list's edge
            Button { searching.toggle() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 13))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IconButtonStyle())
            .help("Find a session")
        }
        .frame(height: 36)
    }
}

/// The logo and name, as a menu (2026-10-04): Settings, the look, and the library folder.
/// A Takes menu since 2026-10-11: the look is a mode switch and theme dots in the menu itself.
struct BrandMenu: View {
    var library: Library
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false

    var body: some View {
        let openSettings = openSettings, openWindow = openWindow, app = app, library = library
        TakesMenuButton(width: 264, help: "Settings, appearance and the library") {
            HStack(spacing: 8) {
                // The logo is back beside the name (2026-10-11).
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 22, height: 22)
                Text("Takes").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.ink)
                // Beside the name, as in Codex (2026-10-11).
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .opacity(hover ? 1 : 0.6)
                Spacer(minLength: 0)
            }
            // The whole row up to the new-session button: an easy target (2026-10-04).
            .padding(.leading, 6).padding(.trailing, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        } content: {
            MenuButton("Settings…", icon: "gearshape", detail: "⌘ ,") { openSettings() }
            MenuDivider()
            MenuLabel("Appearance")
            MenuView("look") { LookPicker() }
            MenuDivider()
            MenuButton("Reveal library in Finder", icon: "folder") { library.reveal(library.root) }
            MenuButton("Change library folder…", icon: "folder.badge.gearshape") { app.chooseLibraryFolder() }
            MenuView("path") {
                Text((library.root.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 33).padding(.trailing, 8).padding(.bottom, 4)
            }
            MenuDivider()
            MenuButton("About Takes", icon: "info.circle") { openWindow(id: "about") }
        }
        .frame(maxWidth: .infinity)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
    }
}

/// Light, dark or the system's mode, and the theme as dots: the look, right in the logo menu.
struct LookPicker: View {
    private var look: Look { Look.shared }
    @State private var hovered: ThemePalette?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TakesSwitch(selection: Binding(get: { look.mode }, set: { look.mode = $0 }), title: \.name, fill: true)
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
            HStack(spacing: 8) {
                ForEach(ThemePalette.allCases) { p in
                    let on = look.palette == p
                    Button { withAnimation(Theme.motion) { look.palette = p } } label: {
                        Circle().fill(Color(nsColor: ThemeColors.ns(p.spec.accent)))
                            .frame(width: 14, height: 14)
                            .padding(3)
                            .overlay(Circle().strokeBorder(on ? Theme.ink : hovered == p ? Theme.border : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
                    .help(p.name)
                    .accessibilityLabel(p.name)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Text((hovered ?? look.palette).name).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 6)
        }
    }
}

/// A square icon button: second strength, a well on hover, a small press.
struct IconButtonStyle: ButtonStyle {
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? Theme.ink : Theme.muted)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.hover : .clear))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
            .animation(Theme.motion, value: configuration.isPressed)
    }
}

/// Draft (a grey ring), ready (orange), scheduled (an orange ring), published (green).
struct SessionDot: View {
    enum Kind { case draft, ready, scheduled, live }
    let kind: Kind
    var body: some View {
        Group {
            switch kind {
            case .draft: Circle().strokeBorder(Theme.faint, lineWidth: 1.5)
            case .ready: Circle().fill(Theme.accent)
            case .scheduled: Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
            case .live: Circle().fill(Theme.live)
            }
        }
        .frame(width: 6, height: 6)
    }
}

// MARK: - Header

/// Title, meta, the four modes, Schedule and ⋯. One row for the whole session.
struct SessionHeader: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @AppStorage("rightTab") private var tab = SessionMode.record.rawValue
    @AppStorage("postPlatform") private var platformRaw = PostPlatform.linkedin.rawValue
    @State private var title = ""
    @State private var titleHover = false
    @FocusState private var editingTitle: Bool
    @Environment(\.titleInset) private var inset

    var body: some View {
        let _ = Perf.body("SessionHeader")
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Untitled", text: $title)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.ink)
                        .focused($editingTitle)
                        .onSubmit { commitTitle() }
                        .disabled(app.isRecording)
                        .overlay(alignment: .bottomLeading) {
                            Rectangle().fill(Theme.border).frame(height: 1)
                                .opacity(titleHover && !app.isRecording ? 1 : 0)
                        }
                        .onHover { h in withAnimation(Theme.motion) { titleHover = h } }
                        .help("Click to rename")
                        .fixedSize()
                    if app.naming { ProgressView().controlSize(.mini) }
                }
                meta.layoutPriority(-1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            ModeSwitcher(tab: $tab)
            HStack(spacing: 6) {
                HeaderSchedule(doc: doc, platform: PostPlatform(rawValue: platformRaw) ?? .linkedin)
                    .id("\(doc.url.path)#\(platformRaw)")
                MoreMenu(doc: doc)
            }
        }
        // The top row (Rail.swift): the title starts where the panel under it starts.
        .padding(.leading, 20 + inset).padding(.trailing, 12)
        .frame(height: Chrome.bar)
        // The notice sits on the middle of the window, not of the space left in this row (2026-10-04).
        // The header runs to the window's right edge, so the window's middle is (width - minX) / 2 here.
        .overlay {
            GeometryReader { g in
                let minX = g.frame(in: .global).minX
                HeaderNotice(session: doc.url)
                    .fixedSize()
                    .position(x: max(260, (g.size.width - minX) / 2), y: g.size.height / 2)
            }
        }
        .gesture(WindowDragGesture())
        .onAppear { title = doc.meta.title }
        .onChange(of: doc.meta.title) { _, t in title = t }
    }

    /// ⌘Z after a rename undoes the rename (and ⇧⌘Z redoes it), not the typing in a field that
    /// the rename has already replaced.
    private func commitTitle() {
        let old = doc.meta.title
        FieldUndo.drop()
        editingTitle = false
        app.rename(doc, to: title)
        if doc.meta.title != old { app.undoableRename(doc, back: old) }
    }

    private var meta: some View {
        HStack(spacing: 7) {
            Text(doc.projectName)
            dot
            let n = doc.takeGroups.count
            Text("\(n) take\(n == 1 ? "" : "s")")
            dot
            Text(SessionList.when(doc.meta.createdAt))
            if doc.isPublished {
                dot
                PublishMenu(doc: doc)
            }
        }
        .font(Theme.sans(12.5))
        .foregroundStyle(Theme.faint)
        .lineLimit(1)
    }

    private var dot: some View { Text("·").foregroundStyle(Theme.faint) }
}

/// Storyboard · Record · Assets · Post, with a paper tab that springs to the one you pick.
struct ModeSwitcher: View {
    @Environment(AppModel.self) var app
    @Binding var tab: String
    @Namespace private var ns

    var body: some View {
        let _ = Perf.body("ModeSwitcher")
        let current = app.isRecording ? SessionMode.record : SessionMode(rawValue: tab)?.tab
        HStack(spacing: 0) {
            ForEach(SessionMode.tabs) { m in
                let on = current == m
                // No withAnimation: it animated every view the new tab builds. Only the tab springs.
                Button { Perf.mark("tab \(m.rawValue)"); tab = m.rawValue } label: {
                    Text(m.title)
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.paper)
                                    .shadow(color: Theme.shadow, radius: 3, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.isRecording && m != .record)
                .help(m.help)
            }
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 9))
        .animation(Theme.spring, value: current)
        .fixedSize()
    }
}

/// Assets holds three pages: this video's files, the b-roll library, and its sound. The switch at their top.
struct AssetsSwitch: View {
    static let pages: Set<String> = [SessionMode.assets.rawValue, SessionMode.broll.rawValue, SessionMode.sounds.rawValue]
    @AppStorage("rightTab") private var tab = SessionMode.record.rawValue
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            item("This video", .assets)
            item("B-roll", .broll)
            item("Sound", .sounds)
        }
        .padding(2)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .animation(Theme.spring, value: tab)
    }

    private func item(_ title: String, _ m: SessionMode) -> some View {
        let on = tab == m.rawValue
        return Button { SessionMode.set(m) } label: {
            Text(title).font(Theme.sans(12, .medium))
                .foregroundStyle(on ? Theme.ink : Theme.muted)
                .padding(.horizontal, 10).frame(height: 24)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.paper)
                            .shadow(color: Theme.shadow, radius: 2, y: 1)
                            .matchedGeometryEffect(id: "page", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The primary action: Schedule the post, or the time it goes out. Hidden while there is no post.
struct HeaderSchedule: View {
    var doc: SessionDoc
    let platform: PostPlatform
    @StateObject private var post: PostStore

    init(doc: SessionDoc, platform: PostPlatform) {
        self.doc = doc
        self.platform = platform
        _post = StateObject(wrappedValue: PostStore(platform))
    }

    var body: some View {
        let _ = Perf.body("HeaderSchedule")
        // A ZStack with a clear base: an empty Group has no view, so onAppear never fired.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let c = post.content { StatusControl(content: c, post: post) }
        }
        .onAppear { post.load(doc.url) }
        .onFilesChanged(in: doc.url) { post.load(doc.url) }
        .animation(Theme.spring, value: post.content?.status)
    }
}

/// Everything else about the session, in one place. Our own popover, not the system menu
/// (2026-10-06). A Takes menu since 2026-10-11: the rows come from `SessionMenu`, the same rows
/// the sidebar's right-click shows.
struct MoreMenu: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @State private var open = false

    var body: some View {
        let _ = Perf.body("MoreMenu")
        let app = app, doc = doc
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 30)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(app.isRecording)
        .help("More")
        .takesMenu(isPresented: $open, width: 260) { SessionMenu.rows(app: app, urls: [doc.url]) }
    }
}

/// The rows of a session's menu (2026-10-11): the ⋯ button and the sidebar's right-click build
/// them here, so both show the same rows in the same order. One session gets its links, naming,
/// the path and Clean up; several get the rows that act on all of them.
enum SessionMenu {
    @MainActor @MenuBuilder
    static func rows(app: AppModel, urls: Set<URL>) -> [MenuItem] {
        let library = app.library
        let one = urls.count == 1 ? urls.first : nil
        // The open session's doc, so a rename or a check shows at once; another one from disk.
        let doc = one.map { u in library.current?.url == u ? library.current! : SessionDoc(url: u) }
        let others = library.projects.filter { $0.url != library.selectedProject }
        let picked = library.sessions.filter { urls.contains($0.url) }
        let archived = !picked.isEmpty && picked.allSatisfy(\.archived)
        if let doc {
            let links = doc.posts.compactMap { p in p.url.flatMap(URL.init(string:)).map { (p.label, $0) } }
            for (label, url) in links {
                MenuButton("Open on \(label)", icon: "arrow.up.right.square") { NSWorkspace.shared.openSoon(url) }
            }
            if !links.isEmpty { MenuDivider() }
            // Naming works on the open session only (AppModel.aiName).
            MenuButton("Name from script", icon: "sparkles",
                       enabled: library.current === doc && !app.naming && !doc.script.isEmpty) {
                Task { await app.aiName(doc) }
            }
            MenuButton("Copy folder path", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.url.path, forType: .string)
                app.show(toast: "Path copied. Paste it to Takes.")
            }
            if doc.isPublished && library.current === doc {
                MenuButton("Clean up…", icon: "checklist") { app.cleaningUp = true }
            }
            MenuDivider()
        }
        if !others.isEmpty {
            MenuGroup("Move to project", icon: "folder") {
                for p in others {
                    MenuButton(p.name) { library.moveSessions(urls, to: p.url) }
                }
            }
        }
        MenuGroup(urls.count == 1 ? "Mark as published on" : "Mark \(urls.count) as published on", icon: "paperplane") {
            if let doc {
                // A platform switches on and off in place, like the Published control.
                let choices: [String?] = Platforms.all.map { $0 } + [nil]
                for p in choices {
                    let on = doc.posts.contains { $0.platform?.lowercased() == p?.lowercased() }
                    MenuButton(p ?? "Somewhere else", checked: on, keepsOpen: true) {
                        doc.setPublished(p, !on)
                        library.loadSessions()
                    }
                }
            } else {
                for p in Platforms.all {
                    MenuButton(p) { library.markPublished(urls, on: p) }
                }
                MenuButton("Somewhere else") { library.markPublished(urls) }
            }
        }
        MenuButton("Trash takes without a star", icon: "star.slash") { library.trashNonKeepers(urls) }
        MenuButton(archived ? "Unarchive" : "Archive", icon: "archivebox") { library.setArchived(urls, !archived) }
        MenuButton("Reveal in Finder", icon: "folder.badge.gearshape") { library.reveal(urls) }
        MenuDivider()
        MenuButton(urls.count == 1 ? "Move session to Trash" : "Move \(urls.count) sessions to Trash",
                   icon: "trash", danger: true) {
            library.trashSessions(urls)
        }
    }
}

/// A text field's typing undo lives in its field editor and points at the field. When a rename
/// redraws the view, the field is gone but the undo steps stay; ⌘Z then called into freed memory
/// and Takes crashed (2026-10-01). Drop them when an edit is committed.
enum FieldUndo {
    @MainActor static func drop() {
        guard let w = NSApp.keyWindow else { return }
        if let tv = w.firstResponder as? NSTextView, tv.isFieldEditor { tv.undoManager?.removeAllActions() }
        (w.fieldEditor(false, for: nil) as? NSTextView)?.undoManager?.removeAllActions()
    }
}
