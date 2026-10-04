import AppKit
import AVFoundation
import SwiftUI
import Testing
import WebKit
@testable import Takes

// The public README's pictures (2026-10-04): the whole window on the made-up library that
// scripts/public/demo.py builds, with a made-up profile. Never the user's library or photo.
//   python3 scripts/public/demo.py /tmp/takes-demo
//   TAKES_DEMO=/tmp/takes-demo TAKES_README=/tmp/shots ./test.sh --filter ReadmeShots
let readmeDir = ProcessInfo.processInfo.environment["TAKES_README"]
let demoRoot = ProcessInfo.processInfo.environment["TAKES_DEMO"]

@MainActor @Suite(.serialized) struct ReadmeShots {
    let size = CGSize(width: 1600, height: 1000)

    func shoot(_ name: String, _ view: some View, dark: Bool = true, wait: Double = 2.5, size: CGSize? = nil,
               tab: SessionMode? = nil) async {
        let size = size ?? self.size
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(wait)
        // Await, not RunLoop.run: tasks, players and web views need the main actor free to load.
        while Date() < end {
            // Something in the test window sends the tab back to Record after a few seconds with the
            // chat docked; hold the tab the shot is for.
            if let tab, UserDefaults.standard.string(forKey: "rightTab") != tab.rawValue { SessionMode.set(tab) }
            try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        // Web views (the article) draw outside cacheDisplay: paint their own snapshot on top.
        // Only on the Post tab: the article's web view stays alive, hidden, behind the other tabs.
        for web in tab == .post || tab == nil ? Self.webViews(in: host) : [] {
            var image: NSImage?
            web.takeSnapshot(with: nil) { i, _ in image = i }
            let stop = Date().addingTimeInterval(3)
            while image == nil && Date() < stop { try? await Task.sleep(for: .milliseconds(50)) }
            guard let image else { continue }
            let r = web.convert(web.bounds, to: host)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: r.minX, y: host.isFlipped ? host.bounds.height - r.maxY : r.minY, width: r.width, height: r.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        // Video players draw outside cacheDisplay too: paint a frame of their file in their place.
        if let top = host.layer {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for l in Self.playerLayers(in: top) {
                guard let asset = l.player?.currentItem?.asset else { continue }
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1.5, preferredTimescale: 600), actualTime: nil) else { continue }
                var r = top.convert(l.bounds, from: l)
                if top.isGeometryFlipped || host.isFlipped { r.origin.y = top.bounds.height - r.maxY }
                let img = CGSize(width: cg.width, height: cg.height)
                let fit = AVMakeRect(aspectRatio: img, insideRect: r)
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.saveGState()
                ctx.clip(to: r)
                if l.videoGravity == .resizeAspectFill {
                    let s = max(r.width / img.width, r.height / img.height)
                    let w = img.width * s, h = img.height * s
                    ctx.draw(cg, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
                } else if l.videoGravity == .resize {
                    ctx.draw(cg, in: r)
                } else {
                    ctx.draw(cg, in: fit)
                }
                ctx.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: readmeDir!).appending(path: "\(name).png"))
    }

    /// A short made-up conversation in the docked chat, so the shots show Takes at work.
    static func demoChat(_ session: URL) {
        let edit = session.appending(path: "edits/ai-week-short-v1.mp4").path
        func m(_ r: ChatMessage.Role, _ t: String) -> ChatMessage { ChatMessage(role: r, text: t) }
        let log = ChatLog(conversation: UUID().uuidString, started: true, messages: [
            m(.user, "Cut my keeper into a vertical short. Keep it tight, no silences."),
            m(.tool, "get session · I let AI edit my videos for a week"),
            m(.tool, "Bash · Find the silences in take 02"),
            m(.tool, "Bash · Cut, reframe to 9:16 and add captions"),
            m(.tool, "Read · frame-0012.png"),
            m(.claude, "The short is ready, cut from your keeper. I took out 14 silences and both false starts, and the captions sit above the platform buttons.\n\(edit)\nI checked frames at every cut: no jump on your face."),
            m(.user, "Nice. Now write the posts for it."),
            m(.tool, "set post · vertical"),
            m(.tool, "set post · linkedin"),
            m(.tool, "set post · x"),
            m(.claude, "The posts are on the Post tab: one caption for TikTok, Reels and Shorts, a LinkedIn post and an X thread. Each one uses the new short."),
        ])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(log).write(to: ClaudeChat.file(session))
    }

    static func playerLayers(in layer: CALayer) -> [AVPlayerLayer] {
        ((layer as? AVPlayerLayer).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap { playerLayers(in: $0) }
    }

    static func webViews(in view: NSView) -> [WKWebView] {
        view.subviews.flatMap { v -> [WKWebView] in (v as? WKWebView).map { [$0] } ?? webViews(in: v) }
    }

    @Test(.enabled(if: readmeDir != nil && demoRoot != nil)) func window() async throws {
        _ = NSApplication.shared
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/fonts")
        for f in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let d = UserDefaults.standard
        // The app as it is used (2026-10-04): Graphite, the chat docked open, the real icon. The
        // default navy palette and a floating chat looked like a different app.
        Look.shared.palette = .graphite
        d.set(true, forKey: "chatOpen")
        d.set(true, forKey: "chatDocked")
        NSApp.applicationIconImage = NSImage(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../assets/Takes.icns"))
        d.set("Sam Rivera", forKey: "linkedinName")
        d.set("Video creator · Editing with agents", forKey: "linkedinHeadline")
        d.set("Sam Rivera", forKey: "xName")
        d.set("samrivera", forKey: "xHandle")
        let avatar = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../scripts/public/demo-media/avatar.jpg")
        LinkedIn.photoImage = NSImage(contentsOf: avatar)
        LinkedIn.photoLoaded = true
        revealAtOnce = true
        defer { LinkedIn.photoLoaded = false; LinkedIn.photoImage = nil; revealAtOnce = false; Look.shared.reset() }

        let app = AppModel()
        app.library.setRoot(URL(fileURLWithPath: demoRoot!))
        app.library.selectedProject = app.library.projects.first { $0.name == "YouTube" }?.url
        app.library.reload()
        let main = try #require(app.library.sessions.first { $0.title.lowercased().contains("ai edit") })
        Self.demoChat(main.url)
        app.library.select(main.url)
        func window() -> some View { ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body) }

        d.set(SessionMode.record.rawValue, forKey: "rightTab")
        if let keeper = app.library.current?.meta.takes.first(where: { $0.keeper }), let doc = app.library.current {
            app.preview = doc.fileURL(keeper)
        }
        // Dark by default (2026-10-04): the app looks best dark; one light shot shows the other look.
        await shoot("record", window(), tab: .record)
        await shoot("record-light", window(), dark: false)
        app.preview = nil
        d.set(SessionMode.storyboard.rawValue, forKey: "rightTab")
        await shoot("storyboard", window(), wait: 4, tab: .storyboard)
        d.set(SessionMode.post.rawValue, forKey: "rightTab")
        for p in PostPlatform.allCases {
            d.set(p.rawValue, forKey: "postPlatform")
            await shoot("post-\(p.rawValue)", window(), wait: p == .article ? 4 : 2.5, tab: .post)
        }
        d.set(SessionMode.record.rawValue, forKey: "rightTab")
        await shoot("banner", Banner(dir: URL(fileURLWithPath: readmeDir!)), wait: 0.5, size: CGSize(width: 1280, height: 640))
    }
}

/// The README's banner, 1280×640 (also GitHub's social preview): the lockup, one line, one real window.
struct Banner: View {
    let dir: URL
    func shot(_ name: String) -> NSImage? { NSImage(contentsOf: dir.appending(path: "\(name).png")) }
    var body: some View {
        let lockupURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/public/lockup-white.png")
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.08), Color(red: 0.15, green: 0.15, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // One real window, straight, running off the right and bottom edge (2026-10-04): the
            // tilted collage looked like a mock-up, not the app.
            if let front = shot("record") {
                Image(nsImage: front).resizable().aspectRatio(contentMode: .fit).frame(width: 980)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: 600, y: 150)
            }
            VStack(alignment: .leading, spacing: 22) {
                if let lockup = Self.trimmed(lockupURL) {
                    Image(nsImage: lockup).resizable().aspectRatio(contentMode: .fit).frame(width: 280)
                        .padding(.bottom, 6)
                }
                Text("Record takes.\nClaude Code does the rest.")
                    .font(.custom("Nunito-Bold", size: 38)).foregroundStyle(Color(red: 0.96, green: 0.97, blue: 0.99))
                    .lineSpacing(2)
                Text("Scripts, storyboards, edits and posts for\nLinkedIn, X, YouTube, Shorts and your blog.")
                    .font(.custom("Inter-Regular", size: 19)).foregroundStyle(Color(red: 0.66, green: 0.71, blue: 0.80))
                    .lineSpacing(4)
            }
            .padding(.leading, 72)
        }
        .frame(width: 1280, height: 640).clipped()
    }

    /// The lockup without its transparent margin, so its left edge lines up with the text.
    static func trimmed(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        data.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let px = data.data!.assumingMemoryBound(to: UInt8.self)
        var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        for y in 0..<cg.height { for x in 0..<cg.width where px[(y * cg.width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, let crop = data.makeImage()?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return NSImage(cgImage: crop, size: CGSize(width: crop.width, height: crop.height))
    }
}
