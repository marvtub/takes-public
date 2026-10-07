import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Takes

/// Renders the building blocks in light and dark to PNGs, to look at after a theme change.
/// Off by default: `TAKES_SNAPSHOT=/some/dir ./test.sh --filter BrandSnapshot`.
@MainActor
struct BrandSnapshotTests {
    @Test func brandSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let mascot = NSImage(contentsOf: root.appending(path: "brand/mascot-512.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let r = ImageRenderer(content: Sheet(mascot: mascot).environment(\.colorScheme, name == "dark" ? .dark : .light))
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "brand-\(name).png"))
        }
    }

    /// The header's notice card: with a picture, with an icon, and with more waiting.
    @Test func noticeCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let pic = NSImage(contentsOf: root.appending(path: "brand/mascot-512.png"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let v = VStack(alignment: .leading, spacing: 28) {
                NoticeCardBody(what: "Edit v2", detail: "The era of personal software · Mg s3 linux phones",
                               icon: "play.rectangle.fill", thumb: pic, more: 1)
                NoticeCardBody(what: "Script", detail: "Bookkeeping agent", icon: "doc.text")
            }
            .padding(30).background(Theme.paper)
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "notice-\(name).png"))
        }
    }

    /// "@comments" in a real (AppKit) text field, with the chip over it: the two must line up.
    @Test func commandToken() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let field = TokenField(draft: "@comments fix the loud part please")
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: field)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 64)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 420, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "token-\(name).png"))
        }
    }

    /// ⌘K with its chips and the project menu, a script hit under them.
    @Test func searchChips() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: assets.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let root = FileManager.default.temporaryDirectory.appending(path: "chips-\(UUID().uuidString)")
        let s = root.appending(path: "Weekly Challenge/2026-10-06-bookkeeping-agent")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try Data("Look down at the computer, click once.".utf8).write(to: s.appending(path: "script.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        app.library.setRoot(root)
        MediaSearch.shared.shown = true
        defer { MediaSearch.shared.shown = false }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let v = SearchPalette(query: "computer").environment(app)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 760, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "search-\(name).png"))
        }
    }

    /// The What's new panel the Update row opens, one change open.
    @Test func whatsNew() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let log = [
            Updater.Change.parse(subject: "Notice card on the middle of the window, over the header row, not in the row's leftover space", id: "a"),
            Updater.Change.parse(subject: "Install only main; Script beside chat moves into the camera caption row", body: "A branch build dropped the Article tab, so install builds only what is on main.", id: "b"),
            Updater.Change.parse(subject: "Notices: unseen ones are saved and come back after a quit or an update", id: "c"),
            Updater.Change.parse(subject: "Chat: @comments at the start of the box shows as a tinted command chip over the typed word", id: "d"),
            Updater.Change.parse(subject: "Notice: a card in the header's middle, with the file's picture and its name in words", id: "e"),
            Updater.Change.parse(subject: "Post tab: Article, a post for the blog as your blog shows it", id: "f"),
        ]
        // A local build, and a GitHub release (its heading names the release).
        for (staged, suffix) in [(Updater.Staged(stamp: "0c2ec90 Oct 4 09:46", changes: [], log: log), ""),
                                 (Updater.Staged(stamp: "0c2ec90 Oct 4 09:46", changes: [], log: log, release: "v2026.10.9"), "-release")] {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let v = WhatsNew(staged: staged, updater: Updater.shared) {}
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: appearance)
            // The list measures its changes after the first layout: fit again after that.
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "whatsnew-\(name)\(suffix).png"))
        }
        }
    }

    /// The post's bar at a narrow and a wide width: nothing in it is cut to "…".
    @MainActor @Test func postBar() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let s = FileManager.default.temporaryDirectory.appending(path: "postbar-\(UUID().uuidString)/P/2026-10-02-a")
        try FileManager.default.createDirectory(at: s.appending(path: "posts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try "Hey there\n".write(to: s.appending(path: "posts/linkedin.md"), atomically: true, encoding: .utf8)
        try "One tweet\n".write(to: s.appending(path: "posts/x.md"), atomically: true, encoding: .utf8)
        try ("---\ntitle: How I make videos\n---\n\n" + String(repeating: "word ", count: 1800)).write(to: s.appending(path: "posts/article.md"), atomically: true, encoding: .utf8)
        let app = AppModel()
        for (platform, width) in [(PostPlatform.article, 620.0), (.article, 1000), (.linkedin, 620), (.vertical, 620)] {
            let v = PlatformPostPane(doc: SessionDoc(url: s), platform: platform, pick: { _ in })
                .environment(app).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: v)
            host.appearance = NSAppearance(named: .darkAqua)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "postbar-\(platform.rawValue)-\(Int(width)).png"))
        }
    }

    /// The Posted tab: the number cards, the one chart and the list, once they have grown in.
    @MainActor @Test func safeZone() throws {
        #expect(SafeZone.fits(CGSize(width: 1080, height: 1920)))
        #expect(!SafeZone.fits(CGSize(width: 1080, height: 1350)))
        #expect(!SafeZone.fits(.zero))
        let r = SafeZone.place(SafeZone.safe[0], in: CGRect(x: 10, y: 0, width: 540, height: 960))
        #expect(r == CGRect(x: 40, y: 120, width: 410, height: 650))
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let still = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT_STILL"].flatMap { NSImage(contentsOfFile: $0) }
        for (name, w) in [("wide", 360.0), ("small", 220.0)] {
            let h = w * 16 / 9
            let v = ZStack {
                if let still { Image(nsImage: still).resizable() } else {
                    LinearGradient(colors: [.orange, .purple], startPoint: .top, endPoint: .bottom)
                }
                SafeZoneOverlay(frame: CGRect(x: 0, y: 0, width: w, height: h))
            }
            .frame(width: w, height: h)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "safe-zone-\(name).png"))
        }
    }

    @MainActor @Test func postedTab() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let lib = FileManager.default.temporaryDirectory.appending(path: "posted-\(UUID().uuidString)")
        let folder = CopilotStore.suggestions(lib)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lib) }
        let f = ISO8601DateFormatter()
        for (i, (daysAgo, who)) in [(0, "Ethan Mollick"), (0, "Greg Isenberg"), (1, "Addy Osmani"), (1, "Cody Schneider"), (1, "Alex Hormozi"),
                                    (1, "Nathan Barry"), (1, "Aakash Gupta"), (2, "Lenny Rachitsky"), (2, "Pieter Levels")].enumerated() {
            let at = f.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86_400 - Double(i) * 600))
            let json = #"{"id": "p\#(i)", "created": "\#(at)", "status": "posted", "post": {"author": "\#(who)"}, "drafts": [{"text": "Kind of the same with agents tbh. Be more careful gets you nothing."}], "final": "Kind of the same with agents tbh. Be more careful gets you nothing.", "posted": {"at": "\#(at)"}}"#
            try json.write(to: folder.appending(path: "p\(i).json"), atomically: true, encoding: .utf8)
        }
        let store = CopilotStore()
        store.scan(lib)
        #expect(store.posted.count == 9)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: PostedList(store: store).environment(\.colorScheme, name == "dark" ? .dark : .light)
                .frame(width: 900, height: 900).background(Theme.paper))
            host.appearance = NSAppearance(named: appearance)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            for _ in 0..<30 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "posted-\(name).png"))
        }
    }

    /// The Skipped tab: flat rows, the buttons hidden until the pointer comes.
    @MainActor @Test func skippedTab() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let lib = FileManager.default.temporaryDirectory.appending(path: "skipped-\(UUID().uuidString)")
        let folder = CopilotStore.suggestions(lib)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lib) }
        let f = ISO8601DateFormatter()
        let rows = [("Dan Koe", "Pick something.", "Surfing does this for me. Every session is a new problem and there's no way to check your phone out there lol"),
                    ("John Cutler", "May I present to you: The Case-by-Caser. By repeatedly asking for specifics, they can make any problem not their fault.", "Strategy vibes fine, problem vibes not fine... stealing that for my next retro lol"),
                    ("Cody Schneider", "Doubling the budget on a winning ad set is the fastest way to kill it. Meta resets learning, CPA jumps.", "20% a day so learning never resets... kind of like paddling out. Go for the big set too early and you're back on the beach lol")]
        for (i, (who, post, text)) in rows.enumerated() {
            let at = f.string(from: Date().addingTimeInterval(-Double(i) * 50_000 - 2_000))
            let json = #"{"id": "s\#(i)", "created": "\#(at)", "skipped": "\#(at)", "status": "review", "post": {"author": "\#(who)", "text": "\#(post)", "url": "https://l.in/\#(i)"}, "drafts": [{"text": "\#(text)"}]}"#
            try json.write(to: folder.appending(path: "s\(i).json"), atomically: true, encoding: .utf8)
        }
        let store = CopilotStore()
        store.scan(lib)
        #expect(store.skippedList.count == 3)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: SkippedList(store: store).environment(\.colorScheme, name == "dark" ? .dark : .light)
                .frame(width: 900, height: 420).background(Theme.paper))
            host.appearance = NSAppearance(named: appearance)
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "skipped-\(name).png"))
        }
    }

    /// The live mascot's face over its body, in each mood (the still pose, no animation).
    @Test func mascotMoods() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        MascotView.bodyImage = NSImage(contentsOf: root.appending(path: "brand/mascot-body-512.png"))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        let moods: [LiveMascot.Mood] = [.idle, .thinking, .writing, .working]
        let s = 256
        let ctx = try #require(CGContext(data: nil, width: s * moods.count, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s * moods.count, height: s))
        for (i, mood) in moods.enumerated() {
            let v = MascotView(frame: NSRect(x: 0, y: 0, width: s, height: s))
            v.mood = mood
            v.layout()
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i * s), y: 0)
            v.layer?.render(in: ctx)
            ctx.restoreGState()
        }
        let image = try #require(ctx.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appending(path: "mascot-moods.png"))
    }
}

private struct Sheet: View {
    let mascot: NSImage?
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "sessions")
                ForEach(["Fix AI agents with context", "Why I record every day", "Takes launch"], id: \.self) { t in
                    HStack { Circle().fill(t == "Takes launch" ? Theme.live : Theme.accent).frame(width: 7, height: 7)
                        Text(t).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink) }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(t.hasPrefix("Why") ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                Spacer()
            }
            .padding(14).frame(width: 230).background(Theme.surface)
            Rule(vertical: true)
            VStack(alignment: .leading, spacing: 18) {
                if let mascot { Image(nsImage: mascot).resizable().aspectRatio(contentMode: .fit).frame(width: 96) }
                (Text("Ready when you are.\n").foregroundStyle(Theme.ink) + Text("Just hit record.").foregroundStyle(Theme.accent))
                    .font(Theme.display(42))
                Text("Takes makes the session for you and names it from your script.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    Button("Record") {}.buttonStyle(AccentButtonStyle(kind: .solid))
                    Button("Schedule") {}.buttonStyle(AccentButtonStyle(kind: .accent))
                    Button("Write one yourself") {}.buttonStyle(AccentButtonStyle(kind: .quiet))
                    Button("Copy path") {}.buttonStyle(BracketButtonStyle())
                }
                HStack(spacing: 8) { Tag(text: "hook B", accent: true); Tag(text: "3 takes"); Tag(text: "needs update").foregroundStyle(Theme.warn) }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Impressions").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.faint)
                        Text("12,480").font(Theme.display(32)).foregroundStyle(Theme.ink)
                        Text("+18% this week").font(Theme.sans(12, .medium)).foregroundStyle(Theme.live)
                    }.card(padding: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing here yet").font(Theme.display(28)).foregroundStyle(Theme.ink)
                        Text("Pause a video and press S.").font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    }.card(padding: 16)
                }
                Text("This is the teleprompter. The script reads like a prompter on dark navy.")
                    .font(Font(Theme.prompter(20))).foregroundStyle(.white)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.stage, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
            .padding(32).frame(width: 640, alignment: .leading).background(Theme.paper)
        }
        .frame(height: 640)
    }
}

private struct TokenField: View {
    @State var draft: String
    var body: some View {
        TextField("Message Takes", text: $draft, axis: .vertical)
            .textFieldStyle(.plain).font(Theme.sans(13)).lineLimit(1...6)
            .overlay(alignment: .topLeading) { CommandToken(draft: draft) }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 12)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .padding(8)
            .background(Theme.raised)
    }
}
