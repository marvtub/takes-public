import AppKit
import SwiftUI

// The frame of the app (redesign 2026-09-30): one sidebar (project switcher, sessions, boards) and
// one header per session (title, four modes, Schedule, ⋯). Everything else lives inside a mode.

/// The five things you do with a session. Stored in "rightTab" (old values: "script" is Record).
enum SessionMode: String, CaseIterable, Identifiable {
    case storyboard, record = "script", assets, sounds, broll, post
    var id: String { rawValue }

    var title: String {
        switch self {
        case .storyboard: return "Storyboard"
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
        case .record: return "Camera, script and takes (⌘1)"
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
        }
    }

    /// The tabs in the header. B-roll (2026-10-03) and Sound (2026-10-04) live inside Assets,
    /// switched at its top.
    static let tabs: [SessionMode] = [.storyboard, .record, .assets, .post]

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

    static func read(_ session: URL) -> (mode: SessionMode, file: URL?, time: Double?) {
        let all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        guard let v = all[session.standardizedFileURL.path] as? [String: Any] else { return (.record, nil, nil) }
        let mode = SessionMode(rawValue: v["tab"] as? String ?? "") ?? .record
        let file = (v["file"] as? String).map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : session.appending(path: $0) }
        return (mode, file, v["time"] as? Double)
    }

    static func write(_ session: URL, mode: SessionMode, file: URL?, time: Double?) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var v: [String: Any] = ["tab": mode.rawValue]
        if let file {
            // Inside the session: kept relative, so it still works when the folder moves.
            let base = session.standardizedFileURL.path + "/", p = file.standardizedFileURL.path
            v["file"] = p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
        }
        if let time { v["time"] = time }
        all[session.standardizedFileURL.path] = v
        // Past 200 sessions, drop one whose folder is gone.
        if all.count > 200, let old = all.keys.first(where: { !FileManager.default.fileExists(atPath: $0) }) { all[old] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) var app
    var library: Library
    @State private var find = ""
    @FocusState private var finding: Bool

    var body: some View {
        let _ = Perf.body("Sidebar")
        // One grid (2026-10-03): every part sits 10 pt in from the sidebar's edges, and its own
        // content 10 pt further, so icons, chevrons, dots and buttons share one left and right line.
        VStack(spacing: 0) {
            Color.clear.frame(height: 10)
            BrandHeader(library: library)
                .padding(.leading, 20).padding(.trailing, 10).padding(.bottom, 10)
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
            .padding(.horizontal, 10).padding(.bottom, 10)
            SessionList(library: library, queue: app.posts, filter: find)
            Rule()
            VStack(spacing: 1) {
                BoardRows()
                SideRow(selected: app.board == .styles) {
                    NavLabel(icon: "square.stack", title: "Styles", key: "⇧⌘Y", active: app.board == .styles)
                }
                .onTapGesture { app.board = .styles }
                .help("Your styles side by side, the one this video uses, and the parts Takes kept")
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
        }
        .background(Theme.surface)
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

    var body: some View {
        let _ = Perf.body("BrandHeader")
        HStack(spacing: 8) {
            BrandMenu(library: library).padding(.leading, -6)  // the logo stays on the list's edge
            // New project moved to the foot of the list (2026-10-03); a session is the common case.
            Button { library.createSession() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 12.5, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IconButtonStyle())
            .help("New session (⌘N)")
            .disabled(library.isRecording)
        }
        .frame(height: 34)
    }
}

/// The logo and name, as a menu (2026-10-04): Settings, the look, and the library folder.
struct BrandMenu: View {
    var library: Library
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var hover = false
    private var look: Look { Look.shared }

    var body: some View {
        Menu {
            Button("Settings…") { openSettings() }.keyboardShortcut(",")
            Menu("Appearance") {
                Picker("Mode", selection: Binding(get: { look.mode }, set: { look.mode = $0 })) {
                    ForEach(Look.Mode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Theme", selection: Binding(get: { look.palette }, set: { look.palette = $0 })) {
                    ForEach(ThemePalette.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Reveal Library in Finder") { library.reveal(library.root) }
            Button("Change Library Folder…") { app.chooseLibraryFolder() }
            Divider()
            AboutButton()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 27, height: 27)
                Text("Takes").font(Theme.display(19)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                // At the row's end, so the row reads as one control (2026-10-04).
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .opacity(hover ? 1 : 0.6)
            }
            // The whole row up to the new-session button: an easy target (2026-10-04).
            .padding(.leading, 6).padding(.trailing, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help("Settings, appearance and the library")
    }
}

/// A row in a popover menu: soft well on hover.
struct MenuRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? Theme.hover : .clear))
            .onHover { hover = $0 }
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

    var body: some View {
        let _ = Perf.body("SessionHeader")
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    TextField("Untitled", text: $title)
                        .textFieldStyle(.plain)
                        .font(Theme.display(30))
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
                        // Never shorter than its line: once (2026-10-04) the field got half its
                        // height and showed only the top of the title.
                        .frame(minHeight: Self.titleHeight)
                    if app.naming { ProgressView().controlSize(.small) }
                }
                meta
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            ModeSwitcher(tab: $tab)
            HStack(spacing: 6) {
                HeaderSchedule(doc: doc, platform: PostPlatform(rawValue: platformRaw) ?? .linkedin)
                    .id("\(doc.url.path)#\(platformRaw)")
                MoreMenu(doc: doc)
            }
        }
        .padding(.leading, 28).padding(.trailing, 20).padding(.top, 16).padding(.bottom, 14)
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
        .background(Theme.paper)
        .gesture(WindowDragGesture())
        .onAppear { title = doc.meta.title }
        .onChange(of: doc.meta.title) { _, t in title = t }
    }

    /// The title font's line height.
    private static var titleHeight: CGFloat {
        let size = 30 * 0.8 * TextSize.shared.factor
        let f = NSFont(name: "Nunito-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
        return ceil(f.ascender - f.descender + f.leading)
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
            Text(doc.projectName).font(Theme.sans(12, .medium)).foregroundStyle(Theme.muted)
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
        .font(Theme.sans(12))
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
                        .padding(.horizontal, 14).frame(height: 26)
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
        .padding(3)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
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

/// Everything else about the session, in one place.
struct MoreMenu: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc

    var body: some View {
        let _ = Perf.body("MoreMenu")
        Menu {
            Button("Name From Script") { Task { await app.aiName(doc) } }
                .disabled(app.naming || doc.script.isEmpty)
            Button("Copy Folder Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.url.path, forType: .string)
                app.show(toast: "Path copied. Paste it to Takes.")
            }
            if doc.isPublished { Button("Clean Up…") { app.cleaningUp = true } }
            Divider()
            BulkMenu(library: app.library, urls: [doc.url])
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(IconButtonStyle())
        .disabled(app.isRecording)
        .help("More")
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
