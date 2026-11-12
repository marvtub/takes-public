import AppKit
import SwiftUI
import Testing
@testable import Takes

// What a session switch costs, end to end: the click, the new session's views, their layout and
// drawing, in the whole window. A made-up library with the shape of the user's (2026-10-11: 18
// sessions, up to 82 edits, 64 generated images, 12 takes, 290 KB chats). Off by default:
//   TAKES_BENCH=1 ./test.sh --filter ZBenchSwitch
@MainActor
@Suite(.serialized) struct ZBenchSwitch {
    /// takes, edits, thumbnails, generated images, posts, storyboard shots, chat KB.
    static let shapes: [(Int, Int, Int, Int, Int, Int, Int)] = [
        (2, 6, 0, 0, 3, 0, 80), (2, 8, 0, 0, 4, 0, 96), (0, 0, 0, 0, 0, 0, 0), (1, 36, 2, 0, 4, 0, 43),
        (0, 2, 0, 0, 5, 0, 0), (1, 30, 7, 0, 5, 0, 98), (0, 0, 6, 0, 5, 0, 0), (4, 29, 6, 0, 5, 0, 0),
        (3, 82, 14, 0, 5, 1, 228), (1, 22, 0, 0, 5, 0, 159), (9, 21, 0, 2, 4, 20, 205), (0, 0, 18, 0, 4, 16, 183),
        (1, 21, 0, 0, 0, 11, 226), (12, 6, 0, 0, 0, 11, 35), (4, 5, 0, 0, 2, 0, 79), (1, 43, 0, 1, 0, 8, 4),
        (2, 2, 1, 10, 2, 7, 0), (2, 57, 8, 64, 5, 7, 290),
    ]

    static func png(_ url: URL, _ w: Int, _ h: Int) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Real clips when TAKES_BENCH_MEDIA has tall.mp4 and wide.mov (APFS clones, no disk), else empty files.
    static let media = ProcessInfo.processInfo.environment["TAKES_BENCH_MEDIA"].map { URL(fileURLWithPath: $0) }
    static var tall: URL? { media?.appending(path: "tall.mp4") }
    static var wide: URL? { media?.appending(path: "wide.mov") }
    static func video(_ from: URL?, _ to: URL) {
        if let from, (try? FileManager.default.copyItem(at: from, to: to)) != nil { return }
        FileManager.default.createFile(atPath: to.path, contents: Data())
    }

    /// A copy of a real library (APFS clone) to switch through in place of the made-up one:
    /// TAKES_BENCH_LIBRARY=/path. Its biggest project is used. Never point it at ~/Movies/Takes.
    static let real = ProcessInfo.processInfo.environment["TAKES_BENCH_LIBRARY"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    /// The session's first edit (clip-v1.mp4 in the made-up library).
    static func edit(in session: URL) -> URL? {
        let dir = session.appending(path: "edits")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    static func library() -> URL {
        if let real { return real }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "takes-switchbench-\(UUID().uuidString)")
        let project = root.appending(path: "Bench")
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        let words = Array(repeating: "the quick brown fox jumps over a lazy dog and says something", count: 60).joined(separator: " ")
        for (i, s) in shapes.enumerated() {
            let (takes, edits, thumbs, gen, posts, shots, chatKB) = s
            let url = project.appending(path: String(format: "2026-10-%02d-session-%02d", i + 1, i))
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            let doc = SessionDoc(url: url)
            doc.meta = SessionMeta(title: "Session \(i)", createdAt: Date(), named: true)
            try? (words + "\n\n" + words).write(to: url.appending(path: "script.md"), atomically: true, encoding: .utf8)
            var list: [Take] = []
            for n in 0..<takes {
                let file = "take-\(String(format: "%02d", n + 1))-camera.mov"
                video(wide, url.appending(path: file))
                list.append(Take(number: n + 1, kind: .camera, file: file, startedAt: Date(), duration: 42,
                                 script: nil, hook: n % 3 == 0 ? "Hook text \(n)" : nil, shot: nil))
            }
            doc.meta.takes = list
            doc.save()
            try? #"{"hooks":[{"id":"h1","text":"Hook text 0"},{"id":"h2","text":"Hook text 3"}],"chosen":"h1"}"#
                .write(to: url.appending(path: "hooks.json"), atomically: true, encoding: .utf8)
            for (folder, n, ext) in [("edits", edits, "mp4"), ("thumbnails", thumbs, "png"), ("generated", gen, "png")] where n > 0 {
                let dir = url.appending(path: folder)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for k in 0..<n {
                    let f = dir.appending(path: "clip-v\(k + 1).\(ext)")
                    if ext == "png" { png(f, 1920, 1080) } else { video(tall, f) }
                }
            }
            if posts > 0 {
                let dir = url.appending(path: "posts")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for p in PostPlatform.allCases.prefix(min(posts, 4)) {
                    let media = edits > 0 ? "media: edits/clip-v1.mp4\n" : ""
                    try? "---\n\(media)status: ready\nat: 2026-10-12T09:02:00-07:00\n---\n\(words)"
                        .write(to: dir.appending(path: "\(p.rawValue).md"), atomically: true, encoding: .utf8)
                }
            }
            if shots > 0 {
                let dir = url.appending(path: "storyboard")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for k in 0..<shots { png(dir.appending(path: "shot-\(k).png"), 320, 180) }
            }
            if chatKB > 0 {
                var log = ChatLog(conversation: UUID().uuidString, started: true)
                var size = 0
                while size < chatKB * 1000 {
                    let m = ChatMessage(role: log.messages.count % 2 == 0 ? .user : .claude, text: String(words.prefix(600)))
                    log.messages.append(m); size += 700
                }
                try? JSONEncoder().encode(log).write(to: ClaudeChat.file(url))
            }
        }
        return root
    }

    func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    @Test(.enabled(if: bench)) func sessionSwitch() throws {
        let root = Self.library()
        defer { if Self.real == nil { try? FileManager.default.removeItem(at: root) } }
        let d = UserDefaults.standard
        let oldTab = d.string(forKey: "rightTab")
        defer { d.set(oldTab, forKey: "rightTab") }
        let app = AppModel()
        app.library.setRoot(root)
        app.library.selectedProject = (Self.real == nil ? app.library.projects.first
            : app.library.projects.max { (app.library.grouped[$0.url]?.count ?? 0) < (app.library.grouped[$1.url]?.count ?? 0) })?.url
        let urls = app.library.sessions.map(\.url)
        // The chat beside the session, as the user keeps it (TAKES_BENCH_CHAT=0 closes it).
        let chatOpen = ProcessInfo.processInfo.environment["TAKES_BENCH_CHAT"] != "0"
        app.chats.docked = chatOpen
        app.chats.open = chatOpen
        try #require(Self.real != nil || urls.count == Self.shapes.count)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).frame(width: 1400, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            for _ in 0..<3 {
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        settle()
        var report: [String] = []
        defer {
            var all = d.dictionary(forKey: SessionView.key) ?? [:]
            for key in all.keys where key.hasPrefix(root.standardizedFileURL.path) { all[key] = nil }
            d.set(all, forKey: SessionView.key)
        }
        let only = ProcessInfo.processInfo.environment["TAKES_BENCH_ONLY"]
        for tab in ["script", "assets", "post", "remembered"] where only == nil || only == tab {
            if tab == "remembered" {
                // Each session opens on its own tab, as in the app: Assets with an edit in the player,
                // the post, or the script.
                for (i, u) in urls.enumerated() {
                    let edit = Self.edit(in: u)
                    // TAKES_BENCH_COVER=1: every session opens on its post (a full-window tab).
                    let pick = ProcessInfo.processInfo.environment["TAKES_BENCH_COVER"] == "1" ? 1 : i % 3
                    switch pick {
                    case 0 where edit != nil: SessionView.write(u, mode: .assets, file: edit, time: 0)
                    case 1: SessionView.write(u, mode: .post, file: nil, time: nil)
                    default: SessionView.write(u, mode: .record, file: nil, time: nil)
                    }
                }
            } else {
                d.set(tab, forKey: "rightTab")
            }
            app.library.selectedSessions = []
            settle()
            var times: [Double] = [], opens: [Double] = [], walls: [Double] = []
            let names = ["TakeRow", "AssetTile", "TakesList", "SessionHeader", "DetailView", "ChatRows", "PostPane", "ScriptPane"]
            let before = names.map { Perf.count($0) }
            for round in 0..<(Int(ProcessInfo.processInfo.environment["TAKES_BENCH_ROUNDS"] ?? "") ?? 3) {
                for u in urls {
                    // The main thread's own CPU time: other work on the Mac barely moves it.
                    let t = cpu(), w = CACurrentMediaTime()
                    app.library.selectedSessions = [u]
                    let o = cpu()
                    settle()
                    if round > 0 { times.append((cpu() - t) * 1000); opens.append((o - t) * 1000)
                        walls.append((CACurrentMediaTime() - w) * 1000) }
                }
            }
            let bodies = zip(names, before).map { "\($0.0) \(Perf.count($0.0) - $0.1)" }.joined(separator: ", ")
            report.append(String(format: "BENCH   %@ open (sync) mean %.1f ms; bodies: %@",
                                 tab, opens.reduce(0, +) / Double(opens.count), bodies))
            let s = times.sorted()
            let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count) * q))] }
            report.append(String(format: "BENCH switch %@ (main thread CPU): n %d, p50 %.1f ms, p90 %.1f, max %.1f, mean %.1f",
                                 tab, s.count, p(0.5), p(0.9), s.last ?? 0, s.reduce(0, +) / Double(s.count)))
            let ws = walls.sorted()
            let wp = { (q: Double) in ws[min(ws.count - 1, Int(Double(ws.count) * q))] }
            report.append(String(format: "BENCH switch %@ (wall): n %d, p50 %.1f ms, p95 %.1f, max %.1f",
                                 tab, ws.count, wp(0.5), wp(0.95), ws.last ?? 0))
        }
        report.forEach { print($0) }
    }

    /// Tab switches inside a session, each tab opened fresh (a new session keeps no tabs), and a
    /// click on an edit in Assets (the stage's ReviewPlayer). Main-thread CPU per switch, until
    /// drawn. TAKES_BENCH_TABS limits the tabs ("assets,post").
    ///   TAKES_BENCH=1 swift test --filter ZBenchSwitch/tabSwitch
    @Test(.enabled(if: bench)) func tabSwitch() throws {
        let root = Self.library()
        defer { if Self.real == nil { try? FileManager.default.removeItem(at: root) } }
        let d = UserDefaults.standard
        let oldTab = d.string(forKey: "rightTab"), oldPlatform = d.string(forKey: "postPlatform")
        defer { d.set(oldTab, forKey: "rightTab"); d.set(oldPlatform, forKey: "postPlatform") }
        let app = AppModel()
        app.library.setRoot(root)
        app.library.selectedProject = (Self.real == nil ? app.library.projects.first
            : app.library.projects.max { (app.library.grouped[$0.url]?.count ?? 0) < (app.library.grouped[$1.url]?.count ?? 0) })?.url
        let urls = app.library.sessions.map(\.url)
        let chatOpen = ProcessInfo.processInfo.environment["TAKES_BENCH_CHAT"] == "1"
        app.chats.docked = chatOpen
        app.chats.open = chatOpen
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).frame(width: 1400, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            for _ in 0..<3 {
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        defer {
            var all = d.dictionary(forKey: SessionView.key) ?? [:]
            for key in all.keys where key.hasPrefix(root.standardizedFileURL.path) { all[key] = nil }
            d.set(all, forKey: SessionView.key)
        }
        let env = ProcessInfo.processInfo.environment
        let tabs = (env["TAKES_BENCH_TABS"] ?? "assets,post:linkedin,post:vertical,post:youtube,storyboard,write,script,video")
            .split(separator: ",").map(String.init)
        var times: [String: [Double]] = [:], walls: [String: [Double]] = [:]
        for round in 0..<(Int(env["TAKES_BENCH_ROUNDS"] ?? "") ?? 3) {
            for u in urls {
                app.preview = nil
                d.set("script", forKey: "rightTab")
                app.library.selectedSessions = [u]
                settle()
                for tab in tabs {
                    if tab == "record-later" {
                        // The session opens on a full-window tab; a second later, back to Record.
                        d.set("script", forKey: "rightTab"); app.library.selectedSessions = []; settle()
                        d.set("post", forKey: "rightTab"); app.library.selectedSessions = [u]; settle()
                        RunLoop.main.run(until: Date().addingTimeInterval(1)); settle()
                        let t = cpu(), w = CACurrentMediaTime()
                        d.set("script", forKey: "rightTab")
                        settle()
                        if round > 0 { times[tab, default: []].append((cpu() - t) * 1000)
                            walls[tab, default: []].append((CACurrentMediaTime() - w) * 1000) }
                        continue
                    }
                    if tab == "video" {
                        // A click on an edit in Assets: it plays on the stage.
                        guard let edit = Self.edit(in: u) else { continue }
                        d.set("assets", forKey: "rightTab"); settle()
                        let t = cpu(), w = CACurrentMediaTime()
                        app.preview = edit
                        settle()
                        if round > 0 { times[tab, default: []].append((cpu() - t) * 1000)
                            walls[tab, default: []].append((CACurrentMediaTime() - w) * 1000) }
                        app.preview = nil; settle()
                        continue
                    }
                    let parts = tab.split(separator: ":").map(String.init)
                    if parts.count > 1 { d.set(parts[1], forKey: "postPlatform") }
                    // Back to Record first, so each post side opens as a new pane.
                    if parts.count > 1 { d.set("script", forKey: "rightTab"); app.library.selectedSessions = []; settle()
                        app.library.selectedSessions = [u]; settle() }
                    let t = cpu(), w = CACurrentMediaTime()
                    d.set(parts[0], forKey: "rightTab")
                    settle()
                    if round > 0 { times[tab, default: []].append((cpu() - t) * 1000)
                        walls[tab, default: []].append((CACurrentMediaTime() - w) * 1000) }
                }
            }
        }
        for tab in tabs {
            let s = (times[tab] ?? []).sorted()
            guard !s.isEmpty else { continue }
            let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count) * q))] }
            print(String(format: "BENCH tab %@ (main thread CPU): n %d, p50 %.1f ms, p95 %.1f, max %.1f, mean %.1f",
                         tab, s.count, p(0.5), p(0.95), s.last ?? 0, s.reduce(0, +) / Double(s.count)))
            let ws = (walls[tab] ?? []).sorted()
            let wp = { (q: Double) in ws[min(ws.count - 1, Int(Double(ws.count) * q))] }
            print(String(format: "BENCH tab %@ (wall): n %d, p50 %.1f ms, p95 %.1f, max %.1f",
                         tab, ws.count, wp(0.5), wp(0.95), ws.last ?? 0))
        }
    }

    /// What each part of a session costs to build, lay out and draw on its own, in a new host:
    /// tells which part of a switch is worth a fix. Main-thread CPU, median and p95 over sessions.
    ///   TAKES_BENCH=1 swift test --filter ZBenchSwitch/parts
    @Test(.enabled(if: bench)) func parts() throws {
        let root = Self.library()
        defer { if Self.real == nil { try? FileManager.default.removeItem(at: root) } }
        let d = UserDefaults.standard
        let oldPlatform = d.string(forKey: "postPlatform")
        defer { d.set(oldPlatform, forKey: "postPlatform") }
        let app = AppModel()
        app.library.setRoot(root)
        app.library.selectedProject = (Self.real == nil ? app.library.projects.first
            : app.library.projects.max { (app.library.grouped[$0.url]?.count ?? 0) < (app.library.grouped[$1.url]?.count ?? 0) })?.url
        let docs = app.library.sessions.map { SessionDoc(url: $0.url) }
        func time(_ size: CGSize, _ make: () -> AnyView) -> Double {
            let t = cpu()
            let host = NSHostingView(rootView: make().environment(app).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<3 { RunLoop.main.run(until: Date()); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            let ms = (cpu() - t) * 1000
            window.contentView = nil
            return ms
        }
        let wide = CGSize(width: 1100, height: 860), column = CGSize(width: 420, height: 860)
        var parts: [(String, CGSize, (SessionDoc) -> AnyView)] = [
            ("sidebar", CGSize(width: 260, height: 860), { _ in AnyView(SessionList(library: app.library, queue: app.posts)) }),
            ("header", CGSize(width: 1100, height: 52), { AnyView(SessionHeader(doc: $0)) }),
            ("assets wide", wide, { AnyView(AssetsPane(doc: $0, wide: true)) }),
            ("assets column", column, { AnyView(AssetsPane(doc: $0)) }),
            ("script", column, { AnyView(ScriptPane(doc: $0)) }),
            ("takes", column, { AnyView(TakesList(doc: $0)) }),
            ("write", wide, { AnyView(ScriptPage(doc: $0)) }),
            ("storyboard", wide, { AnyView(StoryboardPane(doc: $0)) }),
        ]
        for p in ["linkedin", "x", "youtube", "vertical"] {
            parts.append(("post \(p)", wide, { doc in d.set(p, forKey: "postPlatform"); return AnyView(PostPane(doc: doc)) }))
        }
        parts.append(("review player", CGSize(width: 900, height: 700), { doc in
            AnyView(ReviewPlayer(url: Self.edit(in: doc.url)!, session: doc.url)) }))
        let rounds = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_ROUNDS"] ?? "") ?? 3
        let only = ProcessInfo.processInfo.environment["TAKES_BENCH_PART"]
        for (name, size, make) in parts where only == nil || name.hasPrefix(only!) {
            var s: [Double] = []
            for round in 0..<rounds {
                for doc in docs {
                    if name == "review player", Self.edit(in: doc.url) == nil { continue }
                    let ms = time(size) { make(doc) }
                    if round > 0 { s.append(ms) }
                }
            }
            s.sort()
            guard !s.isEmpty else { continue }
            print(String(format: "BENCH part %@: n %d, p50 %.1f ms, p95 %.1f, max %.1f", name, s.count,
                         s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last ?? 0))
        }
    }

    /// The sidebar alone while the selection moves from session to session (each project's
    /// sessions shown): what a switch costs the session list. Main-thread CPU per click.
    ///   TAKES_BENCH=1 swift test --filter ZBenchSwitch/sidebarSelect
    @Test(.enabled(if: bench)) func sidebarSelect() throws {
        let root = Self.library()
        defer { if Self.real == nil { try? FileManager.default.removeItem(at: root) } }
        let app = AppModel()
        app.library.setRoot(root)
        let urls = app.library.grouped.values.joined().filter { !$0.archived && !$0.done }.map(\.url)
        let host = NSHostingView(rootView: AnyView(SessionList(library: app.library, queue: app.posts)
            .environment(app).frame(width: 260, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 260, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { for _ in 0..<3 { RunLoop.main.run(until: Date()); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() } }
        settle()
        var s: [Double] = []
        let before = Perf.count("SessionList")
        for round in 0..<(Int(ProcessInfo.processInfo.environment["TAKES_BENCH_ROUNDS"] ?? "") ?? 3) {
            for u in urls {
                let t = cpu()
                app.library.selectedSessions = [u]
                settle()
                if round > 0 { s.append((cpu() - t) * 1000) }
            }
        }
        s.sort()
        print(String(format: "BENCH sidebar select (%d sessions): n %d, p50 %.2f ms, p95 %.2f, max %.2f; SessionList bodies %d",
                     urls.count, s.count, s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last ?? 0,
                     Perf.count("SessionList") - before))
    }

    /// Scrolling the long lists: the Assets page with every section open (the session with the
    /// most files) and the sidebar. Main-thread CPU per 40 pt step, laid out and drawn.
    ///   TAKES_BENCH=1 swift test --filter ZBenchSwitch/scrolling
    @Test(.enabled(if: bench)) func scrolling() throws {
        let root = Self.library()
        defer { if Self.real == nil { try? FileManager.default.removeItem(at: root) } }
        let app = AppModel()
        app.library.setRoot(root)
        let all = app.library.grouped.values.joined().map(\.url)
        let store = AssetStore()
        let biggest = try #require(all.max { a, b in
            store.scan(SessionDoc(url: a)); let n = store.assets.count
            store.scan(SessionDoc(url: b)); return n < store.assets.count
        })
        let doc = SessionDoc(url: biggest)
        store.scan(doc)
        for (name, size, view) in [
            ("assets (\(store.assets.count) files)", CGSize(width: 1100, height: 860), AnyView(AssetsPane(doc: doc, wide: true, openAll: true))),
            ("sidebar (\(all.count) sessions)", CGSize(width: 260, height: 600), AnyView(SessionList(library: app.library, queue: app.posts))),
        ] {
            let host = NSHostingView(rootView: view.environment(app).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            func settle() { for _ in 0..<2 { RunLoop.main.run(until: Date()); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() } }
            for _ in 0..<20 { settle(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
            guard let scroll = scrolls(host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                  let docView = scroll.documentView else { continue }
            var s: [Double] = []
            for pass in 0..<3 {
                var y: CGFloat = 0
                docView.scroll(.zero); settle()
                while y + size.height < docView.frame.height {
                    y += 40
                    let t = cpu()
                    docView.scroll(NSPoint(x: 0, y: y))
                    settle()
                    if pass > 0 { s.append((cpu() - t) * 1000) }
                }
            }
            s.sort()
            guard !s.isEmpty else { print("BENCH scroll \(name): no scroll"); continue }
            print(String(format: "BENCH scroll %@: %.0f pt, n %d, p50 %.2f ms, p95 %.2f, max %.2f", name, docView.frame.height, s.count,
                         s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last ?? 0))
            window.contentView = nil
        }
    }
}
