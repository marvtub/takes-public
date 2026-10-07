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

    /// The Mac's recognizer has the common languages (what the website names).
    @Test func theCommonLanguagesHaveARecognizer() async {
        let have: [Locale]
        if #available(macOS 26, *) { have = await SpeechTranscriber.supportedLocales } else { have = Array(SFSpeechRecognizer.supportedLocales()) }
        for code in ["en", "es", "fr", "de", "it", "pt", "ja", "zh"] {
            #expect(ScriptLanguage.pick(code, from: have, preferred: []) != nil, "no recognizer for \(code)")
        }
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
        #expect(l.frame.width == NotchLayout.minWidth)  // 185 + 260 is less than the least width
    }

    @Test func noNotchMeansUnderTheMenuBar() {
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let l = NotchLayout.make(screen: screen, visibleTop: 1415, notch: nil, body: 120)
        #expect(l.frame.maxY == 1415)
        #expect(l.band == 0)
        #expect(abs(l.frame.midX - (1512 + 1280)) <= 1)
    }

    @Test func moreLinesMakeATallerPanel() {
        #expect(NotchPanel.body(lines: 4) > NotchPanel.body(lines: 3))
    }

    @Test func voiceFollowSwitchIsRemembered() {
        let app = AppModel()
        let was = app.followVoice
        app.followVoice = !was
        #expect(UserDefaults.standard.bool(forKey: "prompterFollowVoice") == !was)
        app.followVoice = was
        #expect(app.following == was)
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
        for (name, lines) in [("notch-3", 3), ("notch-5", 5)] {
            let body = NotchPanel.body(lines: lines)
            let l = NotchLayout.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 950,
                                     notch: CGSize(width: 185, height: 32), body: body)
            UserDefaults.standard.set(lines, forKey: "notchLines")
            // A grey "desktop" behind it, to see the shape.
            let v = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchView(layout: l, close: {}).environment(app(said: 9)).frame(width: l.frame.width, height: l.frame.height)
            }
            try shoot(v, CGSize(width: l.frame.width + 80, height: l.frame.height + 30), name)
        }
        UserDefaults.standard.removeObject(forKey: "notchLines")
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
