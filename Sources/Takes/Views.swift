import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TakesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    init() { Theme.registerFonts() }

    var body: some Scene {
        Window("Takes", id: "main") {
            ContentView(library: app.library)
                .environment(app)
                .tint(Theme.accent)
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 960, minHeight: 580)
                .overlay(alignment: .top) { PhonePairBanner().environment(app) }
                .overlay { ScreenFindLayer().ignoresSafeArea() }
                .overlay { OnboardingLayer().environment(app) }
                .task { Onboarding.shared.startIfNew(app.library) }
                .onOpenURL { app.handle(url: $0) }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutButton()
                if Releaser.available {
                    Button(Releaser.shared.menuTitle) { Releaser.shared.confirmAndRun { app.show(toast: $0) } }
                        .disabled(Releaser.shared.running)
                }
            }
            CommandGroup(after: .windowArrangement) {
                if Features.socialBoards {
                    Button("Performance") { app.toggle(.performance) }.keyboardShortcut("j", modifiers: [.command, .shift])
                    Button("Comments") { app.toggle(.comments) }.keyboardShortcut("m", modifiers: [.command, .shift])
                }
                ForEach(Plugins.all) { p in
                    Button(p.title) { app.toggle(.plugin(p.id)) }.keyboardShortcut(KeyEquivalent(p.key), modifiers: [.command, .shift])
                }
                Button("Styles") { app.toggle(.styles) }.keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Chat with Takes") { app.chats.open.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") { app.toggleSidebars() }.keyboardShortcut("b")
                Divider()
                ForEach(SessionMode.allCases) { m in
                    Button(m.title) { SessionMode.set(m) }
                        .keyboardShortcut(KeyEquivalent(m.shortcut), modifiers: .command)
                        .disabled(app.isRecording)
                }
                Divider()
                Button("Bigger Text") { TextSize.shared.bigger(); app.show(toast: "Text: \(TextSize.shared.name)") }
                    .keyboardShortcut("=")
                Button("Smaller Text") { TextSize.shared.smaller(); app.show(toast: "Text: \(TextSize.shared.name)") }
                    .keyboardShortcut("-")
                Button("Normal Text") { TextSize.shared.step = 0; app.show(toast: "Text: Normal") }
                    .keyboardShortcut("0")
                Divider()
            }
            CommandGroup(after: .help) {
                Button("Show Welcome Again") { Onboarding.shared.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") { app.library.createSession() }.keyboardShortcut("n")
                    .disabled(Onboarding.shared.shown)
            }
            CommandMenu("Record") {
                Button("Start / Stop Recording") { app.toggleRecord() }.keyboardShortcut("r")
                    .disabled(Onboarding.shared.shown)
                Button("Play / Pause Script") { app.scrolling.toggle() }.keyboardShortcut("p")
                Button("Script to Top") { app.resetToken += 1 }.keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Bigger Script") { app.fontSize = min(96, app.fontSize + 4) }.keyboardShortcut("=", modifiers: [.command, .option])
                Button("Smaller Script") { app.fontSize = max(14, app.fontSize - 4) }.keyboardShortcut("-", modifiers: [.command, .option])
                Divider()
                Button("Reveal Library in Finder") { app.library.reveal(app.library.root) }
                Button("Change Library Folder…") { app.chooseLibraryFolder() }
                Divider()
                Button("Forget Paired Phones") { app.phone?.forgetAll() }
            }
        }
        Window("About Takes", id: "about") {
            AboutView().environment(app).tint(Theme.accent).foregroundStyle(Theme.ink)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // ⌘,: archived sessions live here, out of the sidebar (2026-10-03).
        Settings {
            SettingsView(library: app.library)
                .environment(app)
                .tint(Theme.accent)
                .font(Theme.body)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        AgentSetup.run()
        Setup.shared.start()
        Look.shared.applyMode()
        _ = NSWindow.keepFullScreenOnEscape
        ScreenFind.shared.install()
        // Design check without screen-recording rights and without taking focus: post
        // "de.marvinaziz.takes.snapshot" (object = output path) and Takes draws its window into a PNG.
        DistributedNotificationCenter.default().addObserver(forName: .init("de.marvinaziz.takes.snapshot"),
                                                            object: nil, queue: .main) { n in
            guard let out = n.object as? String,
                  let frame = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}

extension NSWindow {
    /// Esc that no view takes ends at the window, and a full-screen window leaves full screen on it.
    /// Takes uses Esc to close drafts, fields and comment mode, so one press too many dropped the user
    /// out of full screen (2026-10-05). ⌃⌘F and the green button still leave it.
    static let keepFullScreenOnEscape: Void = {
        let sel = #selector(NSResponder.cancelOperation(_:)), ours = #selector(NSWindow.takesCancelOperation(_:))
        guard let original = class_getInstanceMethod(NSWindow.self, sel),
              let replacement = class_getInstanceMethod(NSWindow.self, ours) else { return }
        // NSWindow may only inherit cancelOperation: add ours to NSWindow so NSResponder stays untouched.
        if class_addMethod(NSWindow.self, sel, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(NSWindow.self, ours, method_getImplementation(original), method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, replacement)
        }
    }()

    @objc func takesCancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { return }
        takesCancelOperation(sender)  // swapped: this runs the original
    }
}

struct ContentView: View {
    @Environment(AppModel.self) var app
    var library: Library
    @AppStorage("sidebar") private var savedColumns = "all"
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260

    // Sidebar | the session or a board. Our own columns, not NavigationSplitView: its sidebar
    // floats as an inset card on macOS 26, and this one runs the full height of the window.
    private var showsSidebar: Bool { savedColumns != "detailOnly" }

    var body: some View {
        let _ = Perf.body("ContentView")
        // ⌘B: the content takes its new width at once and only the sidebar slides. Animating the
        // width made every board lay out again on each frame, which looked jumpy.
        ZStack(alignment: .leading) {
            content
                .padding(.leading, showsSidebar ? sidebarWidth + 1 : 0)
                // Never wider than the window: content that wanted more width made the whole
                // stack wider and centred it, so the left edge went under the sidebar and was cut
                // off (2026-10-03). Now anything too wide runs out on the right.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: savedColumns)
            if showsSidebar {
                HStack(spacing: 0) {
                    Sidebar(library: library)
                        .padding(.top, 28)  // clear of the traffic lights
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(Theme.canvas)
                    Rectangle().fill(Theme.border).frame(width: 1)
                        .overlay {
                            Color.clear.frame(width: 8).contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("shell"))
                                    .onChanged { v in sidebarWidth = min(max(v.location.x, 220), 360) })
                        }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: "shell")
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeOut(duration: 0.2), value: savedColumns)
        .onReceive(NotificationCenter.default.publisher(for: .takesToggleSidebar)) { _ in
            savedColumns = showsSidebar ? "detailOnly" : "all"
        }
        .onChange(of: library.selectedSessions) { _, sel in
            app.board = nil  // ⌘N, a link
        }
    }

    /// The session or a board.
    private var content: some View {
            ZStack {
                // Under a board and the session as they cross-fade: no see-through frame.
                Theme.canvas
                if app.board == .performance {
                    ChatSlot(hub: app.chats, target: ChatTarget(chat: app.chats.board, title: "Performance", session: nil)) {
                        PerformanceView(board: app.performance, root: library.root) { app.follow($0) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        BoardChatCorner(hub: app.chats).padding(18)
                    }
                    .transition(.opacity)
                } else if app.board == .styles {
                    ChatSlot(hub: app.chats, target: ChatTarget(chat: app.chats.styles, title: "Styles", session: nil)) {
                        StylesBoard(root: library.root)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        BoardChatCorner(hub: app.chats, styles: true).padding(18)
                    }
                    .transition(.opacity)
                } else if app.board == .comments {
                    CommentsBoard(hub: app.chats, store: app.copilot, root: library.root)
                        .transition(.opacity)
                } else if case .plugin(let id)? = app.board, let p = Plugins.named(id) {
                    p.board(app).transition(.opacity)
                } else {
                    DetailView(library: library, camera: app.camera, screen: app.screen)
                }
            }
            .animation(Theme.motion, value: app.board)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
    }
}

/// Two panes with a draggable divider whose position is remembered between launches.
struct PersistentSplit<Left: View, Right: View>: View {
    @AppStorage("splitRatio") private var ratio: Double = 0.5
    let minLeft: CGFloat
    let minRight: CGFloat
    let left: Left
    let right: Right

    init(minLeft: CGFloat, minRight: CGFloat, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.minLeft = minLeft
        self.minRight = minRight
        self.left = left()
        self.right = right()
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let lw = min(max(w * ratio, minLeft), max(minLeft, w - minRight))
            HStack(spacing: 0) {
                left.frame(width: lw)
                Rectangle().fill(Theme.border).frame(width: 1)
                    .overlay {
                        Color.clear.frame(width: 10).contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                                .onChanged { v in ratio = min(max(v.location.x / w, 0.15), 0.85) })
                    }
                right.frame(maxWidth: .infinity)
            }
        }
        .coordinateSpace(name: "split")
    }
}

// MARK: - Sidebar

/// The sidebar ways into the boards. It also keeps the post plan current for the session list.
struct BoardRows: View {
    @Environment(AppModel.self) var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SetupButton()
            UpdateButton(library: app.library)
            if Features.socialBoards {
                PerformanceRow(board: app.performance, selected: app.board == .performance) { app.board = .performance }
                CommentsRow(store: app.copilot, runner: app.copilot.runner, chat: app.chats.comments, post: app.chats.commentsPost, selected: app.board == .comments) { app.board = .comments }
            }
            ForEach(Plugins.all) { p in
                PluginRow(plugin: p, app: app, selected: app.board == .plugin(p.id)) { app.board = .plugin(p.id) }
            }
        }
            .onAppear { app.posts.scan(app.library.root) }
            .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
                if let paths = n.object as? [String], PostQueue.matters(paths) { app.posts.scanInBackground(app.library.root) }
            }
    }
}

// MARK: - Drag to reorder

extension View {
    /// Drag this row onto another to take its slot. The list moves live while you drag.
    func reorderable<ID: Hashable>(_ id: ID, dragging: Binding<ID?>,
                                   move: @escaping (ID, ID) -> Void) -> some View {
        self
            .onDrag {
                dragging.wrappedValue = id
                return NSItemProvider(object: String(describing: id) as NSString)
            }
            .onDrop(of: [.text], delegate: ReorderDrop(target: id, dragging: dragging, move: move))
    }
}

struct ReorderDrop<ID: Hashable>: DropDelegate {
    let target: ID
    @Binding var dragging: ID?
    let move: (ID, ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(Theme.motion) { move(d, target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) {}
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
}

/// A sidebar row: a soft well on hover, a paper card when selected.
struct SideRow<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        content
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.paper)
                        .shadow(color: Theme.shadow, radius: 6, y: 2)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 0.5))
                } else if hover {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
            .animation(Theme.motion, value: selected)
    }
}

struct SessionList: View {
    @Environment(AppModel.self) var app
    var library: Library
    @ObservedObject var queue: PostQueue
    var filter = ""
    @State private var anchor: URL?
    @State private var dragging: URL?
    @State private var draggingProject: URL?
    @State private var renaming: URL?
    @State private var newName = ""
    /// Renames typed while a chat works in the project: the folder moves once it is done.
    @State private var pendingNames: [URL: String] = [:]
    @FocusState private var focused: Bool
    @FocusState private var naming: Bool
    /// Folded projects, and projects with their published sessions open, by folder name.
    @AppStorage("foldedProjects") private var folded = ""
    @AppStorage("openPublished") private var openPublished = ""
    @State private var showNewProject = false
    @State private var newProject = ""

    var body: some View {
        let _ = Perf.body("SessionList")
        // Highlight the session only while it is on screen: a board covers it.
        let sel = app.board == nil ? library.selectedSessions : []
        let ready = Set(queue.posts.filter { $0.content.status != .draft }.map(\.session.standardizedFileURL))
        let booked = Dictionary(grouping: queue.posts.filter { $0.content.status == .scheduled },
                                by: \.session.standardizedFileURL)
        let rows = visible
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(library.projects) { p in
                        let shown = matching(p.url)
                        if (filter.isEmpty && !Self.hidden(p, library.grouped[p.url] ?? [])) || !shown.isEmpty {
                            section(p, shown, sel, ready: ready, booked: booked)
                        }
                    }
                    if filter.isEmpty && !library.projects.isEmpty {
                        Button { newProject = ""; showNewProject = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).frame(width: 8)
                                Text("New project")
                            }
                            .font(Theme.sans(12, .medium)).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 10).frame(height: 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)
                        .disabled(library.isRecording)
                    }
                    if !filter.isEmpty && rows.isEmpty {
                        Text("No session matches \u{201C}\(filter)\u{201D}.").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 10).padding(.top, 14)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
                .animation(Theme.motion, value: rows)
            }
            .onChange(of: anchor) { _, a in if let a { withAnimation(Theme.motion) { proxy.scrollTo(a) } } }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { renaming == nil ? move(-1) : .ignored }
        .onKeyPress(.downArrow) { renaming == nil ? move(1) : .ignored }
        .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers.contains(.command), renaming == nil else { return .ignored }
            library.selectedSessions = Set(library.sessions.map(\.url))
            return .handled
        }
        .disabled(app.isRecording)
        .alert("New project", isPresented: $showNewProject) {
            TextField("Name", text: $newProject)
            Button("Create") { library.createProject(newProject) }
            Button("Cancel", role: .cancel) {}
        }
        .overlay {
            if library.projects.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "video",
                                       description: Text("\u{2318}N for a new session, or just hit \u{2318}R."))
            }
        }
    }

    // MARK: Sections (2026-10-02): each project is a section, folded or open.

    private func names(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }
    private func isFolded(_ p: URL) -> Bool { filter.isEmpty && names(folded).contains(p.lastPathComponent) }
    private func publishedOpen(_ p: URL) -> Bool { !filter.isEmpty || names(openPublished).contains(p.lastPathComponent) }
    private func toggle(_ raw: inout String, _ name: String) {
        var set = names(raw)
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        raw = set.sorted().joined(separator: "\n")
    }

    /// A project with nothing left to show: all its sessions are archived, or it is an empty
    /// Inbox (2026-10-03). A new, empty project still shows, so you can fill it.
    static func hidden(_ p: Project, _ all: [SessionSummary]) -> Bool {
        let live = all.filter { !$0.archived }
        return live.isEmpty && (!all.isEmpty || p.name == "Inbox")
    }

    /// Archived sessions stay out of the sidebar; Settings lists them (2026-10-03).
    private func matching(_ p: URL) -> [SessionSummary] {
        let all = (library.grouped[p] ?? []).filter { !$0.archived }
        return filter.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    /// The sessions on screen, top to bottom: the arrow keys walk them.
    private var visible: [URL] {
        library.projects.flatMap { p -> [URL] in
            guard !isFolded(p.url) else { return [] }
            let open = publishedOpen(p.url)
            return matching(p.url).filter { !$0.done || open }.map(\.url)
        }
    }

    @ViewBuilder
    private func section(_ p: Project, _ shown: [SessionSummary], _ sel: Set<URL>,
                         ready: Set<URL>, booked: [URL: [QueuedPost]]) -> some View {
        let fold = isFolded(p.url)
        header(p, count: shown.count, folded: fold)
        if !fold {
            let live = shown.filter { !$0.done && booked[$0.url.standardizedFileURL] == nil }
            // Scheduled: the next post to go out first.
            let scheduled = shown.filter { !$0.done && booked[$0.url.standardizedFileURL] != nil }
                .sorted { Self.next(booked[$0.url.standardizedFileURL]) < Self.next(booked[$1.url.standardizedFileURL]) }
            let published = shown.filter(\.done)
            ForEach(live) { row($0, sel, ready: ready.contains($0.url.standardizedFileURL)) }
            ForEach(scheduled) { row($0, sel, ready: true, booked: booked[$0.url.standardizedFileURL] ?? []) }
            if !published.isEmpty {
                let open = publishedOpen(p.url)
                Button { withAnimation(Theme.motion) { toggle(&openPublished, p.name) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 8)
                        Text("Published")
                        Text("\(published.count)").monospacedDigit().foregroundStyle(Theme.faint.opacity(0.7))
                        Spacer()
                    }
                    .font(Theme.sans(12, .medium)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open { ForEach(published) { row($0, sel, ready: false) } }
            }
            if shown.isEmpty {
                Button { library.createSession(in: p.url) } label: {
                    Text("No sessions yet").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                        .padding(.leading, 26).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help("Click for a new session")
            }
        }
    }

    /// A project: click folds it, + adds a session, double-click renames it, drag moves it.
    private func header(_ p: Project, count: Int, folded fold: Bool) -> some View {
        let dir = p.url.standardizedFileURL
        let waiting = app.notices.contains { $0.session?.deletingLastPathComponent().standardizedFileURL == dir }
        // Renaming moves the folder under a working chat: wait until it is done.
        let busy = app.chats.all.contains { c in
            c.running && c.session?.deletingLastPathComponent().standardizedFileURL == dir
        }
        let blocked = busy || app.isRecording
        return ProjectHeader(name: pendingNames[p.url] ?? p.name, count: count, folded: fold, waiting: waiting,
                             renaming: renaming == p.url, newName: $newName, naming: $naming,
                             toggle: { withAnimation(Theme.motion) { toggle(&folded, p.name) } },
                             add: { library.createSession(in: p.url) },
                             commit: { finishRename(p) },
                             cancel: { renaming = nil })
            .padding(.top, p.url == library.projects.first?.url ? 4 : 18).padding(.bottom, 2)
            .reorderable(p.url, dragging: $draggingProject) { library.moveProject($0, to: $1) }
            .contextMenu {
                Button("New Session") { library.createSession(in: p.url) }
                // While a chat works here, the new name shows at once and the folder moves after.
                Button("Rename\u{2026}") { startRename(p) }
                Button("Reveal in Finder") { library.reveal(p.url) }
                Divider()
                Button("Move Project to Trash", role: .destructive) { library.trashProject(p.url) }
                    .disabled(busy || app.isRecording)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(p) })
            .onChange(of: blocked) { _, b in
                if !b, let name = pendingNames.removeValue(forKey: p.url) { applyRename(p, to: name) }
            }
    }

    private func startRename(_ p: Project) {
        newName = pendingNames[p.url] ?? p.name
        renaming = p.url
        DispatchQueue.main.async { naming = true }
    }

    private func finishRename(_ p: Project) {
        guard renaming == p.url else { return }
        renaming = nil
        let dir = p.url.standardizedFileURL
        let busy = app.chats.all.contains { c in
            c.running && c.session?.deletingLastPathComponent().standardizedFileURL == dir
        }
        if busy || app.isRecording {
            pendingNames[p.url] = newName
            app.show(toast: busy ? "Renames when the chat in this project is done" : "Renames when the take is done")
            return
        }
        pendingNames[p.url] = nil
        applyRename(p, to: newName)
    }

    private func applyRename(_ p: Project, to name: String) {
        guard let moved = library.renameProject(p.url, to: name), moved != p.url else { return }
        // The fold and published states follow the new name.
        var f = names(folded)
        if f.remove(p.name) != nil { f.insert(moved.lastPathComponent); folded = f.sorted().joined(separator: "\n") }
        var o = names(openPublished)
        if o.remove(p.name) != nil { o.insert(moved.lastPathComponent); openPublished = o.sorted().joined(separator: "\n") }
    }

    /// When the first of these posts goes out; no time sorts last.
    private static func next(_ posts: [QueuedPost]?) -> Date {
        posts?.compactMap(\.content.at).min() ?? .distantFuture
    }

    /// One line per session (2026-10-03): a status dot only when there is something to say, the
    /// title, and on the right Claude's activity, the post's platforms or the day. The rest is in
    /// the tooltip.
    private func row(_ s: SessionSummary, _ sel: Set<URL>, ready: Bool, booked: [QueuedPost] = []) -> some View {
        let picked = sel.contains(s.url)
        return SideRow(selected: picked) {
            HStack(spacing: 8) {
                Group {
                    if s.published { SessionDot(kind: .live) }
                    else if !booked.isEmpty { SessionDot(kind: .scheduled) }
                    else if ready { SessionDot(kind: .ready) }
                    else { Color.clear }
                }
                .frame(width: 8)
                Text(s.title).font(Theme.sans(13, picked ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(s.published && !picked ? Theme.muted : Theme.ink)
                Spacer(minLength: 6)
                ClaudeActivity(chat: app.chats.existing(s.url),
                               waiting: app.notices.contains { $0.session == s.url.standardizedFileURL })
                Group {
                    if !booked.isEmpty {
                        let at = Self.next(booked)
                        HStack(spacing: 4) {
                            ForEach(booked.map(\.platform.name), id: \.self) { PlatformLogo(platform: $0, size: 11) }
                            Text(at == .distantFuture ? "No time" : Self.short(at))
                        }
                    } else if s.published {
                        PlatformLogos(posts: s.posts, size: 11)
                    } else {
                        Text(Self.age(s.createdAt))
                    }
                }
                .font(Theme.sans(11)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1)
                .fixedSize()
            }
            .frame(height: 18)
        }
        .help(Self.tip(s, ready: ready, booked: booked))
        .id(s.url)
        .onTapGesture { click(s.url); focused = true }
        .reorderable(s.url, dragging: $dragging) { library.moveSession($0, to: $1) }
        .contextMenu {
            let links = s.posts.compactMap { p in p.url.flatMap(URL.init(string:)).map { (p.label, $0) } }
            ForEach(links, id: \.1) { label, url in
                Button("Open on \(label)") { NSWorkspace.shared.open(url) }
            }
            if !links.isEmpty { Divider() }
            BulkMenu(library: library, urls: sel.contains(s.url) ? sel : [s.url])
        }
    }

    /// Finder-style clicks: plain selects one, \u{2318} adds or removes, \u{21E7} selects a range.
    /// Several sessions are picked within one project; a click in another project opens that one.
    private func click(_ url: URL) {
        let mods = NSEvent.modifierFlags
        // A click on the session under a board brings it back.
        app.board = nil
        let same = library.project(of: url) == library.selectedProject
        if same, mods.contains(.command) {
            var sel = library.selectedSessions
            if sel.contains(url), sel.count > 1 { sel.remove(url) } else { sel.insert(url) }
            library.selectedSessions = sel
            anchor = url
        } else if same, mods.contains(.shift), let a = anchor,
                  let i = library.sessions.firstIndex(where: { $0.url == a }),
                  let j = library.sessions.firstIndex(where: { $0.url == url }) {
            library.selectedSessions = Set(library.sessions[min(i, j)...max(i, j)].map(\.url))
        } else {
            library.select(url)
            anchor = url
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let list = visible
        guard !list.isEmpty else { return .ignored }
        let current = anchor.flatMap { a in list.firstIndex(of: a) }
            ?? list.firstIndex { library.selectedSessions.contains($0) } ?? -step
        let next = list[min(max(current + step, 0), list.count - 1)]
        library.select(next)
        anchor = next
        return .handled
    }

    /// "Today 1:51 PM", "Yesterday 9:02 AM", "Sep 21 4:10 PM".
    /// "Today", "Yesterday", "Sep 21": the day only, for the sidebar.
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// How old a session is, in as few letters as fit: "3h", "2d", "Sep 27".
    static func age(_ d: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "9:00 AM" today, "Tue 9:00 AM" this week, else "Oct 9".
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: d).day, days > 0, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The row's tooltip: what no longer fits on its one line.
    static func tip(_ s: SessionSummary, ready: Bool, booked: [QueuedPost]) -> String {
        let state = s.published ? "Published" : !booked.isEmpty ? "Scheduled" : ready ? "Post ready" : "In progress"
        var parts = [s.title, "\(when(s.createdAt)) · \(s.takeCount) take\(s.takeCount == 1 ? "" : "s")", state]
        if let at = booked.compactMap(\.content.at).min() { parts.append("Goes out \(when(at))") }
        return parts.joined(separator: "\n")
    }

    static func when(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        if cal.isDateInTomorrow(d) { return "Tomorrow \(time)" }
        return "\(d.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
}

/// A project's line in the sidebar: a chevron that folds it, the name, the count, a + on hover.
private struct ProjectHeader: View {
    let name: String
    let count: Int
    let folded: Bool
    let waiting: Bool
    let renaming: Bool
    @Binding var newName: String
    var naming: FocusState<Bool>.Binding
    let toggle: () -> Void
    let add: () -> Void
    let commit: () -> Void
    let cancel: () -> Void
    @State private var hover = false

    var body: some View {
        // A quiet label over its sessions (2026-10-03): the chevron shows on hover or when folded.
        HStack(spacing: 5) {
            if renaming {
                TextField("Project", text: $newName)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(12, .semibold))
                    .focused(naming)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: naming.wrappedValue) { _, on in if !on { commit() } }
            } else {
                Text(name).font(Theme.sans(12, .semibold)).foregroundStyle(hover ? Theme.ink : Theme.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .opacity(hover || folded ? 1 : 0)
            }
            if waiting { Circle().fill(Theme.accent).frame(width: 6, height: 6).help("Something new in this project") }
            Spacer(minLength: 4)
            if hover && !renaming {
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                }
                .buttonStyle(IconButtonStyle())
                .help("New session in \(name)")
            } else if folded {
                Text("\(count)").font(Theme.sans(11.5)).monospacedDigit().foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10).frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { toggle() } }
        .onHover { hover = $0 }
    }
}

// MARK: - Detail

/// The full-window tabs opened so far, and the session they were opened in. Tabs of another
/// session never count: on a session switch the old set lived one more frame, so the new session
/// built every pane the old one had open (Assets, Sound, Post) and dropped them again. That made a
/// switch 200+ ms instead of under 100 (perf.txt, 2026-10-02).
struct KeptTabs: Equatable {
    var session: URL?
    var tabs: Set<String> = []

    func on(_ s: URL) -> Set<String> { s == session ? tabs : [] }

    mutating func open(_ tab: String, in s: URL?) {
        if s != session { session = s; tabs = [] }
        tabs.insert(tab)
    }
}

struct DetailView: View {
    @Environment(AppModel.self) var app
    var library: Library
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder
    @AppStorage("rightTab") private var rightTab = "script"
    @Environment(\.colorScheme) private var scheme
    /// The full-window tabs opened in this session so far. They stay mounted.
    @State private var opened = KeptTabs()

    /// The post tab takes the whole window. The camera and takes only distract while you write.
    private var postMode: Bool {
        rightTab == "post" && !app.isRecording && library.current != nil
            && !(library.selectedSessions.count > 1)
    }

    /// Tabs that hide the camera and the stage player for as long as they show.
    private var stageCovered: Bool {
        ["post", "storyboard", "broll"].contains(rightTab) && !app.isRecording && library.current != nil
            && !(library.selectedSessions.count > 1)
    }

    var body: some View {
        let _ = Perf.body("DetailView")
        Group {
            if library.selectedSessions.count > 1 && !app.isRecording {
                BulkView(library: library)
            } else {
                recorder
            }
        }
        .onAppear { app.postView = postMode; app.stageCovered = stageCovered }
        .onChange(of: postMode) { _, on in app.postView = on }
        .onChange(of: stageCovered) { _, on in app.stageCovered = on }
    }

    /// Post always covers the stage. Assets and Sound cover it until you open a file:
    /// then the file plays on the stage and the list sits beside it.
    private var cover: String? {
        guard !app.isRecording, library.current != nil, !(library.selectedSessions.count > 1) else { return nil }
        if rightTab == "post" || rightTab == "storyboard" || rightTab == "broll" { return rightTab }
        if (rightTab == "assets" || rightTab == "sounds") && app.preview == nil { return rightTab }
        return nil
    }

    private var recorder: some View {
        VStack(spacing: 0) {
            if let doc = library.current {
                SessionHeader(doc: doc)
                    // A tall Post page squeezed the header and cut the title's top (2026-10-02).
                    .fixedSize(horizontal: false, vertical: true)
                    .sheet(isPresented: Bindable(app).cleaningUp) { CleanupSheet(doc: doc) }
                Rule()
            }
            ZStack {
                // The recorder stays mounted under the cover: removing the camera preview
                // while the camera stops or starts deadlocks AVFoundation.
                split
                    .pageFade(cover == nil)
                    .allowsHitTesting(cover == nil)
                    .accessibilityHidden(cover != nil)
                // A tab stays mounted once opened, hidden under the others: going back to it is
                // instant, with no rebuild, no rescan and no fade (2026-10-02). A new session
                // starts fresh.
                if let doc = library.current, cover != nil || !opened.on(doc.url).isEmpty {
                    let kept = opened.on(doc.url)
                    ChatSlot(hub: app.chats, doc: doc, active: cover != nil) {
                        VStack(spacing: 0) {
                            // One switch over the three Assets pages, so it stays put when you
                            // change page (2026-10-04: each page drew its own and it jumped).
                            if let c = cover, AssetsSwitch.pages.contains(c) {
                                AssetsSwitch()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 28).padding(.top, 20)
                                    .background(Theme.canvas)
                            }
                            ZStack {
                                // Under the pages as they cross-fade: never the Record stage and
                                // its camera between two tabs (2026-10-04).
                                Theme.canvas
                                ForEach(["storyboard", "assets", "sounds", "broll", "post"], id: \.self) { k in
                                    if k == cover || kept.contains(k) { pane(k, doc) }
                                }
                            }
                        }
                    }
                    .id(doc.url)
                    .animation(.page) { $0.opacity(cover == nil ? 0 : 1) }
                    .allowsHitTesting(cover != nil)
                    .accessibilityHidden(cover == nil)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let doc = library.current, !app.isRecording {
                // Above the Assets footer bar, clear of its buttons.
                ChatCorner(hub: app.chats, doc: doc)
                    .padding(.trailing, 18).padding(.bottom, 52)
                    .transition(.opacity)
            }
        }
        // A file opened in Assets or Sound must not cover the camera in Record.
        .onChange(of: rightTab) { _, tab in
            if tab == "script" && !app.isRecording { app.preview = nil }
            // A hidden tab keeps its views: typing must not go on in its text field.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: cover) { _, c in if let c { opened.open(c, in: library.current?.url) } }
        .onChange(of: library.current?.url) { opened = KeptTabs(session: library.current?.url, tabs: cover.map { [$0] } ?? []) }
        // Nothing extra stays mounted while a take records.
        .onChange(of: app.isRecording) { _, on in if on { opened = KeptTabs() } }
    }

    private func pane(_ k: String, _ doc: SessionDoc) -> some View {
        Group {
            switch k {
            case "post": PostPane(doc: doc)
            case "storyboard": StoryboardPane(doc: doc)
            case "assets": AssetsPane(doc: doc, wide: true)
            case "broll": BrollPane(doc: doc)
            default: SoundsPane(doc: doc, bed: app.bed, wide: true)
            }
        }
        .background(Theme.canvas)
        .pageFade(k == cover)
        .allowsHitTesting(k == cover)
        .accessibilityHidden(k != cover)
        .environment(\.paneShown, k == cover)
    }

    private var split: some View {
            PersistentSplit(minLeft: 380, minRight: 320) {
                VStack(spacing: 0) {
                    ZStack {
                        // The live preview stays mounted, even under the player or while paused.
                        // Removing its layer while the session stops or starts deadlocks AVFoundation.
                        CameraCard(camera: camera, doc: library.current)
                        if app.preview != nil {
                            // Dark at once under a file: the player fades in on the stage, not
                            // over the daylight Record page and the camera (2026-10-04).
                            Theme.stage.transition(.asymmetric(insertion: .identity, removal: .opacity))
                        }
                        if let url = app.preview {
                            // Comments live in the library a file sits in, else in the session.
                            let commentRoot = StyleLib.root(containing: url) ?? library.current?.url
                            Group {
                                if Asset.kind(of: url) == .image, let commentRoot {
                                    StillReview(url: url, session: commentRoot).id(url)
                                } else if Asset.kind(of: url) == .image {
                                    StillView(url: url)
                                } else if Asset.kind(of: url) == .video, let commentRoot {
                                    ReviewPlayer(url: url, session: commentRoot).id(url)
                                } else if DocReview.handles(url), let commentRoot {
                                    DocReview(url: url, root: commentRoot).id(url)
                                } else {
                                    PlayerView(url: url) { app.player = $0 }.id(url)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.stage)
                        } else {
                            overlay
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                    // Daylight while you prepare, dark from the countdown on (AppModel.lightsDown).
                    .background(app.lightsDown ? Theme.stage : Theme.canvas)
                    .animation(.easeInOut(duration: 0.45), value: app.lightsDown)
                    .modifier(StageHoverBar(url: app.preview, session: library.current != nil, paused: camera.paused))
                    // Their own views: a toast or a notice redraws only itself (2026-10-02).
                    .overlay(alignment: .bottom) { StageToast() }
                    .overlay(alignment: .top) { StageNotice(session: library.current?.url) }
                    .overlay(alignment: .topTrailing) {
                        if let url = app.preview, Asset.kind(of: url) == .video { BedPill(bed: app.bed).padding(12) }
                    }
                    .overlay(alignment: .topLeading) {
                        // Assets and Sound: back to the whole list.
                        if app.preview != nil, !app.isRecording, rightTab == "assets" || rightTab == "sounds" {
                            Button { app.preview = nil } label: {
                                StagePill(text: rightTab == "assets" ? "All assets" : "All sounds", icon: "chevron.left")
                            }
                            .buttonStyle(.plain)
                            .help("Close the file and show the whole list")
                            .padding(12)
                            .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if app.preview == nil || app.isRecording {
                            RecordPill(camera: camera, screen: screen)
                                .padding(.bottom, 18)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                    }
                    .animation(Theme.motion, value: app.preview)
                    .overlay {
                        if let doc = library.current, rightTab == "script" {
                            ScriptBeside(hub: app.chats, doc: doc)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The stage, the pill and its popover all follow the lights.
                .environment(\.colorScheme, app.lightsDown ? .dark : scheme)
            } right: {
                // Not under a full-window tab: that tab shows the chat, and a second copy out of
                // sight drew every streamed word twice.
                ChatSlot(hub: app.chats, doc: library.current, replace: true, active: !app.isRecording && cover == nil) {
                    if let doc = library.current {
                        // The column lists files only while one plays on the stage. Under a full-window
                        // tab it keeps the script and takes: before, it built a second copy of the
                        // tab out of sight, and Record rebuilt the script each time (2026-10-02).
                        VStack(spacing: 0) {
                            if rightTab == "assets" && cover == nil && !app.isRecording {
                                AssetsPane(doc: doc)
                            } else if rightTab == "sounds" && cover == nil && !app.isRecording {
                                SoundsPane(doc: doc, bed: app.bed)
                            } else {
                                ScriptPane(doc: doc)
                                Rule()
                                TakesList(doc: doc).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .environment(\.colorScheme, app.lightsDown ? .dark : scheme)
                    } else {
                        EmptySessionView(library: library)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    @ViewBuilder private var overlay: some View {
        switch app.phase {
        case .countdown(let n):
            Text("\(n)")
                .font(Theme.sans(140, .bold))
                .foregroundStyle(.white)
                .shadow(radius: 12)
        case .recording:
            // REC and the screen sit in the camera card's caption.
            EmptyView()
        case .starting, .finishing:
            ProgressView().controlSize(.large).tint(.white)
        case .idle:
            if let p = camera.permissionProblem {
                Text(p).foregroundStyle(.white).padding().background(Theme.stage.opacity(0.9), in: .rect(cornerRadius: Theme.radius))
            } else if let e = app.error {
                Text(e).foregroundStyle(.white).padding().background(Theme.accent, in: .rect(cornerRadius: Theme.radius))
                    .onTapGesture { app.error = nil }
            }
        }
    }
}

/// The camera as a framed card on the stage, the way a viewfinder sits on a desk: the live picture
/// with soft corner marks, or a resting card while the light is off. Above it, which take is next.
/// (2026-10-03: the stage was a full-bleed navy slab and felt like another app.)
struct CameraCard: View {
    @Environment(AppModel.self) var app
    @ObservedObject var camera: CameraRecorder
    var doc: SessionDoc?
    @AppStorage("rightTab") private var rightTab = "script"
    @AppStorage("scriptBeside") private var scriptBeside = false

    private static let corner: CGFloat = 18
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.corner, style: .continuous) }
    private var ratio: CGFloat { camera.orientation == .vertical ? 9.0 / 16.0 : 16.0 / 9.0 }
    private var next: Int { (doc?.meta.takes.map(\.number).max() ?? 0) + 1 }
    private var rolling: Bool { if case .recording = app.phase { return true }; return false }

    var body: some View {
        ZStack {
                CameraPreview(session: camera.session, fill: true, rotation: camera.previewRotation, corner: Self.corner)
                if camera.paused {
                    resting.transition(.opacity)
                } else if !app.lightsDown {
                    FrameMarks().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(16).allowsHitTesting(false).transition(.opacity)
                }
            }
            .clipShape(shape)
            .background(shape.fill(Theme.stage).shadow(color: app.lightsDown ? .black.opacity(0.5) : Theme.shadow.opacity(camera.paused ? 0 : 2.2),
                                                       radius: app.lightsDown ? 30 : 22, y: app.lightsDown ? 0 : 10))
            .overlay(shape.strokeBorder(rolling ? Theme.danger.opacity(0.7) : Theme.border.opacity(app.lightsDown ? 0 : 1),
                                        lineWidth: rolling ? 2 : 1))
            // The caption rides on the card's top edge, so the two stay together at any size.
            .overlay(alignment: .topLeading) { caption.offset(y: -36) }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28).padding(.top, 56).padding(.bottom, 96)  // the record pill sits below
        .animation(Theme.motion, value: camera.paused)
        .animation(Theme.motion, value: rolling)
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if rolling { LivePill() }
            Text("Take \(String(format: "%02d", next))").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            Text(rolling ? "rolling" : app.lightsDown ? "about to roll" : "up next")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            // In the caption row, not on the stage: a pill there covered "Take 01 up next" (2026-10-04).
            if doc != nil, rightTab == "script", app.chats.open, app.chats.docked, !app.isRecording, !scriptBeside {
                Button { scriptBeside = true } label: {
                    Label("Script beside chat", systemImage: "doc.text").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Show the script in this half, next to the chat")
            }
            if app.mode == .cameraScreen {
                Label("Screen too", systemImage: "display").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.muted)
            }
            if !camera.formatDescription.isEmpty && !camera.paused {
                Text(camera.formatDescription).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 2)
    }

    /// The light is off: a calm, flat card. One line and one quiet button.
    private var resting: some View {
        ZStack {
            Theme.paper.overlay(Theme.accentSoft.opacity(0.55))
            VStack(spacing: 14) {
                ViewThatFits(in: .vertical) {
                    LiveMascot(mood: .idle, size: 44)
                    Color.clear.frame(height: 0)
                }
                Text("Camera off").font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
                Button { camera.setPaused(false) } label: { Label("Turn on", systemImage: "video") }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
            }
            .padding(20)
        }
    }
}

/// Four soft corner marks, like a viewfinder.
struct FrameMarks: Shape {
    var length: CGFloat = 22
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 4, r.height / 4)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x, y: y + dy * l))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

/// The toast over the stage ("Saved stills/…").
private struct StageToast: View {
    @Environment(AppModel.self) var app
    var body: some View {
        ZStack {
            if let t = app.toast {
                StagePill(text: t, icon: "checkmark", accent: true)
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Theme.motion, value: app.toast)
    }
}

/// A file a chat wants to show, when no session is open. With one open, the header shows it
/// (HeaderNotice).
private struct StageNotice: View {
    @Environment(AppModel.self) var app
    let session: URL?
    var body: some View {
        ZStack {
            if session == nil, let n = app.notice(for: nil), !app.isRecording { NoticePill(notice: n).padding(.top, 12) }
        }
        .animation(Theme.motion, value: app.notices)
    }
}

/// An audio file on the stage shows its name and the way back while the pointer is over it.
/// The hover lives here: before, it was state of the whole detail view, and each time the
/// pointer crossed the stage edge the whole window built its views again (2026-10-02).
private struct StageHoverBar: ViewModifier {
    @Environment(AppModel.self) var app
    let url: URL?
    let session: Bool
    let paused: Bool
    @State private var hover = false

    private var wanted: Bool {
        guard let url else { return false }
        return Asset.kind(of: url) == .audio || !session
    }

    func body(content: Content) -> some View {
        content
            .onHover { h in
                guard wanted || hover else { return }
                withAnimation(Theme.motion) { hover = h }
            }
            .overlay {
                if let url, wanted, hover {
                    VStack {
                        HStack(spacing: 8) {
                            StagePill(text: url.lastPathComponent, icon: nil)
                            Spacer()
                            if app.canSaveFrame {
                                Button { app.saveFrame() } label: {
                                    StagePill(text: "Save frame", icon: "camera.viewfinder", accent: true)
                                }
                                .buttonStyle(.plain)
                                .help("Save the frame you see as a PNG in stills/ (S)")
                            }
                            Button { app.preview = nil } label: {
                                StagePill(text: paused ? "Back" : "Live camera",
                                          icon: paused ? "xmark" : "video.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .transition(.opacity)
                }
            }
    }
}

/// Floats on the stage: the time, the record button, the shape, the screen and the devices.
struct RecordPill: View {
    @Environment(AppModel.self) var app
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder
    @State private var devices = false
    @State private var hover = false

    private var recording: Bool { if case .recording = app.phase { return true }; return false }
    private var stoppable: Bool {
        if case .countdown = app.phase { return true }
        return recording
    }

    var body: some View {
        let _ = Perf.body("RecordPill")
        HStack(spacing: 12) {
            clock
            Button(action: app.toggleRecord) {
                ZStack {
                    Circle().strokeBorder(Theme.danger.opacity(recording ? 0.9 : 0.3), lineWidth: 2.5)
                    RoundedRectangle(cornerRadius: recording ? 4 : 15)
                        .fill(Theme.danger)
                        .frame(width: recording ? 16 : 30, height: recording ? 16 : 30)
                }
                .frame(width: 44, height: 44)
                .scaleEffect(hover ? 1.06 : 1)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .disabled(!(app.phase == .idle || stoppable))
            .help(recording ? "Stop (⌘R)" : "Record (⌘R)")
            HStack(spacing: 2) {
                ghost(camera.orientation == .vertical ? "Vertical" : "Horizontal",
                      help: "Switch between vertical and horizontal. \(camera.formatDescription)") {
                    camera.orientation = camera.orientation == .vertical ? .horizontal : .vertical
                }
                ghost(app.mode == .cameraScreen ? "Screen on" : "Screen off",
                      help: "Record your screen too, as a second file") {
                    app.mode = app.mode == .cameraScreen ? .camera : .cameraScreen
                }
                Button { devices.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PillGhostStyle())
                .help("Camera, microphone and screen")
                .popover(isPresented: $devices, arrowEdge: .top) {
                    DevicePanel(camera: camera, screen: screen)
                }
            }
            .disabled(app.isRecording)
            .opacity(app.isRecording ? 0.35 : 1)
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 8)
        // Paper on the daylight stage; it follows the stage into the dark while you record.
        .background(Capsule().fill(Theme.paper).shadow(color: Theme.shadow.opacity(1.8), radius: 18, y: 6))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .foregroundStyle(Theme.ink)
        .animation(Theme.spring, value: recording)
        .animation(Theme.spring, value: hover)
    }

    /// The time since you started; the mic level while you wait.
    @ViewBuilder private var clock: some View {
        if case .recording(let start) = app.phase {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                Text(SessionDoc.clock(ctx.date.timeIntervalSince(start)))
                    .font(Theme.sans(13, .medium).monospacedDigit())
                    .frame(minWidth: 44, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("0:00").font(Theme.sans(13).monospacedDigit()).foregroundStyle(Theme.muted)
                LevelMeter(meter: camera.meter, track: Theme.border, fill: Theme.live)
                    .frame(width: 36, height: 3)
                    .clipShape(Capsule())
                    .help("Microphone level")
            }
            .frame(minWidth: 44, alignment: .leading)
        }
    }

    private func ghost(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(Theme.sans(12, .medium))
                .contentTransition(.opacity)
                .padding(.horizontal, 10).frame(height: 28)
        }
        .buttonStyle(PillGhostStyle())
        .help(help)
    }
}

/// A quiet button in the record pill: muted, ink on a soft well when the pointer is over it.
struct PillGhostStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? Theme.ink : Theme.muted)
            .background(Capsule().fill(hover ? Theme.hover : .clear))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(Theme.motion, value: hover)
    }
}

/// Shows while you record: a red pill with a slow pulse.
struct LivePill: View {
    var body: some View {
        HStack(spacing: 7) {
            // A layer animation: a SwiftUI one re-rendered the window every frame while recording.
            LayerPulse(color: .white, low: 0.35).frame(width: 7, height: 7)
            Text("REC").font(Theme.sans(12, .semibold))
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 4)
        .background(Theme.danger.opacity(0.92), in: Capsule())
        .foregroundStyle(.white)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

/// The devices behind the pill's slider button.
struct DevicePanel: View {
    @Environment(AppModel.self) var app
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Camera") {
                Picker("", selection: Binding(get: { camera.videoID }, set: { camera.chooseVideo($0) })) {
                    ForEach(camera.videoDevices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                .labelsHidden()
            }
            row("Shape") {
                Picker("", selection: $camera.orientation) {
                    Text("Horizontal").tag(Orientation.horizontal)
                    Text("Vertical").tag(Orientation.vertical)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            row("Microphone") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(get: { camera.audioID }, set: { camera.chooseAudio($0) })) {
                        ForEach(camera.audioDevices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                    .labelsHidden()
                    LevelMeter(meter: camera.meter, track: Theme.border, fill: Theme.live)
                        .frame(height: 3).clipShape(Capsule())
                }
            }
            if app.mode == .cameraScreen {
                row("Screen") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $screen.displayID) {
                            ForEach(screen.displays) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        Text("Takes hides itself from the screen file.").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                    }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Toggle(isOn: Binding(get: { !camera.paused }, set: { camera.setPaused(!$0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Camera on").font(Theme.sans(12.5, .medium))
                    Text("Off turns the light off. Record turns it back on.").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.muted)
            content()
        }
    }
}

/// Observes only the meter, so the 12 Hz level updates redraw this bar and nothing else.
struct LevelMeter: View {
    @ObservedObject var meter: MicMeter
    var track: Color = Theme.border
    var fill: Color = Theme.ink.opacity(0.55)
    var body: some View {
        let level = meter.level
        return
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(level > 0.9 ? Theme.danger : fill)
                    .frame(width: g.size.width * CGFloat(level))
            }
        }
    }
}

struct TakesList: View {
    var doc: SessionDoc
    @State private var dragging: Int?

    var body: some View {
        let _ = Perf.body("TakesList")
        if doc.meta.takes.isEmpty {
            Text("No takes yet. Files land in the session folder as take-01-camera.mov, take-01-screen.mov, …")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        } else {
            // As tall as the takes, up to 150; then it scrolls.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
            .frame(maxHeight: 150)
            .background(Theme.paper)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(doc.takeGroups.enumerated()), id: \.element.number) { i, g in
                if i > 0 { Rule() }
                row(g.number, g.takes)
            }
        }
    }

    private func row(_ number: Int, _ takes: [Take]) -> some View {
        TakeRow(doc: doc, number: number, takes: takes)
            .reorderable(number, dragging: $dragging) { doc.moveTake($0, to: $1) }
    }
}

struct TakeRow: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    let number: Int
    let takes: [Take]
    @State private var name = ""
    @State private var hooks: [Hook] = []
    @FocusState private var editing: Bool

    private func trash() {
        if takes.contains(where: { doc.fileURL($0) == app.preview }) { app.preview = nil }
        doc.trashTake(number)
    }

    private var trashButton: some View {
        Button("Move Take to Trash", role: .destructive, action: trash).disabled(app.isRecording)
    }

    /// "Hook 2" while that hook is still in hooks.json, else "hook".
    private func hookLabel(_ text: String) -> String {
        hooks.firstIndex { $0.text == text }.map { "Hook \($0 + 1)" } ?? "hook"
    }

    var body: some View {
        let _ = Perf.body("TakeRow")
        let keeper = takes.first?.keeper == true
        HStack(spacing: 10) {
            Button { doc.toggleKeeper(number) } label: {
                Image(systemName: keeper ? "star.fill" : "star").foregroundStyle(keeper ? Theme.accent : Theme.muted)
            }
            .help("Mark as keeper")
            Text(String(format: "%02d", number)).font(Theme.mono(12, .medium)).foregroundStyle(Theme.accentInk)
            TextField("Take \(number)", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.sans(13, .medium))
                .frame(minWidth: 80, maxWidth: 220)
                .focused($editing)
                .onSubmit { doc.renameTake(number, to: name) }
                // Typing saves the name; leaving the field renames the files too.
                .task(id: name) {
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { doc.nameTake(number, name) }
                }
                .onChange(of: editing) { _, now in
                    if !now && !app.isRecording { doc.renameTake(number, to: name) }
                }
                .disabled(app.isRecording)
                .help("Type a name. It saves as you type; the files get it when you leave the field.")
            Text((takes.first?.duration).map(SessionDoc.clock) ?? "–")
                .font(Theme.mono(12)).foregroundStyle(Theme.muted)
            if let variant = takes.first?.script {
                Tag(text: variant, accent: true)
                    .help("Read from the variant “\(variant)”")
            }
            if let hook = takes.first?.hook {
                Tag(text: hookLabel(hook), accent: false)
                    .help("Opened with: \(hook)")
            }
            ForEach(takes) { t in
                let url = doc.fileURL(t)
                Button { app.preview = url } label: {
                    Label(t.kind == .camera ? "Camera" : "Screen", systemImage: app.preview == url ? "play.fill" : "play")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(BracketButtonStyle(active: app.preview == url))
                .disabled(app.isRecording)
                .help("Play \(t.file)")
                .contextMenu {
                    Button("Open in QuickTime") { NSWorkspace.shared.open(url) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Divider()
                    trashButton
                }
            }
            Spacer()
            Button(action: trash) { Image(systemName: "trash").foregroundStyle(Theme.muted) }
                .help("Move take to Trash")
                .disabled(app.isRecording)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu { trashButton }
        .onAppear { name = takes.first?.name ?? "" }
        .onDisappear { if name != (takes.first?.name ?? "") { doc.nameTake(number, name) } }
        .onAppear { hooks = HookStore.read(doc.url).hooks }
        .onChange(of: takes.first?.name) { _, n in name = n ?? "" }
    }
}

/// Shown in the script pane when no session is open.
struct EmptySessionView: View {
    @Environment(AppModel.self) var app
    var library: Library

    var body: some View {
        let _ = Perf.body("EmptySessionView")
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Mascot(size: 96).padding(.bottom, 4)
                    (Text("Ready when you are.\n").foregroundStyle(Theme.ink)
                     + Text("Just hit record.").foregroundStyle(Theme.accent))
                        .font(Theme.display(42))
                        .lineSpacing(2)
                    Text("Takes makes the session for you and names it from your script.")
                        .font(Theme.sans(15)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { app.toggleRecord() } label: {
                        HStack(spacing: 7) {
                            Circle().frame(width: 9, height: 9)
                            Text("Record")
                            Text("⌘R").font(Theme.mono(10.5)).opacity(0.75)
                        }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .solid))
                    Button { library.createSession() } label: {
                        HStack(spacing: 7) { Text("New Session"); Text("⌘N").font(Theme.mono(10.5)).foregroundStyle(Theme.muted) }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                }
                if !library.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(number: "01", text: "continue")
                        VStack(spacing: 0) {
                            ForEach(Array(library.sessions.prefix(4).enumerated()), id: \.element.id) { i, s in
                                if i > 0 { Rule() }
                                Button { library.selectedSessions = [s.url] } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(s.title).font(Theme.sans(13, .medium)).lineLimit(1)
                                            Text("\(s.createdAt.formatted(.relative(presentation: .named))) · \(s.takeCount) take\(s.takeCount == 1 ? "" : "s")")
                                                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                        Text("↗").foregroundStyle(Theme.accent)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(HoverRowStyle())
                            }
                        }
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                    }
                }
                Text("Tip: ask Takes to “create a Takes session with this script”. It shows up here.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    .builderBorder()
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity, minHeight: 0)
        }
        .background(Theme.surface)
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.radius)
                .fill(configuration.isPressed ? Theme.accentSoft : hover ? Theme.surface : .clear))
            .onHover { hover = $0 }
    }
}

struct BulkMenu: View {
    var library: Library
    let urls: Set<URL>

    var body: some View {
        let others = library.projects.filter { $0.url != library.selectedProject }
        if !others.isEmpty {
            Menu("Move to Project") {
                ForEach(others) { p in Button(p.name) { library.moveSessions(urls, to: p.url) } }
            }
        }
        Button("Trash Takes Without a Star") { library.trashNonKeepers(urls) }
        Menu(urls.count == 1 ? "Mark as Published On" : "Mark \(urls.count) as Published On") {
            ForEach(Platforms.all, id: \.self) { p in Button(p) { library.markPublished(urls, on: p) } }
            Button("Somewhere Else") { library.markPublished(urls) }
        }
        let archived = library.sessions.filter { urls.contains($0.url) }.allSatisfy(\.archived)
        Button(archived ? "Unarchive" : "Archive") { library.setArchived(urls, !archived) }
        Button("Reveal in Finder") { library.reveal(urls) }
        Divider()
        Button(urls.count == 1 ? "Move Session to Trash" : "Move \(urls.count) Sessions to Trash", role: .destructive) {
            library.trashSessions(urls)
        }
    }
}

struct BulkView: View {
    var library: Library
    @State private var note: String?
    @State private var stats = BulkStats()

    struct BulkStats: Equatable {
        var takes = 0, starred = 0, unstarred = 0, bytes: Int64 = 0
        var empty: Set<URL> = []
    }

    var body: some View {
        let urls = library.selectedSessions
        let picked = library.sessions.filter { urls.contains($0.url) }
        let others = library.projects.filter { $0.url != library.selectedProject }
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(picked)
                    if stats.empty.count == picked.count && !picked.isEmpty {
                        emptyBanner(picked.count)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        card("01", "selected") {
                            ForEach(picked) { s in sessionRow(s) }
                        }
                        card("02", "actions") {
                            Menu {
                                ForEach(others) { p in Button(p.name) { library.moveSessions(urls, to: p.url) } }
                            } label: {
                                actionLabel("folder", "Move to Project",
                                            others.isEmpty ? "Create another project first" : "Keeps every file and script")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .disabled(others.isEmpty)
                            action("star.slash", "Keep Only Starred Takes",
                                   stats.unstarred == 0 ? "Every take has a star" : "Trash \(stats.unstarred) take\(stats.unstarred == 1 ? "" : "s") without a star") {
                                let n = library.trashNonKeepers(urls)
                                note = "Moved \(n) take\(n == 1 ? "" : "s") to the Trash."
                                Task { await refresh() }
                            }
                            .disabled(stats.unstarred == 0)
                            action("magnifyingglass", "Show in Finder", "Select the folders in Finder") { library.reveal(urls) }
                            Rule().padding(.vertical, 2)
                            action("trash", "Move to Trash", "\(picked.count) sessions · ⌘⌫", destructive: true) {
                                library.trashSessions(urls)
                            }
                            .keyboardShortcut(.delete, modifiers: .command)
                        }
                    }
                    Text(note ?? "Everything goes to the macOS Trash, so you can get it back.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .builderBorder()
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 36).padding(.vertical, 40)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .task(id: urls) { await refresh() }
    }

    private func header(_ picked: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(number: "00", text: "selection")
            (Text("\(picked.count) sessions. ").foregroundStyle(Theme.ink)
             + Text("One move.").foregroundStyle(Theme.accent))
                .font(Theme.display(42))
            Text(summary(picked)).font(Theme.mono(12)).foregroundStyle(Theme.muted)
        }
    }

    private func summary(_ picked: [SessionSummary]) -> String {
        var parts = ["\(stats.takes) take\(stats.takes == 1 ? "" : "s")"]
        if stats.starred > 0 { parts.append("\(stats.starred) starred") }
        parts.append(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file))
        let dates = picked.map(\.createdAt)
        if let lo = dates.min(), let hi = dates.max() {
            let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
            parts.append(Calendar.current.isDate(lo, inSameDayAs: hi) ? lo.formatted(f) : "\(lo.formatted(f)) – \(hi.formatted(f))")
        }
        return parts.joined(separator: " · ")
    }

    private func emptyBanner(_ n: Int) -> some View {
        HStack(spacing: 12) {
            Text(n == 1 ? "This session has no takes." : "None of these sessions has a take.")
                .font(Theme.sans(13, .medium))
            Spacer()
            Button("Trash \(n) Empty Session\(n == 1 ? "" : "s")") { library.trashSessions(stats.empty) }
                .buttonStyle(AccentButtonStyle(kind: .solid))
        }
        .padding(.vertical, 10).padding(.trailing, 10)
        .builderBorder()
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func card<C: View>(_ number: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(number: number, text: title)
                .padding(.horizontal, 8).padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    private func sessionRow(_ s: SessionSummary) -> some View {
        HStack(spacing: 10) {
            Button { library.selectedSessions = [s.url] } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(Theme.sans(13, .medium)).lineLimit(1)
                    Text("\(s.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(s.takeCount) take\(s.takeCount == 1 ? "" : "s")")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open only this session")
            Button { library.selectedSessions.remove(s.url) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .help("Remove from selection")
        }
        .padding(8)
        .background(HoverBackground())
    }

    private func actionLabel(_ icon: String, _ title: String, _ detail: String, destructive: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(destructive ? Theme.danger : Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.sans(13, .medium))
                    .foregroundStyle(destructive ? Theme.danger : Theme.ink)
                Text(detail).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(8)
        .contentShape(Rectangle())
    }

    private func action(_ icon: String, _ title: String, _ detail: String, destructive: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) { actionLabel(icon, title, detail, destructive: destructive) }
            .buttonStyle(HoverRowStyle())
    }

    /// Counts on a background thread: the size walk visits every file of every picked session,
    /// and blocked the click that selected them (2026-10-01).
    private func refresh() async {
        let urls = library.selectedSessions
        let s = await Task.detached(priority: .userInitiated) { Self.count(urls) }.value
        guard !Task.isCancelled, urls == library.selectedSessions else { return }
        stats = s
    }

    nonisolated private static func count(_ urls: Set<URL>) -> BulkStats {
        var s = BulkStats()
        for u in urls {
            let takes = Store.readMeta(u)?.takes ?? []
            let groups = Dictionary(grouping: takes, by: \.number)
            s.takes += groups.count
            s.starred += groups.values.filter { $0.contains(where: \.keeper) }.count
            s.unstarred += Set(takes.filter { !$0.keeper }.map(\.number)).count
            if takes.isEmpty { s.empty.insert(u) }
            if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e { s.bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            }
        }
        return s
    }
}

/// Hover highlight for rows that hold their own buttons.
struct HoverBackground: View {
    @State private var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.radius)
            .fill(hover ? Theme.surface : .clear)
            .onHover { hover = $0 }
    }
}

/// A small dark label that floats over the video.
/// In the sidebar, after a session's title: Claude is working in it (a ring), or left something
/// to look at there (an orange dot: a reply, or a file it wanted to show).
struct ClaudeActivity: View {
    let chat: ClaudeChat?
    let waiting: Bool
    var body: some View {
        if let chat { Live(chat: chat, waiting: waiting) } else if waiting { Self.dot.help("Takes has something to show you here") }
    }

    static var dot: some View { Circle().fill(Theme.accent).frame(width: 7, height: 7) }

    private struct Live: View {
        var chat: ClaudeChat
        let waiting: Bool
        var body: some View {
            Group {
                if chat.running {
                    LayerSpinner(color: Theme.faint, lineWidth: 1.5, inset: 0, length: 0.3)
                        .frame(width: 9, height: 9)
                        .help("Takes is working in this session")
                } else if waiting || chat.unread {
                    ClaudeActivity.dot.help(waiting ? "Takes has something to show you here" : "Takes replied")
                }
            }
            .transition(.opacity)
            .animation(Theme.motion, value: chat.running)
        }
    }
}

/// Top of the stage: a file a chat in another session wanted to show. Waits for a click.
struct NoticePill: View {
    @Environment(AppModel.self) var app
    let notice: AgentNotice
    var body: some View {
        // A session in another project is not in the sidebar list: read its title from disk.
        let title = notice.session.flatMap { s in
            app.library.sessions.first { $0.url.standardizedFileURL == s }?.title ?? Store.readMeta(s)?.title
        }
        let more = app.notices.count - 1
        HStack(spacing: 2) {
            Button { app.show(notice) } label: {
                StagePill(text: (title.map { "\($0) · " } ?? "") + notice.path.lastPathComponent
                          + (more > 0 ? "  +\(more)" : ""), icon: "sparkle", accent: true)
            }
            .buttonStyle(.plain)
            .help("Takes wants to show you this. Click to go there.")
            Button { app.notices.removeAll() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// The header's middle: a file a chat wants the user to see, as a card with its picture
/// (2026-10-04: a pill of raw file names on the stage covered the stage's own buttons).
/// It floats on the middle of the window, over the header row (SessionHeader). Waits for a click.
struct HeaderNotice: View {
    @Environment(AppModel.self) var app
    let session: URL?

    var body: some View {
        ZStack {
            if let n = app.notice(for: session), !app.isRecording {
                NoticeCard(notice: n, here: n.session == session?.standardizedFileURL, more: app.notices.count - 1)
                    .id(n.id)
                    .transition(.opacity.combined(with: .offset(y: -8)).combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(Theme.spring, value: app.notices)
    }
}

private struct NoticeCard: View {
    @Environment(AppModel.self) var app
    let notice: AgentNotice
    let here: Bool
    let more: Int
    @State private var thumb: NSImage?

    var body: some View {
        let d = AgentNotice.describe(notice.path, session: notice.session)
        // A session in another project is not in the sidebar list: read its title from disk.
        let from = here ? nil : notice.session.flatMap { s in
            app.library.sessions.first { $0.url.standardizedFileURL == s }?.title ?? Store.readMeta(s)?.title
        }
        NoticeCardBody(what: d.what, detail: [from ?? "", d.name].filter { !$0.isEmpty }.joined(separator: " · "),
                       icon: Self.icon(notice.path, d.what), thumb: thumb, more: more,
                       show: { app.show(notice) },
                       dismiss: { app.notices.removeAll { $0.id == notice.id } })
            .task(id: notice.path) { thumb = await Self.picture(notice.path) }
    }

    static func icon(_ path: URL, _ what: String) -> String {
        if what.hasPrefix("Script") { return "doc.text" }
        if what.hasPrefix("Storyboard") { return "rectangle.split.3x1" }
        if what.hasPrefix("Post") { return "text.bubble" }
        if what == "Session" || what == "Project" || what == "Folder" { return "folder" }
        switch Asset.kind(of: path) {
        case .video: return "play.rectangle.fill"
        case .image: return "photo"
        case .audio: return "waveform"
        case .other: return "sparkle"
        }
    }

    /// A frame of a video, or the image itself. Nothing for other files: they get an icon.
    static func picture(_ url: URL) async -> NSImage? {
        guard [.video, .image].contains(Asset.kind(of: url)),
              let at = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let a = Asset(url: url, group: "", name: url.lastPathComponent, size: Int64(at.fileSize ?? 0),
                      modified: at.contentModificationDate ?? .distantPast)
        return await Thumbs.shared.image(a)
    }
}

/// The card itself, without the app: the brand snapshot renders it too.
struct NoticeCardBody: View {
    let what: String
    let detail: String
    let icon: String
    var thumb: NSImage? = nil
    var more = 0
    var show: () -> Void = {}
    var dismiss: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: show) {
                HStack(spacing: 10) {
                    picture
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            Text("\(what) is ready").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                        }
                        if !detail.isEmpty {
                            Text(detail).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
                    Text("Show").font(Theme.sans(11.5, .semibold)).foregroundStyle(hover ? .white : Theme.accentInk)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(hover ? Theme.accent : Theme.accentSoft, in: Capsule())
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Theme.motion) { hover = h } }
            .help(more > 0 ? "Takes wants to show you this. Click to go there. \(more) more after it."
                           : "Takes wants to show you this. Click to go there.")
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(6).padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper)
            .shadow(color: Theme.shadow, radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(hover ? Theme.accent.opacity(0.45) : Theme.border))
        // More waiting: a second card peeks out under this one.
        .background(alignment: .bottom) {
            if more > 0 {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                    .frame(height: 20).padding(.horizontal, 10).offset(y: 5)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft)
            if let thumb {
                Image(nsImage: thumb).resizable().scaledToFill()
            } else {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accentInk)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if more > 0 {
                Text("+\(more)").font(Theme.sans(9.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                    .background(Theme.accent, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.paper, lineWidth: 1.5))
                    .offset(x: 6, y: -6)
            }
        }
    }
}

struct StagePill: View {
    let text: String
    let icon: String?
    var accent = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.sans(12, .medium))
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(accent ? Theme.accent : Color(nsColor: Theme.stageNS).opacity(0.62), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

/// Script and chat side by side (2026-10-02): with the chat docked, the script can take the
/// camera's half. The preview stays mounted under it (removing its layer deadlocks AVFoundation).
struct ScriptBeside: View {
    @Environment(AppModel.self) var app
    var hub: ChatHub
    var doc: SessionDoc
    @AppStorage("scriptBeside") private var on = false

    var body: some View {
        let _ = Perf.body("ScriptBeside")
        let docked = hub.open && hub.docked && !app.isRecording
        ZStack(alignment: .topLeading) {
            if docked && on {
                ScriptPane(doc: doc, onShowCamera: { on = false })
                    .background(Theme.paper)
                    .transition(.opacity)
            } else if docked && app.preview != nil {
                // Over the camera, the button sits in the card's caption row instead (CameraCard).
                Button { on = true } label: { StagePill(text: "Script beside chat", icon: "doc.text") }
                    .buttonStyle(.plain).padding(12)
                    .help("Show the script in this half, next to the chat")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Theme.motion, value: docked && on)
    }
}

struct ScriptPane: View {
    @Environment(AppModel.self) var app
    @Environment(\.colorScheme) private var scheme
    var doc: SessionDoc
    /// Beside the chat, the bar gets a button that puts the camera back.
    var onShowCamera: (() -> Void)? = nil
    @State private var showHistory = false
    @StateObject private var comments = CommentStore()
    @State private var selection = ""
    @State private var draft: ReviewPlayer.Draft?
    @State private var focused: String?
    @State private var reveal: (quote: String, token: Int)?

    /// The file of the script on screen, as comments name it.
    private var scriptFile: String { doc.activeDraft == "main" ? "script.md" : "variants/\(doc.activeDraft).md" }
    private var scriptComments: [Comment] { comments.on(scriptFile) }

    var body: some View {
        let _ = Perf.body("ScriptPane")
        VStack(spacing: 0) {
            if let shot = app.shot {
                ShotBanner(shot: shot)
            } else {
                DraftBar(doc: doc, showHistory: $showHistory)
                HookPicker(doc: doc)
            }
            if !app.isRecording {
                ScriptCommentList(comments: scriptComments, focused: focused) { c in
                    withAnimation(Theme.motion) { draft = nil; focused = c.id }
                    if let q = c.quote { reveal = (q, (reveal?.token ?? 0) + 1) }
                }
            }
            ZStack(alignment: .topLeading) {
                // A storyboard shot shows only its own lines.
                Prompter(text: app.shot.map { s in .constant(s.say) } ?? Binding(get: { doc.activeText }, set: { doc.activeText = $0 }),
                         contentKey: app.shot.map { "\(doc.url.path)#shot-\($0.id)" } ?? "\(doc.url.path)#\(doc.activeDraft)",
                         fontSize: app.fontSize, scrolling: app.scrolling,
                         speed: app.speed, editable: !app.isRecording, resetToken: app.resetToken,
                         dark: app.lightsDown,
                         highlights: app.isRecording ? [] : scriptComments.filter(\.open).compactMap(\.quote),
                         reveal: reveal,
                         onSelect: { selection = $0 },
                         onComment: startComment)
                if doc.activeText.isEmpty {
                    Text("Paste your script here.\nOr have Takes write script.md into the session folder.")
                        .font(Theme.sans(18)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 40).padding(.top, 40)
                        .allowsHitTesting(false)
                }
                // Reading line: keep your eyes here.
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(app.isRecording ? 0.9 : 0.5))
                        .frame(width: 4, height: app.fontSize * 1.3)
                        .offset(x: 14, y: g.size.height * 0.28)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if !selection.isEmpty && draft == nil && !app.isRecording && !app.scrolling {
                    Button(action: startComment) {
                        StagePill(text: "Comment", icon: "text.bubble", accent: true)
                    }
                    .buttonStyle(.plain)
                    .help("Comment on the selected text, for Takes")
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) { commentCard.padding(12) }
            .animation(Theme.motion, value: selection.isEmpty)
            Rule()
            // The full bar when it fits; half a screen wide, the two options go in a menu
            // (2026-10-02: the bar overflowed beside the chat, under a floating camera pill).
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            .controlSize(.small)
            .font(Theme.sans(12, .medium))
            .tint(Theme.accent)
            .padding(.leading, 12).padding(.vertical, 8)
            // The round chat button sits over the bar's right end, except beside the chat.
            .padding(.trailing, onShowCamera == nil ? 64 : 12)
            .background(Theme.paper)
        }
        .background(Theme.paper)
        // Daylight while you prepare; the prompter goes dark from the countdown on.
        .environment(\.colorScheme, app.lightsDown ? .dark : scheme)
        .animation(.easeInOut(duration: 0.45), value: app.lightsDown)
        .sheet(isPresented: $showHistory) { HistorySheet(doc: doc) }
        .onAppear { comments.load(doc.url) }
        .onChange(of: doc.url) { comments.load(doc.url); draft = nil; focused = nil }
        .onChange(of: doc.activeDraft) { draft = nil; focused = nil }
        .onFilesChanged(in: doc.url) { if !app.isRecording { comments.load(doc.url) } }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if let onShowCamera {
                Button(action: onShowCamera) {
                    Label("Camera", systemImage: "video").labelStyle(.titleAndIcon).padding(.horizontal, 6).frame(height: 28)
                }
                .buttonStyle(PillGhostStyle())
                .help("Put the camera back in this half")
            }
            Button { app.scrolling.toggle() } label: {
                Image(systemName: app.scrolling ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play / pause (Space when not typing, ⌘P)")
            Button { app.resetToken += 1 } label: {
                Image(systemName: "arrow.up.to.line").frame(width: 28, height: 28)
            }
            .buttonStyle(PillGhostStyle())
            .help("Back to top")
            HStack(spacing: 7) {
                Image(systemName: "tortoise").foregroundStyle(Theme.faint)
                Slider(value: Binding(get: { app.speed }, set: { app.speed = $0 }), in: 5...200)
                    .frame(width: compact ? 64 : 100)
                Image(systemName: "hare").foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Theme.hover, in: Capsule())
            .help("Scroll speed")
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                Button { app.fontSize = max(14, app.fontSize - 4) } label: {
                    Text("A").font(Theme.sans(11, .semibold)).frame(width: 26, height: 28)
                }
                .help("Smaller text")
                Rectangle().fill(Theme.border).frame(width: 1, height: 14)
                Button { app.fontSize = min(96, app.fontSize + 4) } label: {
                    Text("A").font(Theme.sans(15, .semibold)).frame(width: 26, height: 28)
                }
                .help("Larger text")
            }
            .buttonStyle(PillGhostStyle())
            .background(Theme.hover, in: Capsule())
            if compact {
                Menu {
                    Toggle("Auto-scroll when recording starts", isOn: Binding(get: { app.autoScroll }, set: { app.autoScroll = $0 }))
                    Toggle("3s countdown", isOn: Binding(get: { app.countdownOn }, set: { app.countdownOn = $0 }))
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Auto-scroll and countdown")
            } else {
                ToggleChip(title: "Auto-scroll", icon: "arrow.down", on: Binding(get: { app.autoScroll }, set: { app.autoScroll = $0 }))
                    .help("Start scrolling when recording starts")
                ToggleChip(title: "Countdown", icon: "timer", on: Binding(get: { app.countdownOn }, set: { app.countdownOn = $0 }))
                    .help("Count down 3, 2, 1 before the take starts")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startComment() {
        guard !selection.isEmpty, !app.isRecording else { return }
        withAnimation(Theme.motion) { focused = nil; draft = ReviewPlayer.Draft(quote: selection, timed: false) }
    }

    @ViewBuilder private var commentCard: some View {
        if let d = draft {
            Composer(draft: Composer.bind($draft, d),
                     onSend: {
                         let text = (draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                         guard !text.isEmpty, let q = draft?.quote else { return }
                         if let c = comments.add(script: scriptFile, quote: q, text: text) {
                             app.show(toast: "Comment \(c.id) saved for Takes")
                         }
                         withAnimation(Theme.motion) { draft = nil }
                     },
                     onCancel: { withAnimation(Theme.motion) { draft = nil } },
                     onArea: {})
        } else if let id = focused, let i = scriptComments.firstIndex(where: { $0.id == id }) {
            let c = scriptComments[i]
            CommentCard(comment: c, number: i + 1,
                        onReply: { comments.reply(id, $0) },
                        onResolve: { comments.setResolved(id, c.open) },
                        onDelete: { comments.delete(id); focused = nil },
                        onClose: { withAnimation(Theme.motion) { focused = nil } },
                        onJump: { app.jump(to: doc.url.appending(path: $0), at: $1) })
        }
    }
}

/// An option you switch on and off with one click: a soft blue chip with a check when on.
struct ToggleChip: View {
    let title: String
    let icon: String
    @Binding var on: Bool
    @State private var hover = false

    var body: some View {
        Button { withAnimation(Theme.motion) { on.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark" : icon).font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(Theme.sans(12, .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.accentInk : hover ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? Theme.accentSoft : hover ? Theme.hover : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
    }
}

/// Script comments above the teleprompter, like the hook list. Click one to show it in the text.
struct ScriptCommentList: View {
    let comments: [Comment]
    let focused: String?
    let pick: (Comment) -> Void
    @AppStorage("scriptCommentsCollapsed") private var collapsed = false

    var body: some View {
        // Only while a comment waits for Claude: all resolved, the bar is noise (2026-10-02).
        if comments.contains(where: \.open) {
            let open = comments.filter(\.open).count
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(Theme.motion) { collapsed.toggle() } } label: {
                    HStack(spacing: 8) {
                        Text("COMMENTS").font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.accent)
                        Text(open > 0 ? "\(open) open for Takes" : "all resolved")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                                row(i + 1, c)
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    .frame(maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Theme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }

    private func row(_ n: Int, _ c: Comment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(Theme.mono(10, .bold)).foregroundStyle(.white)
                .frame(minWidth: 16, minHeight: 16)
                .background(c.open ? Theme.accent : Theme.faint, in: RoundedRectangle(cornerRadius: 3))
            Text(c.text).font(Theme.sans(12.5)).foregroundStyle(c.open ? Theme.ink : Theme.faint)
                .lineLimit(1)
            if let r = c.replies?.last, r.by != "user" {
                Text("↳ \(r.text)").font(Theme.sans(11.5)).foregroundStyle(Theme.accentInk).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(focused == c.id ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(c) }
        .help(c.quote.map { "“\($0)”" } ?? c.text)
    }
}

/// Tabs for the main script and its variants, plus the history button, on the prompter's page.
struct DraftBar: View {
    @Environment(AppModel.self) var app
    var doc: SessionDoc
    @Binding var showHistory: Bool
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let _ = Perf.body("DraftBar")
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("main", "Main", author: "", note: "The main script")
                        ForEach(doc.variants) { v in chip(v.slug, v.name, author: v.author, note: v.note) }
                        Button {
                            doc.newVariant(name: "Variant \(doc.variants.count + 1)", text: doc.activeText)
                        } label: { Image(systemName: "plus").padding(5).foregroundStyle(Theme.muted) }
                        .buttonStyle(.borderless)
                        .help("New variant (copy of what you see)")
                    }
                    .padding(.vertical, 9)
                }
                Button { showHistory = true } label: {
                    Label("\(doc.historyCount)", systemImage: "clock.arrow.circlepath")
                        .font(Theme.mono(11, .medium)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.borderless)
                .help("Script history")
            }
            .padding(.horizontal, 14)
            if doc.activeDraft != "main", let v = doc.variants.first(where: { $0.slug == doc.activeDraft }) {
                HStack(spacing: 8) {
                    Image(systemName: v.author == "claude" ? "sparkles" : "person.fill")
                    Text(v.note.isEmpty ? "Variant\(v.author.isEmpty ? "" : " by \(v.author.capitalized)")" : v.note)
                        .lineLimit(1)
                    Spacer()
                    Button("Use as Main") { doc.promote(v.slug) }
                        .help("This variant becomes the main script. The old main stays in history.")
                }
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .background(Theme.paper)
        .disabled(app.isRecording)
    }

    @ViewBuilder
    private func chip(_ slug: String, _ name: String, author: String, note: String) -> some View {
        let on = doc.activeDraft == slug
        let favorite = doc.meta.favorite == slug
        Group {
            if renaming == slug {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .frame(width: max(80, CGFloat(draftName.count) * 8))
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, f in if !f { commitRename() } }
            } else {
                HStack(spacing: 4) {
                    if favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.accent) }
                    if author == "claude" { Image(systemName: "sparkles").font(.caption2) }
                    Text(name).lineLimit(1)
                }
            }
        }
        .font(Theme.sans(12.5, on ? .semibold : .medium))
        .foregroundStyle(on ? Theme.accentInk : Theme.muted)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(on ? Theme.accentSoft : Theme.hover, in: Capsule())
        .contentShape(Rectangle())
        // Switch on mouse-down of the first click. A plain onTapGesture next to a double-tap waits
        // out the double-click interval before it fires, which made switching feel slow.
        .gesture(TapGesture(count: 2).onEnded { startRename(slug, name) })
        .simultaneousGesture(TapGesture().onEnded { if renaming != slug && doc.activeDraft != slug { doc.activeDraft = slug } })
        .help(slug == "main" ? "Main script" : "\(note.isEmpty ? name : note) · double-click to rename")
        .contextMenu {
            Button(favorite ? "Remove Favorite" : "Mark as Favorite") { doc.toggleFavorite(slug) }
            if slug != "main" {
                Button("Rename…") { startRename(slug, name) }
                Button("Use as Main Script") { doc.promote(slug) }
                Divider()
                Button("Delete Variant", role: .destructive) { doc.deleteVariant(slug) }
            }
        }
    }

    private func startRename(_ slug: String, _ name: String) {
        guard slug != "main" else { return }
        draftName = name
        renaming = slug
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let slug = renaming else { return }
        FieldUndo.drop()
        renaming = nil
        doc.renameVariant(slug, to: draftName)
    }
}

struct HistorySheet: View {
    var doc: SessionDoc

    var body: some View {
        VersionsSheet(title: "Script history", subtitle: doc.meta.title,
                      empty: "Takes saves a version while you edit, before each take, and whenever the chat changes the script.",
                      load: { doc.snapshotDirty(); return doc.versions() },
                      draftName: doc.draftName, restore: doc.restore)
    }
}

/// Saved versions on the left, the picked one on the right, and Restore. For the script and the post.
struct VersionsSheet: View {
    let title: String
    let subtitle: String
    let empty: String
    let load: () -> [ScriptVersion]
    let draftName: (String) -> String
    let restore: (ScriptVersion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [ScriptVersion] = []
    @State private var selected: ScriptVersion.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Theme.sans(17, .bold))
                Text(subtitle).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AccentButtonStyle(kind: .quiet))
            }
            .padding(14)
            Rule()
            if versions.isEmpty {
                ContentUnavailableView("No versions yet", systemImage: "clock", description: Text(empty))
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(versions) { v in
                                SideRow(selected: selected == v.id) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Image(systemName: v.author == "claude" ? "sparkles" : "person.fill")
                                                .font(.caption).foregroundStyle(Theme.accent)
                                            Text(v.note.isEmpty ? "Saved" : v.note)
                                                .font(Theme.sans(13, selected == v.id ? .bold : .medium)).lineLimit(1)
                                        }
                                        Text("\(SessionList.when(v.created)) · \(draftName(v.draft))")
                                            .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                    }
                                }
                                .onTapGesture { selected = v.id }
                            }
                        }
                        .padding(8)
                    }
                    .background(Theme.surface)
                    .frame(width: 280)
                    Rule(vertical: true)
                    ScrollView {
                        Text(versions.first { $0.id == selected }?.text() ?? "")
                            .font(Theme.sans(15))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                }
                Rule()
                HStack {
                    Text("Restoring saves the current text as a version first, so nothing is lost.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Restore This Version") {
                        if let v = versions.first(where: { $0.id == selected }) { restore(v); dismiss() }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .solid))
                    .disabled(selected == nil)
                }
                .padding(14)
            }
        }
        .frame(width: 860, height: 560)
        .presentationBackground(Theme.paper)
        .tint(Theme.accent)
        .font(Theme.body)
        .onAppear {
            versions = load()
            selected = versions.first?.id
        }
    }
}

// MARK: - AppKit bridges

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var fill = false
    var rotation: CGFloat = 0
    /// Rounds the layer itself: SwiftUI's clip does not reach the preview layer.
    var corner: CGFloat = 0
    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.fill = fill; nsView.rotation = rotation
        if nsView.layer?.cornerRadius != corner { nsView.layer?.cornerRadius = corner; nsView.layer?.cornerCurve = .continuous }
    }
}

struct PlayerView: NSViewRepresentable {
    let url: URL
    var onPlayer: (AVPlayer) -> Void = { _ in }
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.showsFrameSteppingButtons = true
        let player = AVPlayer(url: url)
        v.player = player
        onPlayer(player)
        player.play()
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) { nsView.player?.pause() }
}

final class PreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    var fill = false { didSet { preview.videoGravity = fill ? .resizeAspectFill : .resizeAspect } }
    /// Turns an upright iPhone's frames upright, as the take will be.
    var rotation: CGFloat = 0 { didSet { if rotation != oldValue { turn() } } }

    /// On the camera queue: the connection takes the session's lock (see deinit).
    private func turn() {
        let p = preview, angle = rotation
        CameraRecorder.queue.async {
            guard let c = p.connection, c.isVideoRotationAngleSupported(angle), c.videoRotationAngle != angle else { return }
            c.videoRotationAngle = angle
        }
    }

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.stageNS.cgColor
        preview.videoGravity = .resizeAspect
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))  // mirror, like a mirror
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The layer lets go of the session on the camera queue, never on the main thread. A layer freed
    /// on the main thread takes the session's lock; a stopRunning() on the camera queue holds that
    /// lock and waits for the main thread. The app froze when both met (a file opened over the camera).
    deinit {
        let p = preview
        CameraRecorder.queue.async { p.session = nil }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        turn()
    }
}

/// Teleprompter: an NSTextView that doubles as the script editor and scrolls itself.
struct Prompter: NSViewRepresentable {
    @Binding var text: String
    var contentKey: String
    var fontSize: Double
    var scrolling: Bool
    var speed: Double
    var editable: Bool
    var resetToken: Int
    /// Navy page and white type from the countdown on; the app's paper and ink before.
    var dark = false
    /// Quotes of open script comments, highlighted in the text.
    var highlights: [String] = []
    /// Bump with a quote to select and show it.
    var reveal: (quote: String, token: Int)? = nil
    var onSelect: (String) -> Void = { _ in }
    var onComment: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.drawsBackground = true
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.textContainerInset = NSSize(width: 40, height: 36)
        scroll.drawsBackground = true
        scroll.scrollerStyle = .overlay
        tv.string = text
        // The cursor starts at the top: left at the end, the view scrolls down to keep it in sight.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        context.coordinator.scroll = scroll
        apply(to: tv, context: context)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.setScrolling(false, speed: 0)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        let c = context.coordinator
        c.parent = self
        if c.lastKey != contentKey {
            // Switched session or variant: always replace, even while the text view has focus.
            c.lastKey = contentKey
            tv.string = text
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            c.fontApplied = 0
            c.scrollToTop()
        } else if tv.string != text && !c.isEditing {
            // A first script, written by the chat, starts at its first line, not at its end.
            let first = tv.string.isEmpty
            tv.string = text
            c.fontApplied = 0
            if first { tv.setSelectedRange(NSRange(location: 0, length: 0)); c.scrollToTop() }
        }
        apply(to: tv, context: context)
    }

    private func apply(to tv: NSTextView, context: Context) {
        let font = Theme.prompter(fontSize)
        let ink = dark ? NSColor.white : Theme.inkNS
        if context.coordinator.darkApplied != dark {
            context.coordinator.darkApplied = dark
            context.coordinator.fontApplied = 0
            let page = dark ? Theme.stageNS : Theme.paperNS
            tv.backgroundColor = page
            tv.enclosingScrollView?.backgroundColor = page
            tv.selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(dark ? 0.45 : 0.22)]
        }
        if context.coordinator.fontApplied != fontSize {
            context.coordinator.fontApplied = fontSize
            tv.font = font
            let para = NSMutableParagraphStyle()
            para.lineSpacing = fontSize * 0.35
            tv.defaultParagraphStyle = para
            tv.textStorage?.addAttributes([.font: font, .paragraphStyle: para, .foregroundColor: ink],
                                          range: NSRange(location: 0, length: tv.string.utf16.count))
            tv.typingAttributes = [.font: font, .paragraphStyle: para, .foregroundColor: ink]
        }
        tv.isEditable = editable
        let c = context.coordinator
        if c.lastReset != resetToken {
            c.lastReset = resetToken
            c.scrollToTop()
        }
        c.setScrolling(scrolling, speed: speed)
        c.highlight(tv, highlights)
        if let reveal, reveal.token != c.lastReveal {
            c.lastReveal = reveal.token
            let r = (tv.string as NSString).range(of: reveal.quote)
            if r.location != NSNotFound {
                tv.setSelectedRange(r)
                tv.scrollRangeToVisible(r)
                tv.showFindIndicator(for: r)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Prompter
        weak var scroll: NSScrollView?
        var lastReset: Int
        var lastKey: String
        var fontApplied: Double = 0
        var darkApplied: Bool?
        var isEditing = false
        var lastReveal = 0
        private var lit: (String, [String])?
        private var timer: Timer?
        private var speed: Double = 40
        private var offset: CGFloat = 0

        private var stopObserver: NSObjectProtocol?

        init(_ p: Prompter) {
            parent = p; lastReset = p.resetToken; lastKey = p.contentKey
            super.init()
            stopObserver = NotificationCenter.default.addObserver(forName: .takesStopScrolling, object: nil, queue: .main) {
                [weak self] _ in self?.setScrolling(false, speed: self?.speed ?? 40)
            }
        }

        deinit {
            timer?.invalidate()
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            let text = r.length > 0 ? (tv.string as NSString).substring(with: r) : ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.parent.onSelect(trimmed) }
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Comment for Takes…", action: #selector(commentFromMenu), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func commentFromMenu() { parent.onComment() }

        /// Marks the quoted text of open comments. Temporary attributes: never saved, never typed over.
        func highlight(_ tv: NSTextView, _ quotes: [String]) {
            guard lit == nil || lit!.0 != tv.string || lit!.1 != quotes, let lm = tv.layoutManager else { return }
            lit = (tv.string, quotes)
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            for q in quotes where !q.isEmpty {
                let r = (tv.string as NSString).range(of: q)
                guard r.location != NSNotFound else { continue }
                lm.addTemporaryAttributes([.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.22),
                                           .underlineStyle: NSUnderlineStyle.single.rawValue,
                                           .underlineColor: NSColor(Theme.accent)], forCharacterRange: r)
            }
        }

        func scrollToTop() {
            guard let scroll else { return }
            offset = 0
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func setScrolling(_ on: Bool, speed: Double) {
            self.speed = speed
            if on, timer == nil {
                offset = scroll?.contentView.bounds.origin.y ?? 0
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            } else if !on {
                timer?.invalidate()
                timer = nil
            }
        }

        private func tick() {
            // A timer whose view left the window has no one to stop it: stop here.
            guard let scroll, scroll.window != nil, let doc = scroll.documentView else {
                setScrolling(false, speed: speed); return
            }
            let clip = scroll.contentView
            // Follow manual scrolling (trackpad) while playing.
            if abs(clip.bounds.origin.y - offset) > 2 { offset = clip.bounds.origin.y }
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            offset = min(maxY, offset + CGFloat(speed / 60))
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
