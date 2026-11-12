import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Takes

// Pictures of views on the real library, for design work without restarting Takes. Off by default:
//   TAKES_SNAP=/tmp/snaps swift test --filter Snap
let snapDir = ProcessInfo.processInfo.environment["TAKES_SNAP"]

@MainActor
@Suite struct Snap {
    func shoot(_ name: String, _ view: some View, size: CGSize, dark: Bool = false) {
        let (window, host) = open(view, size: size, dark: dark)
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
        save(name, window, host)
    }

    /// The same, for a view whose data loads off the main actor (a detached task, a video's still
    /// frame): it sleeps `settle` seconds, so those tasks can come back to the main actor first.
    func shoot(_ name: String, _ view: some View, size: CGSize, dark: Bool = false, settle: Double) async {
        let (window, host) = open(view, size: size, dark: dark)
        let end = Date().addingTimeInterval(settle)
        while Date() < end { try? await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        save(name, window, host)
    }

    private func open(_ view: some View, size: CGSize, dark: Bool) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        return (window, host)
    }

    private func save(_ name: String, _ window: NSWindow, _ host: NSView) {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        let url = URL(fileURLWithPath: snapDir!).appending(path: "\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// As ContentView places it: under the traffic lights, on the canvas, a line on its right.
    func frame(_ app: AppModel) -> some View {
        HStack(spacing: 0) {
            Sidebar(library: app.library).padding(.top, 28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .environment(app)
    }

    /// The Sound page: the library only, Use asks the chat (2026-10-09).
    @Test(.enabled(if: snapDir != nil)) func sounds() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        guard let s = app.library.sessions.first else { return }
        let doc = SessionDoc(url: s.url)
        shoot("sounds-wide-dark", SoundsPane(doc: doc, wide: true).environment(app), size: CGSize(width: 1000, height: 700), dark: true)
        shoot("sounds-column", SoundsPane(doc: doc).environment(app), size: CGSize(width: 420, height: 700))
    }

    /// The Made tab (make_music, 2026-11-03): empty, and with two songs, light and dark.
    @Test(.enabled(if: snapDir != nil)) func soundsMade() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = root.appending(path: "Proj/2026-11-03-launch")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try Data(#"{"title":"Launch","createdAt":"2026-11-03T00:00:00Z","named":true,"takes":[]}"#.utf8)
            .write(to: s.appending(path: "session.json"))
        let audio = SoundLib.dir(root: root)
        for f in ["Music/26428_Chasing the Truth.mp3", "SFX/1_Whoosh.mp3"] {
            let u = audio.appending(path: f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: u)
        }
        let app = AppModel()
        app.library.setRoot(root)
        let doc = SessionDoc(url: s)
        shoot("sounds-made-empty", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 520))
        for f in ["Made/Moonlight piano over soft D&B v1.mp3", "Made/Heroic strings over soft D&B v1.mp3"] {
            let u = audio.appending(path: f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: u)
        }
        shoot("sounds-made", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 520))
        shoot("sounds-made-dark", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 520), dark: true)
        shoot("sounds-made-column", SoundsPane(doc: doc, startOn: "Made").environment(app), size: CGSize(width: 420, height: 560))
        // Tags (2026-11-08): the filter row and the tags on each row, light and dark; the editor.
        SoundTags.save(["Made/Moonlight piano over soft D&B v1.mp3": ["Education", "Calm"],
                        "Made/Heroic strings over soft D&B v1.mp3": ["Education"]], to: audio)
        shoot("sounds-tags", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 520))
        shoot("sounds-tags-dark", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 520), dark: true)
        shoot("sounds-tags-column", SoundsPane(doc: doc, startOn: "Made").environment(app), size: CGSize(width: 420, height: 560))
        let editor = SoundTagEditor(title: "Moonlight piano over soft D&B v1", tags: ["Education", "Calm"],
                                    suggestions: ["Education", "Calm", "Whoosh", "Upbeat"], onChange: { _ in })
            .background(Theme.paper)
        shoot("sounds-tag-editor", editor.environment(app), size: CGSize(width: 260, height: 190))
        shoot("sounds-tag-editor-dark", editor.environment(app), size: CGSize(width: 260, height: 190), dark: true)
    }

    @Test(.enabled(if: snapDir != nil)) func sidebar() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        if let s = app.library.sessions.first(where: { $0.title.contains("Bookkeeping") }) { app.library.select(s.url) }
        shoot("sidebar", frame(app), size: CGSize(width: 290, height: 900))
        shoot("sidebar-dark", frame(app), size: CGSize(width: 290, height: 900), dark: true)
    }

    /// Settings with two archived sessions, in a library of its own.
    @Test(.enabled(if: snapDir != nil)) func settings() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        app.library.setRoot(root)
        let p = try #require(app.library.createProject("Inbox"))
        var made: Set<URL> = []
        for t in ["Phone take from the beach", "Old hook test"] {
            let d = try #require(app.library.createSession(in: p))
            d.meta.title = t; d.save(); made.insert(d.url)
        }
        _ = app.library.createSession(in: p)
        app.library.setArchived(made, true)
        UserDefaults.standard.set("archived", forKey: "settingsPage")
        shoot("settings", SettingsView(library: app.library).environment(app), size: CGSize(width: 760, height: 560))
        UserDefaults.standard.set("appearance", forKey: "settingsPage")
        shoot("sidebar-archived", frame(app), size: CGSize(width: 290, height: 500))
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
    }

    /// The article as the blog shows it (the web view's own snapshot), where the user also writes.
    /// TAKES_SNAP_ARTICLE=<a .mdx> renders that post; else a sample with every component.
    @Test(.enabled(if: snapDir != nil)) func article() async throws {
        var md = ArticleTests.sample
        var c = PostFile.Content(text: md)
        if let path = ProcessInfo.processInfo.environment["TAKES_SNAP_ARTICLE"],
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let (fields, body) = FrontMatter.parse(raw)
            md = body
            c = PostFile.Content(text: body, meta: fields.filter { !$0.value.isEmpty })
        } else {
            c.title = "How I Ship Without Reading Code"
            c.meta["description"] = "One PR, every time. The agent writes, the checks read."
            c.meta["category"] = "Tech"
        }
        let session = FileManager.default.temporaryDirectory
        let size = CGSize(width: 900, height: 2400)
        let config = WKWebViewConfiguration()
        let files = SessionFiles()
        files.session = session
        config.setURLSchemeHandler(files, forURLScheme: "takes")
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString(ArticlePage.html.replacingOccurrences(of: "post('ready', '');", with: ""), baseURL: URL(string: "takes://session/"))
        for _ in 0..<20 where web.isLoading { try await Task.sleep(for: .milliseconds(150)) }
        let head = ArticleHead(c)
        _ = try? await web.evaluateJavaScript("takes.render(\(ArticleView.Coordinator.blocks(md)), \(head.json)); "
                                             + "takes.mark(['the checks read', 'worktrees']); document.querySelector('details').open = true; 1")
        try await Task.sleep(for: .milliseconds(900))
        let image = try await web.takeSnapshot(configuration: nil)
        window.orderOut(nil)
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapDir!).appending(path: "article.png"))
        }
    }

    /// The Record tab as you open it: the whole window, camera paused.
    @Test(.enabled(if: snapDir != nil)) func record() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        if let s = app.library.sessions.first(where: { $0.title.contains("Pay For AI") }) { app.library.select(s.url) }
        UserDefaults.standard.set("script", forKey: "rightTab")
        let window = ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body)
        shoot("record", window, size: CGSize(width: 1440, height: 860))
        shoot("record-dark", window, size: CGSize(width: 1440, height: 860), dark: true)
        app.lightsDownForSnapshot = true
        let rolling = ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body)
        shoot("record-lights-down", rolling, size: CGSize(width: 1440, height: 860))
        app.lightsDownForSnapshot = false
    }

    /// The storyboard strip's time ruler, under stand-in cards (the real strip loads too late).
    @Test(.enabled(if: snapDir != nil)) func about() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        let v = AboutView().environment(app)
        shoot("about", v, size: CGSize(width: 440, height: 700))
        shoot("about-dark", v, size: CGSize(width: 440, height: 700), dark: true)
    }

    @Test(.enabled(if: snapDir != nil)) func reviewEmpty() {
        for finding in [false, true] {
            let v = ReviewEmpty(finding: finding, drafts: 10, posted: 7, run: {}, watch: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paper)
            let name = finding ? "review-empty-finding" : "review-empty"
            shoot(name, v, size: CGSize(width: 950, height: 640))
            shoot(name + "-dark", v, size: CGSize(width: 950, height: 640), dark: true)
        }
        let v = BoardEmpty(badge: "paperplane.fill", title: "Nothing approved yet",
                           text: "Comments you approve wait here. Post now posts them in a background Chrome tab, one to two minutes apart.",
                           action: ("Review 3 drafts", "arrow.left", {}))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.paper)
        shoot("approved-empty-dark", v, size: CGSize(width: 950, height: 640), dark: true)
        shoot("approved-empty", v, size: CGSize(width: 950, height: 640))
    }

    @Test(.enabled(if: snapDir != nil)) func storyboardRuler() {
        let lengths: [[Double]] = [[4, 6], [5, 8, 7, 6, 9, 5], [8, 8]]
        var t = 0.0
        let starts = lengths.map { sec in sec.map { l in defer { t += l }; return t } }
        let row = HStack(alignment: .bottom, spacing: 18) {
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    Text(["HOOK", "MAIN", "END"][i]).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.faint)
                    HStack(spacing: 6) {
                        ForEach(0..<lengths[i].count, id: \.self) { j in
                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: 8).fill(Theme.raised).frame(width: 76, height: 95)
                                ShotTime(start: starts[i][j], length: lengths[i][j], on: i == 1 && j == 1,
                                         gap: i == 2 && j == 1 ? 0 : j == lengths[i].count - 1 ? 18 : 6,
                                         end: i == 2 && j == 1 ? t : nil)
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.canvas)
        shoot("storyboard-ruler-dark", row, size: CGSize(width: 1000, height: 200), dark: true)
        shoot("storyboard-ruler", row, size: CGSize(width: 1000, height: 200))
    }

    @Test(.enabled(if: snapDir != nil)) func vertical() {
        let video = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/Takes/Demo/2026-01-01-sample/edits/sample-v1.mp4")
        func card(_ media: URL?) -> some View {
            VerticalCard(text: .constant("Start with the hook: the feeds show one or two lines."), title: "", saveTitle: { _ in },
                         places: VerticalPlace.allCases, setPlaces: { _ in }, media: media, phoneHeight: 600,
                         expanded: .constant(false), highlights: [], reveal: nil, focusToken: 0,
                         onSelect: { _ in }, onComment: {}, onExpand: {})
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        }
        shoot("vertical-empty", card(nil), size: CGSize(width: 1200, height: 780))
        shoot("vertical-empty-dark", card(nil), size: CGSize(width: 1200, height: 780), dark: true)
        shoot("vertical-phone", card(video), size: CGSize(width: 1200, height: 780))
    }

    /// Settings › Appearance, then the whole window in a few palettes.
    @Test(.enabled(if: snapDir != nil)) func appearance() {
        let look = Look.shared
        let saved = (look.mode, look.palette, look.accent)
        defer { look.mode = saved.0; look.palette = saved.1; look.accent = saved.2 }
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        UserDefaults.standard.set("appearance", forKey: "settingsPage")
        look.mode = .system; look.palette = .takes; look.accent = nil
        let settings = SettingsView(library: app.library).environment(app).font(Theme.body)
        shoot("appearance", settings, size: CGSize(width: 760, height: 560))
        shoot("appearance-dark", settings, size: CGSize(width: 760, height: 560), dark: true)
        let window = ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body)
        for (p, dark) in [(ThemePalette.sand, false), (.graphite, true), (.forest, false), (.plum, true)] {
            look.palette = p
            shoot("look-\(p.rawValue)\(dark ? "-dark" : "")", window, size: CGSize(width: 1440, height: 860), dark: dark)
        }
    }

    /// Takes, dark, with the chat open: the chat sits one step lighter than the page.
    @Test(.enabled(if: snapDir != nil)) func chatRaised() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        app.chats.open = true
        let window = ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body)
        shoot("chat-dark", window, size: CGSize(width: 1440, height: 860), dark: true)
        shoot("chat-light", window, size: CGSize(width: 1440, height: 860))
        app.chats.open = false
    }

    /// The Mac controls the iPhone copies (2026-10-09, PhoneParity.swift): the More panel, the
    /// script's draft bar, the history sheet, the voice panel and the schedule panel, on the real
    /// library's newest session with takes. Look at these before changing the phone's version.
    @Test(.enabled(if: snapDir != nil)) func phoneRefs() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        guard let s = app.library.sessions.first(where: { $0.takeCount > 0 }) else { return }
        app.library.select(s.url)
        guard let doc = app.library.current else { return }
        func paper(_ v: some View) -> some View { v.background(Theme.paper).environment(app).font(Theme.body).tint(Theme.accent) }
        // The More menu is a Takes menu since 2026-10-11 (SessionMenu); one shot with "Move to project" open.
        func more(open group: String? = nil) -> some View {
            let st = MenuState()
            if let group { st.open.insert(group) }
            return TakesMenuList(content: { SessionMenu.rows(app: app, urls: [doc.url]) }, state: st, width: 260)
        }
        shoot("ref-more", paper(more(open: "g:Move to project")), size: CGSize(width: 260, height: 420))
        shoot("ref-draftbar", paper(DraftBar(doc: doc, showHistory: .constant(false))), size: CGSize(width: 700, height: 90))
        shoot("ref-history", paper(HistorySheet(doc: doc)), size: CGSize(width: 860, height: 560))
        if let t = doc.meta.takes.first {
            let mix = VoiceMix(take: t, session: doc.url)
            mix.reload()
            shoot("ref-voice", paper(VoicePanel(voice: mix)), size: CGSize(width: 320, height: 380))
        }
        let post = PostStore(.linkedin)
        post.load(doc.url)
        if let c = post.content {
            shoot("ref-schedule", paper(SchedulePanel(content: c, post: post, close: {})), size: CGSize(width: 320, height: 560))
        }
        for dark in [false, true] {
            shoot("ref-more\(dark ? "-dark" : "")", paper(more()), size: CGSize(width: 260, height: 380), dark: dark)
        }
    }
}
