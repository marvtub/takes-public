import Foundation
import Testing
@testable import Takes

// Speed checks on the real library (~/Movies/Takes). Off by default; run them with
//   TAKES_BENCH=1 swift test --filter ZBench
// Debug-build numbers: compare them with each other, not with the release app.
let bench = ProcessInfo.processInfo.environment["TAKES_BENCH"] != nil

@MainActor
@Suite struct ZBench {
    @Test(.enabled(if: bench)) func sessionOpenCosts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        let fm = FileManager.default
        var rows: [(Double, String)] = []
        for p in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] where !p.lastPathComponent.hasPrefix("_") {
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where fm.fileExists(atPath: s.appending(path: "session.json").path) {
                var t = CFAbsoluteTimeGetCurrent()
                let doc = SessionDoc(url: s)
                let d1 = (CFAbsoluteTimeGetCurrent() - t) * 1000
                t = CFAbsoluteTimeGetCurrent()
                _ = ClaudeChat(session: s)
                let d2 = (CFAbsoluteTimeGetCurrent() - t) * 1000
                t = CFAbsoluteTimeGetCurrent()
                let store = AssetStore(); store.scan(doc)
                let d3 = (CFAbsoluteTimeGetCurrent() - t) * 1000
                t = CFAbsoluteTimeGetCurrent()
                _ = CommentStore.read(s)
                let d4 = (CFAbsoluteTimeGetCurrent() - t) * 1000
                rows.append((d1 + d2 + d3 + d4, String(format: "doc %.1f chat %.1f assets %.1f(%d) comments %.1f  %@", d1, d2, d3, store.assets.count, d4, s.lastPathComponent)))
            }
        }
        for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(12) { print(String(format: "BENCH %.1f ms ", r.0) + r.1) }
    }
}

import AppKit
import SwiftUI

@MainActor
@Suite struct ZBenchViews {
    @Test(.enabled(if: bench)) func chatLayoutCost() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        let fm = FileManager.default
        var best: (Int, URL)? = nil
        for p in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                let f = s.appending(path: ".claude-chat.json")
                if let sz = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int, sz > (best?.0 ?? 0) { best = (sz, s) }
            }
        }
        guard let s = best?.1 else { return }
        let chat = ClaudeChat(session: s)
        let app = AppModel()
        let texts = chat.messages.filter { $0.role == .claude }.map(\.text)
        let view = ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(Array(texts.enumerated()), id: \.offset) { _, t in ChatReply(text: t) } } }.frame(width: 520, height: 900).environment(app)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        var t = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        let first = (CFAbsoluteTimeGetCurrent() - t) * 1000
        t = CFAbsoluteTimeGetCurrent()
        host.rootView = AnyView(ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(Array(texts.enumerated()), id: \.offset) { _, t in ChatReply(text: t) } } }.frame(width: 520, height: 900).environment(app))
        host.layoutSubtreeIfNeeded()
        let again = (CFAbsoluteTimeGetCurrent() - t) * 1000
        let h2 = NSHostingView(rootView: AnyView(ScrollView { ChatRows(chat: chat) }.frame(width: 520, height: 900).environment(app)))
        h2.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        t = CFAbsoluteTimeGetCurrent()
        h2.layoutSubtreeIfNeeded()
        print(String(format: "BENCH ChatRows (limited) first layout %.1f ms", (CFAbsoluteTimeGetCurrent() - t) * 1000))
        print(String(format: "BENCH chat %d msgs (%d claude, %d chars): first layout %.1f ms, update %.1f ms", chat.messages.count, texts.count, texts.reduce(0) { $0 + $1.count }, first, again))
    }
}

@MainActor
@Suite struct ZBenchPanes {
    func time(_ name: String, _ app: AppModel, _ v: some View) {
        let host = NSHostingView(rootView: AnyView(v.frame(width: 1100, height: 800).environment(app)))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let t = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        let a = (CFAbsoluteTimeGetCurrent() - t) * 1000
        let t2 = CFAbsoluteTimeGetCurrent()
        host.rootView = AnyView(v.frame(width: 1100, height: 801).environment(app))
        host.layoutSubtreeIfNeeded()
        print(String(format: "BENCH pane %@ build %.1f ms, relayout %.1f ms", name, a, (CFAbsoluteTimeGetCurrent() - t2) * 1000))
    }

    @Test(.enabled(if: bench)) func paneCosts() {
        let app = AppModel()
        let s = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes/Acme").path
        let session = (try? FileManager.default.contentsOfDirectory(atPath: s))?.first { $0.contains("how-i-make-my-videos") }
        let doc = SessionDoc(url: URL(fileURLWithPath: s).appending(path: session ?? ""))
        time("warmup", app, Text("x"))
        time("script", app, VStack { ScriptPane(doc: doc); TakesList(doc: doc) })
        time("assets", app, AssetsPane(doc: doc, wide: true))
        time("sounds", app, SoundsPane(doc: doc, bed: app.bed, wide: true))
        time("post", app, PostPane(doc: doc))
        time("header", app, SessionHeader(doc: doc))
    }
}

/// Scrolls the Performance board a step at a time, the way a trackpad does, and times each frame
/// (layout and drawing). Uses the real _library/social.json.
@MainActor
@Suite struct ZBenchScroll {
    @Test(.enabled(if: bench)) func performanceScroll() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        guard let social = SocialData.read(root) else { print("BENCH no social.json"); return }
        let view = ScrollView { SignalPage(data: social, platform: "") { Text("takes") }.padding(18) }
            .frame(width: 1100, height: 800).background(Theme.paper)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        guard let scroll = find(host) else { print("BENCH no NSScrollView"); return }
        let height = scroll.documentView?.frame.height ?? 0
        var frames: [Double] = []
        var y: CGFloat = 0
        for pass in 0..<2 {
            let step: CGFloat = pass == 0 ? 24 : -24
            for _ in 0..<Int(max(0, height - 800) / 24) {
                y += step
                let t = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                frames.append((CACurrentMediaTime() - t) * 1000)
            }
        }
        var layers = 0, shadows = 0, noPath = 0, masks = 0, filters = 0
        func walk(_ l: CALayer) {
            layers += 1
            if l.shadowOpacity > 0 { shadows += 1; if l.shadowPath == nil { noPath += 1 } }
            if l.mask != nil { masks += 1 }
            if !(l.filters ?? []).isEmpty || !(l.backgroundFilters ?? []).isEmpty || l.compositingFilter != nil { filters += 1 }
            for c in l.sublayers ?? [] { walk(c) }
        }
        if let l = host.layer { walk(l) }
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).map(count).reduce(0, +) }
        var kinds: [String: Int] = [:]
        func kind(_ l: CALayer) { kinds[String(describing: type(of: l)), default: 0] += 1; (l.sublayers ?? []).forEach(kind) }
        if let l = scroll.documentView?.layer { kind(l) }
        print("BENCH kinds", kinds.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" })
        var deep = scroll.documentView?.layer
        while let d = deep, (d.sublayers ?? []).count == 1 { deep = d.sublayers?.first }
        if let d = deep {
            print("BENCH top sections", (d.sublayers ?? []).map { "\(count($0))@\(Int($0.frame.minY))" }.joined(separator: " "))
        }
        print("BENCH layers \(layers), shadows \(shadows) (no path \(noPath)), masks \(masks), filters \(filters)")
        let s = frames.sorted()
        let p = { (q: Double) in s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
        print(String(format: "BENCH scroll doc %.0f pt, %d frames: median %.2f ms, p90 %.2f, max %.2f, total %.0f ms",
                     height, s.count, p(0.5), p(0.9), s.last ?? 0, s.reduce(0, +)))
    }
}

@MainActor
@Suite struct ZBenchPost {
    /// What one file change costs the post tab: the reload that runs on each change in the session.
    @Test(.enabled(if: bench)) func postReloadCost() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        let fm = FileManager.default
        var sessions: [URL] = []
        for p in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] where !p.lastPathComponent.hasPrefix("_") {
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where fm.fileExists(atPath: s.appending(path: "posts").path) { sessions.append(s) }
        }
        func ms(_ n: Int = 20, _ f: () -> Void) -> Double {
            let t = CFAbsoluteTimeGetCurrent(); for _ in 0..<n { f() }; return (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(n)
        }
        var rows: [(Double, String)] = []
        for s in sessions {
            for p in PostPlatform.allCases {
                let post = PostStore(p), comments = CommentStore(), hooks = HookStore(file: { PostFile.hooksURL($0, p) })
                post.load(s); comments.load(s); hooks.load(s)
                let reload = ms {
                    post.load(s); comments.load(s); hooks.load(s)
                    _ = PostFile.media(post.content, in: s, p)
                    _ = p == .linkedin ? PostFile.firstComment(s) : ""
                }
                let media = ms { _ = PostFile.media(post.content, in: s, p) }
                rows.append((reload, String(format: "reload %.2f ms (media %.2f)  %@ %@", reload, media, p.rawValue, s.lastPathComponent)))
            }
        }
        for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(8) { print("BENCH " + r.1) }
        // What each keystroke's body does on top of drawing.
        let longest = sessions.compactMap { PostFile.read($0, .article) }.max { $0.text.count < $1.text.count }
        if let a = longest {
            print(String(format: "BENCH article %d chars: words+minutes %.3f ms, head %.3f ms, blocks %.3f ms",
                         a.text.count, ms { _ = Article.words(a.text); _ = Article.minutes(a.text) },
                         ms { _ = ArticleHead(a) }, ms { _ = Article.blocks(a.text) }))
        }
        if let s = sessions.first {
            print(String(format: "BENCH switch dots %.3f ms", ms { for p in PostPlatform.allCases { _ = fm.fileExists(atPath: PostFile.url(s, p).path) } }))
        }
    }
}


@MainActor
@Suite struct ZBenchTabs {
    /// The time to show the Post tab and to go back to it, in the whole window, on a real session.
    @Test(.enabled(if: bench)) func tabSwitchCost() {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        let name = ProcessInfo.processInfo.environment["TAKES_BENCH_SESSION"] ?? "claude-ran-a-shop"
        guard let s = app.library.sessions.first(where: { $0.url.lastPathComponent.contains(name) }) else { return }
        app.library.select(s.url)
        app.chats.open = ProcessInfo.processInfo.environment["TAKES_BENCH_CHAT"] != "0"
        app.chats.docked = true
        UserDefaults.standard.set("script", forKey: "rightTab")
        let size = CGSize(width: 1440, height: 860)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body)
            .frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        func settle() { for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() } }
        func step(_ tab: String) -> Double {
            let t = CFAbsoluteTimeGetCurrent()
            UserDefaults.standard.set(tab, forKey: "rightTab")
            RunLoop.main.run(until: Date())        // the change reaches SwiftUI
            host.layoutSubtreeIfNeeded()
            host.display()
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            settle()
            return ms
        }
        settle()
        for p in (ProcessInfo.processInfo.environment["TAKES_BENCH_PLATFORMS"] ?? "linkedin,vertical,article").split(separator: ",") {
            UserDefaults.standard.set(String(p), forKey: "postPlatform")
            let first = step("post"), a = step("assets"), again = step("post"), b = step("script"), third = step("post")
            print(String(format: "BENCH %@ post first %.0f ms, assets %.0f, post again %.0f, record %.0f, post from record %.0f", String(p), first, a, again, b, third))
            _ = step("script")
        }
        // Any order of tabs, first frame of each: TAKES_BENCH_SEQ=post,script,assets,script.
        // TAKES_BENCH_CHAT=0 closes the docked chat.
        if let seq = ProcessInfo.processInfo.environment["TAKES_BENCH_SEQ"] {
            for tab in seq.split(separator: ",").map(String.init) {
                print(String(format: "BENCH to %@: %.0f ms", tab, step(tab)))
            }
        }
        // A long run to sample: TAKES_BENCH_LOOP=40.
        let loops = Int(ProcessInfo.processInfo.environment["TAKES_BENCH_LOOP"] ?? "0") ?? 0
        if loops > 0 {
            FileManager.default.createFile(atPath: "/private/tmp/claude-501/takes-bench-loop", contents: nil)
            var total = 0.0
            for _ in 0..<loops { total += step("post"); total += step("script") }
            print(String(format: "BENCH loop avg %.0f ms a switch", total / Double(loops * 2)))
        }
        window.orderOut(nil)
    }
}

import WebKit

@MainActor
@Suite struct ZBenchArticleSwitch {
    /// LinkedIn, Article, LinkedIn, Article in the real window: the second Article reuses the page
    /// and shows this session's article.
    @Test(.enabled(if: bench)) func articleSwitchReusesThePage() async {
        let app = AppModel()
        app.library.setRoot(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes"))
        guard let s = app.library.sessions.first(where: { FileManager.default.fileExists(atPath: $0.url.appending(path: "posts/article.md").path) }) else { return }
        app.library.select(s.url)
        UserDefaults.standard.set("post", forKey: "rightTab")
        UserDefaults.standard.set("linkedin", forKey: "postPlatform")
        let size = CGSize(width: 1440, height: 860)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        func settle() { for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() } }
        func webs(_ v: NSView) -> [WKWebView] { (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webs) }
        func shown(_ w: WKWebView) async -> (Double, String) {
            let t = CFAbsoluteTimeGetCurrent()
            var txt = ""
            for _ in 0..<800 {
                txt = (try? await w.evaluateJavaScript("document.querySelector('article')?.innerText ?? ''")) as? String ?? ""
                if txt.count > 200 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return ((CFAbsoluteTimeGetCurrent() - t) * 1000, txt)
        }
        func webProcs() -> (Int, Int) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "rss=,command="]
            let o = Pipe(); p.standardOutput = o; try? p.run()
            let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("WebKit.WebContent") }
            return (rows.count, rows.compactMap { Int($0.split(separator: " ").first ?? "") }.reduce(0, +) / 1024)
        }
        let start = webProcs()
        settle()
        var seen: [WKWebView] = []
        for round in 0..<6 {
            // From the switch until the article's text is on the page.
            let t = CFAbsoluteTimeGetCurrent()
            UserDefaults.standard.set("article", forKey: "postPlatform")
            var web: WKWebView?, chars = 0
            while CFAbsoluteTimeGetCurrent() - t < 8 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005)); host.layoutSubtreeIfNeeded()
                if web == nil { web = webs(host).first }
                if let w = web {
                    chars = ((try? await w.evaluateJavaScript("document.querySelector('article')?.innerText.length ?? 0")) as? Int) ?? 0
                    if chars > 200 { break }
                }
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            guard let w = web else { Issue.record("no web view"); return }
            print(String(format: "BENCH article round %d: switch to text %.0f ms, reused %@, %d chars", round, ms, seen.contains { $0 === w } ? "yes" : "no", chars))
            seen.append(w)
            UserDefaults.standard.set("linkedin", forKey: "postPlatform"); settle()
        }
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let end = webProcs()
        print("BENCH web processes: \(start.0) (\(start.1) MB) before, \(end.0) (\(end.1) MB) after six switches")
        #expect(seen[1] === seen[0] && seen[2] === seen[0])
        window.orderOut(nil)
    }
}

@MainActor
@Suite struct ZBenchStream {
    /// CPU while a reply streams into a long docked chat, on each tab (TAKES_BENCH_SEQ). Runs on a copy
    /// of a real session's text files, with a fake claude, so no real chat changes. The window is off
    /// every screen, where animations never settle: compare two runs, do not trust one number.
    @Test(.enabled(if: bench)) func streamCost() async throws {
        let fm = FileManager.default
        let name = ProcessInfo.processInfo.environment["TAKES_BENCH_SESSION"] ?? "claude-ran-a-shop"
        let real = fm.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        guard let src = (fm.subpaths(atPath: real.path) ?? []).first(where: { $0.hasSuffix(name) && !$0.contains("/.") })
            .map({ real.appending(path: $0) }) else { return }
        let root = fm.temporaryDirectory.appending(path: "takes-stream-\(UUID().uuidString)")
        let session = root.appending(path: "Bench/2026-10-01-\(name)")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        defer { ClaudeChat.claudeOverride = nil; try? fm.removeItem(at: root) }
        for f in [".claude-chat.json", "script.md", "session.json", "SESSION.md", "hooks.json", "posts"] {
            try? fm.copyItem(at: src.appending(path: f), to: session.appending(path: f))
        }
        let script = root.appending(path: "claude")
        try """
        #!/bin/bash
        cat > /dev/null
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'
        for i in $(seq 1 120); do
          echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"word '$i' and a few more words, "}}}'
          sleep 0.025
        done
        echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        ClaudeChat.claudeOverride = script.path

        let app = AppModel()
        app.library.setRoot(root)
        guard let s = app.library.sessions.first else { return }
        app.library.select(s.url)
        app.chats.open = true
        app.chats.docked = true
        let size = CGSize(width: 1440, height: 860)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        func settle() { for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); host.layoutSubtreeIfNeeded() } }
        func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000 }
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["TAKES_BENCH_PLATFORMS"] ?? "linkedin", forKey: "postPlatform")
        let chat = app.chats.chat(s.url)
        for tab in (ProcessInfo.processInfo.environment["TAKES_BENCH_SEQ"] ?? "post,script").split(separator: ",").map(String.init) {
            UserDefaults.standard.set(tab, forKey: "rightTab")
            settle(); settle()
            let c = cpu(), t = CFAbsoluteTimeGetCurrent()
            chat.send("Bench", title: "Bench", onStage: nil)
            while chat.running && CFAbsoluteTimeGetCurrent() - t < 15 {
                try? await Task.sleep(for: .milliseconds(16))
            }
            print(String(format: "BENCH stream on %@: %.0f ms CPU over %.1f s (%d msgs)", tab, cpu() - c, CFAbsoluteTimeGetCurrent() - t, chat.messages.count))
        }
        window.orderOut(nil)
    }
}
