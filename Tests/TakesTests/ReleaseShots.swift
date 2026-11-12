import AppKit
import AVFoundation
import ObjectiveC
import SwiftUI
import Testing
@testable import Takes

// Pictures for the release notes (2026-10-24): each change people can see gets a still or a short
// film, drawn from the real views on the public copy, with made-up data (never the user's library).
// They go on the GitHub release and are kept for marketing in scripts/public/docs/releases/<tag>/.
//   scripts/public/release-media.sh        # exports the public copy, runs this suite, makes the files
// Each release, replace `thisRelease` with the scenes of its changes: `still` for a view, `film`
// for motion (a page that changes, a list that fills). release-media.sh turns every film into an
// .mp4 (marketing) and an animated .webp (the notes).
let releaseMediaDir = ProcessInfo.processInfo.environment["TAKES_RELEASE_MEDIA"]

@MainActor @Suite(.serialized) struct ReleaseShots {
    var out: URL { URL(fileURLWithPath: releaseMediaDir!) }
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")

    /// The app's look in every picture: its fonts, its icon, Graphite.
    static func setUp() {
        _ = NSApplication.shared
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        NSApp.applicationIconImage = NSImage(contentsOf: repo.appending(path: "assets/Takes.icns"))
        Look.shared.palette = .graphite
    }

    /// One picture of a view, as `<name>.png`. Use it for a change that does not move.
    func still(_ name: String, _ view: some View, size: CGSize, dark: Bool = true, wait: Double = 1.5) async {
        await ReadmeShots().shoot(name, view.foregroundStyle(Theme.ink).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas), dark: dark, wait: wait, size: size, dir: out.path)
    }

    /// A short film of a view at the app's real speed, as numbered frames in `<name>.film/` with
    /// their times (ffconcat). `beats` change the state at a second of the film: a click, a page.
    /// Drawing a frame off screen takes about 130 ms, so the motion runs `slow` times slower while
    /// it films, and each frame keeps its time in the app.
    func film(_ name: String, _ view: some View, size: CGSize, seconds: Double, dark: Bool = true,
              beats: [(at: Double, run: () -> Void)] = [], slow: Double = 6) async throws {
        let dir = out.appending(path: "\(name).film")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Theme.pace = slow
        Onboarding.pace = slow
        defer { Theme.pace = 1; Onboarding.pace = 1 }
        // Top-aligned: a view that grows or shrinks (a page with more rows) stays in place.
        let host = NSHostingView(rootView: AnyView(view.foregroundStyle(Theme.ink)
            .frame(width: size.width, height: size.height, alignment: .top).background(Theme.canvas)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var todo = beats.sorted { $0.at < $1.at }
        var times = "ffconcat version 1.0\n"
        var last: (String, Double)?
        var i = 0
        let start = Date()
        while true {
            let t = Date().timeIntervalSince(start) / slow
            if t > seconds { break }
            while let b = todo.first, b.at <= t { todo.removeFirst(); b.run() }
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = String(format: "%04d.png", i)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: file))
            let now = Date().timeIntervalSince(start) / slow
            if let last { times += "file \(last.0)\nduration \(String(format: "%.3f", now - last.1))\n" }
            last = (file, now)
            i += 1
        }
        if let last { times += "file \(last.0)\nduration 0.5\nfile \(last.0)\n" }
        try times.write(to: dir.appending(path: "times.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: This release

    @Test(.enabled(if: releaseMediaDir != nil)) func thisRelease() async throws {
        Self.setUp()
        defer { Look.shared.reset() }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "release-shots-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // The demo people (made up); the public copy has no scripts/public, so release-media.sh names the folder.
        let demo = ProcessInfo.processInfo.environment["TAKES_DEMO_MEDIA"].map { URL(fileURLWithPath: $0) }
            ?? Self.repo.appending(path: "scripts/public/demo-media")
        // The app's own pictures (the mascot) come from its bundle, which a test run does not have:
        // point the test runner's resources at the repo's brand files for these scenes.
        let resources = root.appending(path: "Resources")
        try fm.createDirectory(at: resources.appending(path: "Brand"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.repo.appending(path: "assets/brand/mascot.png"), to: resources.appending(path: "Brand/mascot.png"))
        ReleaseBundle.use(resources)
        defer { ReleaseBundle.use(nil) }

        // A made-up session to open: Maya's launch video.
        let session = root.appending(path: "Launches/2026-11-10-launch-video")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try Data(#"{"title":"Launch video","createdAt":"2026-11-10T10:00:00Z","named":true,"takes":[]}"#.utf8)
            .write(to: session.appending(path: "session.json"))
        let app = AppModel()
        app.library.setRoot(root)
        app.library.select(session)

        // Start (v2026.11): the mascot, one line, Record in the middle, the last session at the foot.
        await still("start", StartPanel(last: "How I film on my phone", lastPath: session.path).environment(app),
                    size: CGSize(width: 900, height: 620))

        // Effects: the Effects page of the Styles board with the 35 effects. The test runner has no
        // app bundle, so the effects go in as the library's own (same cards, same board).
        let own = EffectLib.own(root: root)
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        for d in try fm.contentsOfDirectory(at: Self.repo.appending(path: "effects"), includingPropertiesForKeys: nil)
        where fm.fileExists(atPath: d.appending(path: "effect.json").path) {
            let to = own.appending(path: d.lastPathComponent)
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            // The poster, not the video: a playing video does not show in an off-screen picture.
            for f in ["effect.json", "preview.png", "README.md"] where fm.fileExists(atPath: d.appending(path: f).path) {
                try fm.copyItem(at: d.appending(path: f), to: to.appending(path: f))
            }
        }
        let suite = "release-shots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("effects", forKey: "stylesPage")
        await still("effects", StylesBoard(root: root).environment(app).defaultAppStorage(defaults).tint(Theme.accent), size: CGSize(width: 1100, height: 1010), wait: 3)

        // Sound: the Made tab with three songs made with ElevenLabs Music, tagged, and the tag row.
        let audio = SoundLib.dir(root: root)
        let songs = [("Music/Chasing the Light.m4a", 148.0), ("SFX/Whoosh to hit.m4a", 2.0), ("SFX/Mouse click 2.m4a", 1.0),
                     ("Made/Moonlight piano over soft D&B v1.m4a", 94.0), ("Made/Heroic strings, slow build v2.m4a", 121.0),
                     ("Made/Lo-fi desk beat for a screen demo v1.m4a", 63.0)]
        for (f, seconds) in songs { try ReleaseAudio.silence(audio.appending(path: f), seconds: seconds) }
        SoundTags.save(["Made/Moonlight piano over soft D&B v1.m4a": ["Calm", "Education"],
                        "Made/Heroic strings, slow build v2.m4a": ["Launch", "Upbeat"],
                        "Made/Lo-fi desk beat for a screen demo v1.m4a": ["Calm", "Screen demo"]], to: audio)
        let doc = SessionDoc(url: session)
        await still("sound", SoundsPane(doc: doc, wide: true, startOn: "Made").environment(app), size: CGSize(width: 1000, height: 470), wait: 2.5)

        // Carousels: the How I built it template in the Desk look, with a Screen card per step.
        let cs = root.appending(path: "Carousels/2026-11-09-viral-carousels")
        try fm.createDirectory(at: cs, withIntermediateDirectories: true)
        var takes: [[String: Any]] = []
        for (i, name) in ["find what works", "talk it out", "build every slide"].enumerated() {
            let file = String(format: "take-%02d-screen.jpg", i + 1)
            try fm.copyItem(at: demo.appending(path: "screen-wide.jpg"), to: cs.appending(path: file))
            takes.append(["number": i + 1, "kind": "screen", "file": file, "startedAt": "2026-11-09T10:0\(i):00Z", "name": name, "keeper": false])
        }
        try JSONSerialization.data(withJSONObject: ["title": "Viral carousels", "createdAt": "2026-11-09T10:00:00Z", "named": true, "takes": takes])
            .write(to: cs.appending(path: "session.json"))
        var built = CarouselTemplate.built.slides(cs, title: "carousels that get saved")
        built[2].title = "1) *find out what already works*\nTakes reads my best posts and the ones that went viral."
        built[2].body = "(the top 10 are the plan)"
        built[3].title = "2) *talk it out*\nI send a voice note, it writes every slide."
        built[3].body = "(and I change anything)"
        await SlidePictures.shared.preload(built.flatMap { $0.loads(cs) })
        let shown = Array(built.prefix(4))
        let row = HStack(spacing: 18) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, sl in
                CarouselSlideView(slide: sl, index: i, total: built.count, place: .instagram, name: "Maya Chen", width: 270,
                                  style: SlideStyle(.desk), session: cs, exporting: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        await still("carousels", row, size: CGSize(width: 1210, height: 400), wait: 2)

        // Screen takes: the eight cursor looks, as the cursor-looks effect draws them: the first
        // two seconds of each look (a move onto Export and the click), from the effect's own preview.
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: Self.repo.appending(path: "effects/cursor-looks/preview-16x9.mp4")))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var frames: [NSImage] = []
        let fps = 12.0, each = 2.0
        for look in 0..<8 {
            for k in 0..<Int(each * fps) {
                let t = Double(look) * 4.2 + 0.2 + Double(k) / fps
                let cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                frames.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        let pick = FramePick()
        try await film("screen-cursor", FramePickView(pick: pick, frames: frames), size: CGSize(width: 960, height: 540),
                       seconds: Double(frames.count) / fps,
                       beats: (1..<frames.count).map { i in (Double(i) / fps, { pick.at = i }) })
    }
}

/// A film made of pictures: which one shows.
@MainActor @Observable final class FramePick {
    var at = 0
}

struct FramePickView: View {
    let pick: FramePick
    let frames: [NSImage]
    var body: some View {
        Image(nsImage: frames[pick.at]).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
    }
}

/// Points the test runner's Bundle.main resources at a folder (the mascot), then back.
enum ReleaseBundle {
    nonisolated(unsafe) static var folder: URL?
    nonisolated(unsafe) static var swapped = false
    static func use(_ url: URL?) {
        folder = url
        let want = url != nil
        guard want != swapped,
              let a = class_getInstanceMethod(Bundle.self, #selector(getter: Bundle.resourceURL)),
              let b = class_getInstanceMethod(Bundle.self, #selector(getter: Bundle.releaseShotsResourceURL)) else { return }
        method_exchangeImplementations(a, b)
        swapped = want
    }
}

extension Bundle {
    @objc dynamic var releaseShotsResourceURL: URL? {
        // After the swap this name calls the original getter.
        if self === Bundle.main, let f = ReleaseBundle.folder { return f }
        return releaseShotsResourceURL
    }
}

/// Silent songs of a real length, so the rows show their times.
enum ReleaseAudio {
    static func silence(_ url: URL, seconds: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050,
                                                               AVNumberOfChannelsKey: 1])
        let n = AVAudioFrameCount(22050 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buf.frameLength = n
        buf.floatChannelData![0].update(repeating: 0, count: Int(n))
        try file.write(from: buf)
    }
}

/// The search scene's state: which hit the results page shows.
@MainActor @Observable final class SearchPick {
    var at = 0
}

struct SearchPickView: View {
    let pick: SearchPick
    let hits: [MediaSearch.Hit]
    let root: URL
    var body: some View {
        SearchPreview(hit: hits[pick.at], root: root, moments: [], open: { _ in }).id(pick.at)
    }
}

/// The chat's foot as it looks while the agent runs commands: its last words, the commands, the box.
@MainActor @Observable final class RunningDemo {
    var shown = 0
    var stopped = false
}

struct RunningDemoView: View {
    let demo: RunningDemo
    let commands = [AgentCommand(pid: 1, command: "npm run dev", seconds: 74, port: 5173),
                    AgentCommand(pid: 2, command: "python3 watch_renders.py --folder edits", seconds: 312)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The preview runs at localhost:5173, and I'm watching edits/ for new renders. Stop either one below.")
                .font(Theme.sans(13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                ForEach(Array(commands.prefix(demo.shown).enumerated()), id: \.element.id) { i, c in
                    if !(demo.stopped && i == 1) { AgentCommandChip(command: c) {} }
                }
            }
            HStack {
                Text("Ask Takes…").font(Theme.sans(13)).foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
