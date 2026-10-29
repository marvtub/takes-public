import AppKit
import Foundation
import Speech
import SwiftUI
import Testing
@testable import Takes

// 2026-10-07: voice follow, the notch and the mirrored window.

@MainActor
struct PrompterFollowTests {
    private func heard(_ f: inout ScriptFollower, _ text: String) -> Bool {
        f.hear(ScriptFollower.tokens(text))
    }

    /// The notch text size is kept, stays in range, and the panel grows to fit the same lines.
    @MainActor @Test func notchFontSize() {
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: NotchPanel.fontKey) }
        d.removeObject(forKey: NotchPanel.fontKey)
        #expect(NotchPanel.fontSize == 21)
        let small = NotchPanel.body(lines: 3)
        d.set(29.0, forKey: NotchPanel.fontKey)
        #expect(NotchPanel.fontSize == 29 && NotchPanel.body(lines: 3) > small)
        d.set(99.0, forKey: NotchPanel.fontKey)
        #expect(NotchPanel.fontSize == NotchPanel.fontSizes.upperBound)
        // More lines make a taller panel.
        #expect(NotchPanel.body(lines: 4) > NotchPanel.body(lines: 3))
    }

    @Test func followsWordByWord() {
        var f = ScriptFollower("Most people never record a second take. Here is why that matters.")
        #expect(heard(&f, "most people"))
        #expect(f.next == 2)
        #expect(heard(&f, "most people never record a second take"))
        #expect(f.next == 7)
    }

    @Test func skippedWordsStillMoveOn() {
        var f = ScriptFollower("Most people never record a second take. Here is why that matters.")
        f.jump(to: 2)
        // "never record a" left out.
        #expect(heard(&f, "second take here is"))
        #expect(f.words[f.next - 1] == "is")
    }

    @Test func offScriptWordsWait() {
        var f = ScriptFollower("Most people never record a second take.")
        f.jump(to: 3)
        #expect(!heard(&f, "um so anyway let me think"))
        #expect(f.next == 3)
    }

    @Test func aRepeatedPhraseKeepsTheNearestPlace() {
        var f = ScriptFollower("Do it again. Then do it again. Then stop.")
        f.jump(to: 4)
        #expect(heard(&f, "do it again then do it again"))
        #expect(f.next == 7)  // the second "Then", not back to the first
    }

    @Test func goingBackNeedsMoreProof() {
        var f = ScriptFollower("One two three four five six seven eight nine ten eleven twelve.")
        f.jump(to: 10)
        // Recognizers send all the words so far. One word from earlier is not enough to jump back...
        #expect(!heard(&f, "eight nine ten five"))
        #expect(f.next == 10)
        // ...a restart of the sentence is.
        #expect(heard(&f, "eight nine ten let me say that again three four five"))
        #expect(f.next == 5)
    }

    @Test func accentsCaseAndPunctuationDoNotMatter() {
        var f = ScriptFollower("Das Café öffnet um acht. ¿Qué pasa?")
        #expect(heard(&f, "das cafe offnet"))
        #expect(f.next == 3)
        #expect(heard(&f, "um acht que pasa"))
        #expect(f.next == f.words.count)
    }

    @Test func chineseIsCutIntoWords() {
        let f = ScriptFollower("今天我们来录一个视频。")
        #expect(f.words.count > 2)
        #expect(ScriptFollower.tokens("今天我们") == Array(f.words.prefix(ScriptFollower.tokens("今天我们").count)))
    }

    @Test func wordAtOffsetFindsTheWordUnderAHandScroll() {
        let f = ScriptFollower("Alpha beta gamma.")
        #expect(f.word(at: 0) == 0)
        #expect(f.word(at: 7) == 1)
        #expect(f.word(at: 100) == 3)
    }

    @Test func picksTheScriptsLanguage() {
        #expect(ScriptLanguage.code(of: "This is a short script about recording better videos at home.") == "en")
        #expect(ScriptLanguage.code(of: "Heute zeige ich dir, wie du bessere Videos zu Hause aufnimmst.") == "de")
        #expect(ScriptLanguage.code(of: "Hoy te muestro cómo grabar mejores videos en casa.") == "es")
    }

    @Test func picksTheRegionYouUse() {
        let supported = ["en-US", "en-GB", "de-DE", "de-AT", "pt-PT", "pt-BR", "es-MX", "es-ES"].map { Locale(identifier: $0) }
        #expect(ScriptLanguage.pick("en", from: supported, preferred: [Locale(identifier: "en_GB")])?.identifier == "en-GB")
        #expect(ScriptLanguage.pick("de", from: supported, preferred: [Locale(identifier: "en_US")])?.identifier == "de-DE")
        #expect(ScriptLanguage.pick("pt", from: supported, preferred: [])?.identifier == "pt-BR")
        #expect(ScriptLanguage.pick("fi", from: supported, preferred: []) == nil)
    }

    @Test func hintsAreNamesAndLongWords() {
        let h = VoiceFollow.hints("Today Maya shows Takes, a teleprompter that records. It is free and it is fast.")
        #expect(h.contains("Maya") && h.contains("Takes") && h.contains("teleprompter"))
        #expect(!h.contains("free") && !h.contains("fast"))
    }

    @Test func notchPanelHangsFromTheNotch() {
        // A 14-inch MacBook Pro: 1512 × 982 points, the notch about 185 wide and 32 high.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let l = NotchLayout.make(screen: screen, visibleTop: 950, notch: CGSize(width: 185, height: 32), body: 120)
        #expect(l.frame.maxY == 982)
        #expect(l.frame.height == 152)
        #expect(l.band == 32)
        #expect(abs(l.frame.midX - 756) <= 1)
        #expect(l.frame.width == NotchLayout.minWidth)  // 185 + 330 is less than the least width
    }

    @Test func noNotchMeansUnderTheMenuBar() {
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let l = NotchLayout.make(screen: screen, visibleTop: 1415, notch: nil, body: 120)
        #expect(l.frame.maxY == 1415)
        #expect(l.band == 0)
        #expect(abs(l.frame.midX - (1512 + 1280)) <= 1)
    }

    /// The panel's line is the line Prompter draws, at the smallest and the biggest size: one more
    /// line of text takes one more of the panel's lines (2026-10-11: it was a fifth short each).
    @MainActor @Test func aPanelLineIsADrawnLine() {
        func drawn(_ text: String, _ size: Double) -> CGFloat {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = size * 0.35
            let store = NSTextStorage(string: text, attributes: [.font: NotchPanel.font(size), .paragraphStyle: para])
            let layout = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: 800, height: 10_000))
            store.addLayoutManager(layout); layout.addTextContainer(box)
            layout.ensureLayout(for: box)
            return layout.usedRect(for: box).height
        }
        for size in [NotchPanel.fontSizes.lowerBound, NotchPanel.fontSizes.upperBound] {
            let step = drawn("One\nTwo\nThree", size) - drawn("One\nTwo", size)
            #expect(abs(step - NotchPanel.line(size)) < 1, "size \(size): a line draws \(step), the panel gives \(NotchPanel.line(size))")
        }
    }

    /// The notch's line focus (2026-10-29): the line read goes dim, the words said on this line
    /// are full white, the words still to say wait a little dim.
    @Test func notchDimsTheLineRead() throws {
        let text = "Most people never record a second take. They watch the first one, wince, and give up. Here is how to fix that."
        let app = AppModel()
        app.voice.source = { text }
        app.voice.jump(to: 9)  // "the": the next word to say, on the second line
        let view = Prompter(text: .constant(text), contentKey: "t", fontSize: 21, scrolling: false, speed: 40, editable: false,
                            resetToken: 0, dark: true, voice: app.voice, readingLine: 0.3, inset: NSSize(width: 24, height: 2),
                            darkPage: .black, font: NotchPanel.font(21, mono: true), centered: true, focusLine: true)
        let host = NSHostingView(rootView: view.frame(width: 540, height: 160))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 160)
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 540, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSTextView? { (v as? NSTextView) ?? v.subviews.lazy.compactMap(find).first }
        let tv = try #require(find(host))
        let lm = try #require(tv.layoutManager)
        func alpha(_ word: String) -> CGFloat? {
            let at = (text as NSString).range(of: word).location
            return (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor)?.alphaComponent
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(tv.textContainer!.size.width > 300)
        #expect(alpha("Most").map { $0 < 0.4 } == true)
        #expect(alpha("watch") == 1)
        #expect(alpha("first").map { $0 > 0.5 && $0 < 0.7 } == true)
    }

    @Test func notchIntroNamesTakesNotClaude() {
        #expect(NotchView.intro.allSatisfy { !$0.title.contains("Claude") && !$0.text.contains("Claude") })
    }

    @Test func backToTopResetsThePlace() {
        let app = AppModel()
        app.voice.source = { "One two three four five." }
        app.voice.jump(to: 3)
        #expect(app.voice.next == 3)
        app.resetToken += 1
        #expect(app.voice.next == 0)
    }
}

/// The real recognizer on spoken audio (`say`), through the matcher. Off by default (it may
/// download a speech model): `TAKES_SPEECH=1 ./test.sh --filter SpokenFollow`.
@MainActor
struct SpokenFollowTests {
    @Test(arguments: [
        ("Samantha", "Most people never record a second take. They watch the first one and give up. Here is how to fix that in ten minutes."),
        ("Anna", "Die meisten Leute nehmen nie einen zweiten Take auf. Sie sehen sich den ersten an und geben auf. So änderst du das in zehn Minuten."),
        ("Thomas", "La plupart des gens n'enregistrent jamais une deuxième prise. Ils regardent la première et abandonnent. Voici comment changer cela en dix minutes."),
        ("Eddy (Spanish (Spain))", "La mayoría de la gente nunca graba una segunda toma. Ven la primera y se rinden. Así lo cambias en diez minutos."),
    ])
    func followsSpokenAudio(voice: String, script: String) async throws {
        guard ProcessInfo.processInfo.environment["TAKES_SPEECH"] != nil else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spoken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "say.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEI16@16000", script]
        try say.run(); say.waitUntilExit()
        let audio = try AVAudioFile(forReading: file)
        let found = await VoiceFollow.locale(for: script)
        let locale = try #require(found)
        var follower = ScriptFollower(script)
        var moves = 0
        let listener: Listener? = await {
            if #available(macOS 26, *) {
                return await AnalyzerListener.make(input: audio.processingFormat, locale: locale, hints: VoiceFollow.hints(script),
                                                   heard: { words, _ in if let words, follower.hear(ScriptFollower.tokens(words)) { moves += 1 } },
                                                   problem: { Issue.record("\($0)") })
            }
            return await RecognizerListener.make(locale: locale, heard: { words, _ in
                if let words, follower.hear(ScriptFollower.tokens(words)) { moves += 1 }
            }, problem: { Issue.record("\($0)") })
        }()
        let l = try #require(listener)
        // read(into:) throws at the end of the file, so stop on the length.
        while audio.framePosition < audio.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { break }
            try audio.read(into: b)
            l.feed(b)
        }
        await l.finish()
        print("\(locale.identifier): \(moves) moves, at word \(follower.next) of \(follower.words.count)")
        #expect(moves >= 5)
        #expect(follower.next >= follower.words.count - 2)
    }
}

/// The notch panel, the prompter window (plain and mirrored) and the prompter bar, as PNGs.
/// Off by default: `TAKES_SNAPSHOT=/some/dir ./test.sh --filter PrompterShots`.
@MainActor
struct PrompterShots {
    static let script = """
    Most people never record a second take. They watch the first one, wince, and give up.
    Here is how to fix that in ten minutes. First, write the script where you can read it.
    Then put the words right under the camera, so your eyes stay on the lens.
    """

    private func shoot(_ view: some View, _ size: CGSize, _ name: String, dark: Bool = true) throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    private func fonts() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }

    private func app(said: Int) -> AppModel {
        let app = AppModel()
        app.followVoice = true
        app.shot = StoryShot(say: Self.script)
        app.voice.source = { Self.script }
        app.voice.jump(to: said)
        return app
    }

    @Test func notch() throws {
        guard ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] != nil else { return }
        fonts()
        for (name, lines, intro) in [("notch-3", 3, 3), ("notch-5", 5, 3), ("notch-8", 8, 3), ("notch-intro-1", 5, 0), ("notch-intro-2", 5, 1), ("notch-intro-3", 5, 2)] {
            UserDefaults.standard.set(intro, forKey: NotchView.introKey)
            let body = NotchPanel.body(lines: lines)
            let l = NotchLayout.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 950,
                                     notch: CGSize(width: 185, height: 32), body: body)
            UserDefaults.standard.set(lines, forKey: "notchLines")
            // A grey "desktop" behind it, to see the shape.
            let v = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchView(layout: l, close: {}, lit: name == "notch-intro-1" ? 1 : 0).environment(app(said: 9))
            }
            let w = NotchView.window(for: l, floating: false)
            try shoot(v, CGSize(width: w.width + 40, height: w.height + 20), name)
        }
        UserDefaults.standard.removeObject(forKey: "notchLines")
        UserDefaults.standard.removeObject(forKey: NotchView.introKey)
    }

    /// The 2026-10-29 look: mono and Inter, narrow and wide, off the notch, with the voice light.
    /// ImageRenderer, so the light's blur draws.
    @Test func notchLooks() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        fonts()
        let d = UserDefaults.standard
        defer { [NotchView.introKey, NotchPanel.monoKey, "notchLines"].forEach { d.removeObject(forKey: $0) }; NotchVoiceLight.testLevel = nil }
        d.set(NotchView.intro.count, forKey: NotchView.introKey)
        d.set(3, forKey: "notchLines")
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for (name, mono, width, floating, light) in [("look-mono", true, nil, false, 0.9), ("look-inter", false, nil, false, 0.9),
                                                     ("look-narrow", true, 420.0, false, 0.5), ("look-quiet", true, nil, false, 0.1),
                                                     ("look-floating", true, nil, true, 0.8), ("look-with-pill", true, nil, false, 0.5)] as [(String, Bool, CGFloat?, Bool, Double)] {
            d.set(mono, forKey: NotchPanel.monoKey)
            NotchVoiceLight.testLevel = light
            let body = NotchPanel.body(lines: 3)
            let l = floating ? NotchLayout.floating(topLeft: CGPoint(x: 200, y: 900), width: 540, body: body + NotchView.strip)
                             : NotchLayout.make(screen: screen, visibleTop: 950, notch: CGSize(width: 185, height: 32), body: body, width: width)
            let w = NotchView.window(for: l, floating: floating)
            let model = app(said: 14)
            // The screen pill is up: the notch keeps only the words until you point at it.
            model.screenPillOpen = name == "look-with-pill"
            let v = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.06, green: 0.16, blue: 0.34), Color(red: 0.17, green: 0.37, blue: 0.77)],
                               startPoint: .top, endPoint: .bottom)
                NotchView(layout: l, floating: floating, close: {}).environment(model)
                if !floating {
                    UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 8, bottomTrailing: 8)).fill(.black).frame(width: 185, height: 32)
                }
            }
            .frame(width: w.width + 80, height: w.height + 20)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let img = try #require(r.nsImage)
            let tiff = try #require(img.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }

    /// The glow at its brightest. ImageRenderer draws blur; the AppKit snapshot above does not.
    @Test func glow() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let l = NotchLayout.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 950,
                                 notch: CGSize(width: 185, height: 32), body: NotchPanel.body(lines: 3))
        let v = ZStack(alignment: .top) {
            Color(white: 0.93)
            ZStack(alignment: .top) {
                NotchGlow(size: l.frame.size)
                NotchShape().fill(NotchView.fill(band: l.band, height: l.frame.height)).frame(width: l.frame.width, height: l.frame.height)
                // The screen's notch over the panel's top middle.
                UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 8, bottomTrailing: 8))
                    .fill(.black).frame(width: 185, height: 32)
            }
        }
        .frame(width: l.frame.width + 2 * NotchView.margin + 40, height: l.frame.height + NotchView.margin + 20)
        let r = ImageRenderer(content: v)
        r.scale = 2
        let img = try #require(r.nsImage)
        let tiff = try #require(img.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "notch-glow.png"))
    }

    @Test func window() throws {
        guard ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] != nil else { return }
        fonts()
        for (name, mirror) in [("window", false), ("window-mirrored", true)] {
            UserDefaults.standard.set(mirror, forKey: "prompterMirror")
            try shoot(PrompterWindowView().environment(app(said: 9)), CGSize(width: 900, height: 520), name)
        }
        UserDefaults.standard.removeObject(forKey: "prompterMirror")
    }

    @Test func bar() throws {
        guard ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] != nil else { return }
        fonts()
        let s = FileManager.default.temporaryDirectory.appending(path: "bar-\(UUID().uuidString)/P/2026-10-07-a")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try Self.script.write(to: s.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let app = AppModel()
        app.followVoice = true
        for (name, width) in [("bar-wide", 1000.0), ("bar-narrow", 560.0)] {
            try shoot(ScriptPane(doc: SessionDoc(url: s)).environment(app), CGSize(width: width, height: 420), name, dark: false)
        }
        // With the script in the notch, Record shows a small recorder, not a second prompter.
        app.notchOpen = true
        try shoot(ScriptPane(doc: SessionDoc(url: s)).environment(app), CGSize(width: 560, height: 520), "record-notch-open", dark: false)
        try shoot(ZStack { ScriptPane(doc: SessionDoc(url: s)); NotchTourShade() }.environment(app), CGSize(width: 900, height: 420), "tour-shade", dark: false)
    }
}

/// Shows the real notch panel for three seconds and takes a screenshot of the screen under it.
/// The panel asks to be left out of captures. Off by default: `TAKES_NOTCH_LIVE=/some/dir`.
@MainActor
struct NotchLiveCheck {
    @Test func panelIsLeftOutOfScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_NOTCH_LIVE"], let screen = NotchPanel.screen else { return }
        let app = AppModel()
        app.shot = StoryShot(say: PrompterShots.script)
        NotchPanel.shared.show(app)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let l = NotchLayout.make(for: screen, body: NotchPanel.body(lines: 3))
        print("NOTCH screen \(screen.frame) notch \(l.notchWidth)×\(l.band) panel \(l.frame)")
        let n = NotchPanel.shared.contentForTest?.window?.windowNumber ?? 0
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .first { ($0[kCGWindowNumber as String] as? Int) == n }
        // Hover labels need mouse-moved events while Takes is not the active app.
        func areas(_ v: NSView) -> [NSTrackingArea] { v.trackingAreas + v.subviews.flatMap(areas) }
        let opts = areas(NotchPanel.shared.contentForTest ?? NSView()).map(\.options)
        print("NOTCH tracking areas: \(opts.count) activeAlways: \(opts.filter { $0.contains(.activeAlways) }.count)")
        print("NOTCH on screen: \(info != nil) sharing: \(info?[kCGWindowSharingState as String] ?? "-") layer: \(info?[kCGWindowLayer as String] ?? "-")")
        // screencapture counts from the top left of the main display.
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - l.frame.maxY
        let r = "\(Int(l.frame.minX)),\(Int(top)),\(Int(l.frame.width)),\(Int(l.frame.height))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", r, "\(dir)/notch-capture.png"]
        try p.run(); p.waitUntilExit()
        // The panel itself, drawn by Takes, to compare.
        if let view = NotchPanel.shared.contentForTest, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "notch-drawn.png"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        NotchPanel.shared.hide()
    }
}

/// Record opens the notch by itself until you close it (2026-10-08).
@MainActor
struct NotchOnRecord {
    @Test func onUntilYouCloseIt() {
        let d = UserDefaults.standard, k = NotchPanel.autoKey
        let old = d.object(forKey: k)
        defer { d.set(old, forKey: k) }
        d.removeObject(forKey: k)
        #expect(NotchPanel.auto)
        NotchPanel.shared.close()
        #expect(!NotchPanel.auto)
        #expect(!NotchPanel.shared.autoOpened)
    }
}
