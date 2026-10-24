import AppKit
import AVFoundation
import SwiftUI

/// The welcome on the first launch (2026-10-06; four pages since 2026-10-22). 1: who does what (you
/// talk, Takes does the rest). 2: do you have an idea, and where does the video go. 3: the idea:
/// type it and Takes starts writing, or say what you do and Takes suggests three. 4: the look:
/// one of the styles Takes ships, or "Your own" from up to 3 videos. Nothing waits: the script is
/// written while the look is picked, and your own style is made in the Styles chat after Done.
/// Shown once, to a library without projects. Help › Show Welcome Again shows it again.
@MainActor @Observable
final class Onboarding {
    static let shared = Onboarding()
    static let doneKey = "onboarded"
    static let pages = 4
    /// How slow the welcome's motion runs: 1 in the app. The films in OnboardingShots slow it down,
    /// because a frame drawn off screen takes longer than a frame of the animation.
    static var pace = 1.0
    /// The creator in the camera on page 2: Sam, one of the made-up creators of the public
    /// pictures (scripts/public/demo-media). Without the file, a plain figure stands in.
    static var creator: NSImage? = Bundle.main.resourceURL
        .flatMap { NSImage(contentsOf: $0.appending(path: "Onboarding/creator.jpg")) }

    var shown = false
    var page = 0
    /// Which way the last page change went, so the pages slide the right way.
    var forward = true

    /// Page 2: "I have an idea", or "Not yet" and Takes suggests three.
    var hasIdea = true
    /// Where the first video goes; nil is "Not sure yet". It sets the shape and the length.
    var postOn: Post? = .linkedin
    /// The idea, typed or picked from the suggestions.
    var idea = ""
    /// The session the idea went to, once Takes started writing.
    private var startedDoc: SessionDoc?
    var started: URL? { startedDoc?.url }
    /// The look on page 4: a style's name, or nil for "Your own".
    var look: String? = "Magazine"
    /// Page 4 shows the stage for your own look.
    var ownStage = false
    /// "Your own": up to 3 videos or images, and a link or words.
    var ownFiles: [URL] = []
    var ownWords = ""

    enum Post: String, CaseIterable, Identifiable {
        case linkedin = "LinkedIn", youtube = "YouTube", shorts = "Shorts and Reels"
        var id: String { rawValue }
        /// What the chat hears: the shape and the length that fit.
        var line: String {
            switch self {
            case .linkedin: "It goes on LinkedIn: a tall video, under 90 seconds."
            case .youtube: "It goes on YouTube: a wide 16:9 video, 3 to 6 minutes."
            case .shorts: "It goes on Shorts and Reels: a tall 9:16 video, under 45 seconds."
            }
        }
    }

    /// The styles Takes ships (styles/ in the repo), in the order page 4 shows them.
    static let looks: [(name: String, note: String)] = [
        ("Magazine", "Paper pages, serif"), ("Bold Captions", "Yellow words, fast cuts"),
        ("Clean Studio", "Calm, white type"), ("Field Notes", "Paper, maps, marker"),
        ("Cinematic", "Dark grade, wide bars")]

    /// A look's tile: the picture in the app (a made-up creator in that look), else its preview.
    static var tiles = Bundle.main.resourceURL?.appending(path: "Onboarding/styles")
    static func tile(_ name: String, root: URL) -> NSImage? {
        if let i = tiles.flatMap({ NSImage(contentsOf: $0.appending(path: "\(name).jpg")) }) { return i }
        return NSImage(contentsOf: StyleLib.style(name, root: root).appending(path: "preview.png"))
    }

    /// First launch only. A library with projects in it means someone uses Takes already.
    func startIfNew(_ library: Library) {
        let d = UserDefaults.standard
        guard !shown, !d.bool(forKey: Self.doneKey) else { return }
        if !library.projects.isEmpty { d.set(true, forKey: Self.doneKey); return }
        show()
        Self.fillScreen()
    }

    /// The first launch goes full screen (2026-10-12: in the small window the welcome, the app
    /// and the notch felt noisy to new users). Only then: after that, macOS keeps what they pick.
    static func fillScreen() {
        guard !AppModel.testing else { return }
        mainWindow { w in
            if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
    }

    static let bigKey = "windowMadeBig"

    /// The fallback (2026-10-13: a new user's Takes opened in the 960-wide minimum window). Once per
    /// Mac, a window at about the minimum size grows to fill the screen, full screen or not. A
    /// window someone made big already stays as it is; one they shrink later stays small.
    static func bigWindowOnce() {
        guard !AppModel.testing, !UserDefaults.standard.bool(forKey: bigKey) else { return }
        mainWindow { w in
            UserDefaults.standard.set(true, forKey: bigKey)
            guard let screen = w.screen ?? NSScreen.main, !w.styleMask.contains(.fullScreen) else { return }
            let area = screen.visibleFrame
            if w.frame.width < min(1200, area.width * 0.8) || w.frame.height < min(760, area.height * 0.8) {
                w.setFrame(area, display: true)
            }
        }
    }

    /// The main window, once it is on screen: at launch it can come a moment after the first
    /// task runs, so this looks again for up to 3 seconds.
    private static func mainWindow(tries: Int = 15, _ act: @escaping @MainActor (NSWindow) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }) {
                    act(w)
                } else if tries > 1 {
                    mainWindow(tries: tries - 1, act)
                }
            }
        }
    }

    func show() {
        page = 0; forward = true; shown = true
        hasIdea = true; idea = ""; startedDoc = nil; look = "Magazine"; ownStage = false; ownFiles = []; ownWords = ""
    }

    func go(_ to: Int) {
        guard (0..<Self.pages).contains(to) else { return }
        forward = to > page
        withAnimation(Theme.spring) { page = to }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        withAnimation(Theme.motion) { shown = false }
    }

    /// Sessions vs projects, in one line (2026-10-08: a new user did not know what a session is).
    static let sessionLine = "A session is one video: its script, takes, edits and posts. A project holds sessions, like a folder."

    /// Writing a script needs only a signed-in agent. ffmpeg comes in later, for the edit.
    static var canWrite: Bool { Setup.shared.agent == .ok && Setup.shared.signedIn == .ok }

    static func ask(_ idea: String, on post: Post? = nil) -> String {
        guard let post else {
            return "Write a short video script about: \(idea). Keep it under a minute, in my words, and put it in the session's script."
        }
        return "Write a video script about: \(idea). \(post.line) In my words, and put it in the session's script."
    }

    /// Takes starts writing at once, in a new session named after the idea, while the look is
    /// picked. Before setup is done the session is there and the ask waits for it.
    func write(_ idea: String, app: AppModel) {
        let idea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return }
        self.idea = idea
        let doc: SessionDoc
        if let d = startedDoc {
            guard d.meta.title != idea else { return }  // the same idea again: it is being written
            doc = d
        } else {
            guard let d = app.library.createSession() else { return }
            doc = d
        }
        // Named after the idea, before the chat starts: a rename moves the folder the chat works in.
        app.rename(doc, to: idea, named: true)
        startedDoc = doc
        if let look { StyleLib.choose(look, project: doc.url.deletingLastPathComponent()) }
        let ask = Self.ask(idea, on: postOn)
        let send = { @MainActor in app.chats.chat(doc.url).send(ask, title: doc.meta.title, onStage: nil) }
        if Self.canWrite { send(); return }
        Task { @MainActor in
            // Setup ends with a click in Terminal or a download: look again each second, for an hour.
            for _ in 0..<3600 where !Self.canWrite {
                try? await Task.sleep(for: .seconds(1))
            }
            if Self.canWrite { send() }
        }
    }

    /// The last button: the look goes to the project, the window opens on Script beside the docked
    /// chat, so the script shows up where it will be read. Your own look is made in the Styles chat.
    func done(app: AppModel) {
        if look == nil && (!ownFiles.isEmpty || !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            makeOwn(app: app)
        }
        if started == nil, !idea.trimmingCharacters(in: .whitespaces).isEmpty { write(idea, app: app) }
        if let s = started {
            StyleLib.choose(look ?? "Magazine", project: s.deletingLastPathComponent())
            app.chats.open = true
            app.chats.docked = true
            SessionMode.set(.write)
        }
        finish()
    }

    /// One idea Takes suggests on page 3b.
    struct Suggestion: Hashable {
        var title: String
        var kind: String
        var why: String
    }

    /// Three videos for this week, from what you do: the agent's small model, no tools. Lines of
    /// "title | KIND | why"; anything else in the reply is left out. Empty when it fails.
    static func suggest(_ about: String, on post: Post?) async -> [Suggestion] {
        let prompt = """
        Suggest three short talking-head videos this person can film this week. Each must be easy to say \
        on camera with no editing skills. Mix the kinds. Reply with exactly three lines and nothing else, \
        each line: title | KIND | why
        title: under 9 words, in the first person, no quotes. KIND: one of STORY, LIST, LESSON, HOW-TO. \
        why: under 8 words, why it works\(post.map { " on \($0.rawValue)" } ?? "").
        """
        let reply = await Agents.run(AgentRequest(prompt: prompt, input: "What I do: \(about)", speed: .fast, seconds: 60)).text ?? ""
        return parse(reply)
    }

    nonisolated static func parse(_ reply: String) -> [Suggestion] {
        let out = reply.split(whereSeparator: \.isNewline).compactMap { line -> Suggestion? in
            // A list marker ("1.", "-", "•") goes; a number that is part of the title stays.
            let bare = line.replacingOccurrences(of: #"^\s*([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            let parts = bare.split(separator: "|").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *\"\t")) }
            guard parts.count >= 3, !parts[0].isEmpty else { return nil }
            return Suggestion(title: parts[0], kind: parts[1].uppercased(), why: parts[2])
        }
        return Array(out.prefix(3))
    }

    /// A dropped file's card: the image, or a video's first frame.
    static func thumb(_ url: URL) async -> NSImage? {
        if let i = NSImage(contentsOf: url), i.isValid { return i }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// The Styles chat. Its history is one file for the whole Mac, so tests put a stand-in here.
    static var askStyles: @MainActor (AppModel, String) -> Void = { app, text in
        app.chats.styles.send(text, title: "Styles", onStage: nil)
    }

    /// The New style flow of the Styles board, started from here: the board's Making card shows it,
    /// and once its preview is there the project of the first video uses it.
    private func makeOwn(app: AppModel) {
        let x = (ownFiles.map(\.path) + [ownWords]).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let since = Date()
        Self.askStyles(app, StylesBoard.makeAsk(x))
        UserDefaults.standard.set(since.timeIntervalSince1970, forKey: "styleMakingSince")
        let root = app.library.root, project = started?.deletingLastPathComponent()
        Task { @MainActor in
            for _ in 0..<360 {
                try? await Task.sleep(for: .seconds(10))
                let found = StylesBoard.progress(root: root, since: since)
                guard let name = found.name,
                      FileManager.default.fileExists(atPath: StyleLib.style(name, root: root).appending(path: "preview.mp4").path)
                else { continue }
                if let project { StyleLib.choose(name, project: project) }
                app.show(toast: "Your style \(name) is ready", icon: "paintpalette")
                return
            }
        }
    }

    /// The demo session opens on its edit: what a finished video looks like before the first take.
    func example(app: AppModel) {
        Task { await Demo.shared.add(app.library) }
        finish()
    }

    /// An empty session on Record: the camera is ready, the script can wait.
    func recordNow(app: AppModel) {
        _ = app.library.createSession()
        SessionMode.set(.record)
        finish()
    }
}

/// The dim layer and the card, over the whole window.
struct OnboardingLayer: View {
    var flow = Onboarding.shared

    var body: some View {
        ZStack {
            if flow.shown {
                // Nearly opaque, in the window's own color: the app behind is a hint, not a second thing to read.
                Theme.canvas.opacity(0.97).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}  // the window stays out of reach
                    .transition(.opacity)
                OnboardingCard(flow: flow)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: flow.shown)
        // On its way out it takes no clicks (2026-10-15, Product Hunt on the newest macOS: Skip and
        // Write my script closed it, but the window stayed dead and had to be quit). The fade kept
        // every click for its 0.9 s, and an exit that never ends kept them for good.
        .allowsHitTesting(flow.shown)
    }
}

struct OnboardingCard: View {
    @Environment(AppModel.self) var app
    var flow: Onboarding
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(flow.page)
                    .id(flow.page)
                    .transition(.asymmetric(
                        insertion: .move(edge: flow.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: flow.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Rule()
            footer
        }
        .frame(width: 760, height: 556)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { flow.go(flow.page + 1); return .handled }
        .onKeyPress(.leftArrow) { flow.go(flow.page - 1); return .handled }
        .onExitCommand { flow.finish() }
    }

    private var own: Bool { flow.look == nil }

    private var nextTitle: String {
        switch flow.page {
        case 2: flow.hasIdea ? "Next: the look" : "Use this idea"
        case 3: own ? "Make it" : "Use \(flow.look ?? "it")"
        default: "Next"
        }
    }

    private var nextReady: Bool {
        switch flow.page {
        case 2: flow.hasIdea || !flow.idea.isEmpty
        case 3: !own || !flow.ownFiles.isEmpty || !flow.ownWords.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private func next() {
        switch flow.page {
        case 2:
            flow.write(flow.idea, app: app)
            flow.go(3)
        case 3: flow.done(app: app)
        default: flow.go(flow.page + 1)
        }
    }

    @ViewBuilder private func page(_ i: Int) -> some View {
        switch i {
        case 0: WelcomePage()
        case 1: IdeaPage(flow: flow)
        case 2: if flow.hasIdea { StartPage(flow: flow, onNext: next) } else { SuggestPage(flow: flow) }
        default: LookPage(flow: flow)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<Onboarding.pages, id: \.self) { i in
                    Capsule().fill(i == flow.page ? Theme.accent : Theme.border)
                        .frame(width: i == flow.page ? 22 : 7, height: 7)
                        .onTapGesture { flow.go(i) }
                }
            }
            .animation(Theme.spring, value: flow.page)
            Spacer()
            if flow.page < Onboarding.pages - 1 {
                // Esc too, from any page and whatever has focus (onExitCommand needs the card focused).
                Button("Skip") { flow.finish() }.buttonStyle(BracketButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if flow.page > 0 {
                Button("Back") {
                    if flow.page == 3 && flow.ownStage { withAnimation(Theme.spring) { flow.ownStage = false } }
                    else { flow.go(flow.page - 1) }
                }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
            }
            Button(action: next) {
                HStack(spacing: 6) { Text(nextTitle); Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)) }
            }
            .buttonStyle(AccentButtonStyle(kind: .accent))
            .keyboardShortcut(.defaultAction)
            .disabled(!nextReady)
            .animation(Theme.spring, value: nextTitle)
        }
        .padding(.horizontal, 24).frame(height: 64)
        .background(Theme.canvas)
    }
}

// MARK: - The pages

/// Every page: an illustration on a soft glow, then a title and two lines. FirstTake uses it too.
struct PageFrame<Art: View>: View {
    let title: String
    let text: String
    var note: String? = nil
    /// Where the title comes in the order: after the parts of the picture.
    var after = 1
    @ViewBuilder var art: Art

    var body: some View {
        VStack(spacing: 0) {
            art
                .frame(maxWidth: .infinity).frame(height: 290)
                .background {
                    ZStack {
                        RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 420)
                        RadialGradient(colors: [Theme.secondary.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 300)
                    }
                    .allowsHitTesting(false)
                }
            VStack(spacing: 10) {
                Text(title).font(Theme.display(36)).multilineTextAlignment(.center)
                    .arrive(after)
                Text(text).font(Theme.sans(14.5)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                    .arrive(after + 1)
                if let note {
                    Text(note).font(Theme.sans(12)).foregroundStyle(Theme.faint).padding(.top, 4)
                }
            }
            .padding(.top, 26).padding(.horizontal, 40)
            Spacer(minLength: 0)
        }
    }
}

/// 1. Who does what: you record, Takes writes, edits and posts.
private struct WelcomePage: View {
    @Environment(\.accessibilityReduceMotion) var still
    /// The step that is working now: 0 Record, 1 Script, 2 Edit, 3 Post. It walks on in a loop.
    @State private var active = -1

    var body: some View {
        PageFrame(title: "You talk. Takes does the rest.",
                  text: "Tell Takes your idea and it writes the script. You read it on camera. Takes cuts the video and writes the posts.",
                  after: 5) {
            HStack(alignment: .top, spacing: 14) {
                side("You", icon: nil, first: 0, steps: [("video.fill", "Record", "Read it on camera")])
                side("Takes", icon: NSApp.applicationIconImage, first: 1, steps: [("text.alignleft", "Script", "From your idea"), ("scissors", "Edit", "Cuts and captions"), ("paperplane.fill", "Post", "Every platform")])
            }
            .padding(.top, 30)
        }
        .task {
            guard !still else { return }
            try? await Task.sleep(for: .seconds(1.1 * Onboarding.pace))
            while !Task.isCancelled {
                withAnimation(.smooth(duration: 0.4 * Onboarding.pace)) { active = (active + 1) % 4 }
                try? await Task.sleep(for: .seconds(1.2 * Onboarding.pace))
            }
        }
    }

    private func side(_ who: String, icon: NSImage?, first: Int, steps: [(String, String, String)]) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18) }
                else { Image(systemName: "person.fill").font(.system(size: 11, weight: .semibold)) }
                Text(who).font(Theme.sans(12.5, .semibold))
            }
            .foregroundStyle(who == "You" ? Theme.ink : Theme.accentInk)
            .padding(.horizontal, 12).frame(height: 28)
            .background(who == "You" ? Theme.hover : Theme.accentSoft, in: Capsule())
            HStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    step(s, n: first + i, arrow: i > 0, takes: who != "You")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(who == "You" ? Theme.border : Theme.accent.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1, dash: who == "You" ? [4, 4] : [])))
        }
    }

    @ViewBuilder private func step(_ s: (String, String, String), n: Int, arrow: Bool, takes: Bool) -> some View {
        if arrow {
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                .foregroundStyle(active == n ? Theme.accentInk : Theme.faint)
                .arrive(n + 1)
        }
        tile(s.0, s.1, s.2, takes: takes, on: active == n).arrive(n + 1)
    }

    private func tile(_ icon: String, _ title: String, _ detail: String, takes: Bool, on: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .medium))
                .foregroundStyle(takes ? Theme.accentInk : Theme.ink)
                .frame(width: 52, height: 52)
                .background(takes ? Theme.accentSoft : Theme.hover, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 2) {
                Text(title).font(Theme.sans(13.5, .semibold))
                Text(detail).font(Theme.sans(11)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 118, height: 132)
        .card(padding: 0)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.accent.opacity(on ? 0.8 : 0), lineWidth: 1.5))
        .scaleEffect(on ? 1.04 : 1)
        .shadow(color: Theme.accent.opacity(on ? 0.25 : 0), radius: 12, y: 4)
    }
}

/// 2. Do you have an idea, and where does it go. The two ways to start without one stay here.
private struct IdeaPage: View {
    @Environment(AppModel.self) var app
    @Bindable var flow: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                choice(true, icon: "lightbulb", "I have an idea", "Takes writes the script").arrive(0)
                choice(false, icon: "sparkles", "Not yet", "Takes suggests three").arrive(1)
            }
            .padding(.top, 44)
            VStack(spacing: 8) {
                Text("Do you have a video idea?").font(Theme.display(34))
                Text("Then say where it goes. Takes sets the shape and the length.")
                    .font(Theme.sans(14.5)).foregroundStyle(Theme.muted)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 48)
            .arrive(2)
            HStack(spacing: 8) {
                Text("Post on").font(Theme.sans(12.5)).foregroundStyle(Theme.faint).padding(.trailing, 4)
                ForEach(Onboarding.Post.allCases) { p in chip(p.rawValue, on: flow.postOn == p) { flow.postOn = p } }
                chip("Not sure yet", on: flow.postOn == nil) { flow.postOn = nil }
            }
            .padding(.top, 22)
            .arrive(3)
            HStack(spacing: 18) {
                Button { flow.recordNow(app: app) } label: {
                    HStack(spacing: 7) { Circle().fill(Theme.danger).frame(width: 7, height: 7); Text("Record without a script") }
                }
                // The demo session: a finished video by a made-up creator, to see first (Demo.swift).
                Button { flow.example(app: app) } label: {
                    HStack(spacing: 6) { Image(systemName: "play.rectangle").font(.system(size: 11, weight: .semibold)); Text("See a finished example") }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            .padding(.top, 20)
            .arrive(4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 380)
                .frame(height: 300).allowsHitTesting(false)
        }
    }

    private func choice(_ yes: Bool, icon: String, _ title: String, _ detail: String) -> some View {
        let on = flow.hasIdea == yes
        return Button { withAnimation(Theme.spring) { flow.hasIdea = yes } } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accentInk)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(spacing: 3) {
                    Text(title).font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 214, height: 124)
            .background(on ? Theme.accentSoft.opacity(0.5) : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(on ? 1 : 0.98)
    }

    private func chip(_ title: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.spring) { pick() } } label: {
            Text(title).font(Theme.sans(12.5, .medium))
                .foregroundStyle(on ? Theme.accentInk : Theme.ink)
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? Theme.accentSoft : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.accent : Theme.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The setup, made small: one line while Takes gets ready (its steps open on a click), one line
/// with a check once it is ready. Pages 3a and 3b show it.
private struct SetupLine: View {
    private var setup = Setup.shared
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Theme.spring) { open.toggle() } } label: {
                HStack(spacing: 9) {
                    if setup.needed {
                        ProgressView().controlSize(.small)
                        Text("Takes is getting ready").font(Theme.sans(13, .semibold))
                        Spacer()
                        Capsule().fill(Theme.border).frame(width: 110, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accent).frame(width: 110 * CGFloat(4 - setup.left) / 4, height: 4)
                            }
                        Text("\(4 - setup.left) of 4 done").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    } else {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.live)
                        Text("Takes is ready").font(Theme.sans(13, .semibold))
                        Spacer()
                    }
                }
                .foregroundStyle(Theme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!setup.needed)
            if open && setup.needed {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        item(setup.agent == .ok ? setup.target.name : "Claude Code", setup.agent, "Install", setup.installAgent)
                        item("Sign in", setup.agent == .ok ? setup.signedIn : .missing, "Sign in", setup.signIn,
                             enabled: setup.agent == .ok)
                    }
                    HStack(spacing: 8) {
                        item("Video tools", setup.ffmpeg, "Get", setup.installFFmpeg)
                        item("Apple developer tools", setup.devTools, "Get", setup.installDevTools)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        // Steps left on a new Mac: open, so the first click is in sight.
        .onAppear { open = setup.needed && !Onboarding.canWrite }
    }

    private func item(_ title: String, _ status: Setup.Status, _ action: String, _ run: @escaping () -> Void,
                      enabled: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status == .ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14)).foregroundStyle(status == .ok ? Theme.live : Theme.faint)
            Text(title).font(Theme.sans(12.5, .medium)).lineLimit(1)
            Spacer(minLength: 4)
            if status == .working {
                ProgressView().controlSize(.mini)
            } else if status != .ok {
                Button(action: run) {
                    Text(action).font(Theme.sans(11.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!enabled)
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// A numbered box under the setup line: "2 Tell Takes your idea".
private struct NumberedBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("2").font(Theme.mono(11, .bold)).foregroundStyle(Theme.paper)
                    .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                Text(title).font(Theme.sans(13.5, .semibold))
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The page's title and its line, the same on 3a, 3b and 4.
private struct PageHead: View {
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 7) {
            Text(title).font(Theme.display(32))
            Text(text).font(Theme.sans(14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 600)
        }
        .multilineTextAlignment(.center)
    }
}

/// 3a. The idea. Write my script starts the writing at once and goes on to the look.
private struct StartPage: View {
    @Bindable var flow: Onboarding
    let onNext: () -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 14) {
            PageHead(title: "Make your first video.",
                     text: "Tell Takes your idea. It writes the script into a new session, and you read it on camera.")
                .arrive(0).padding(.top, 30).padding(.bottom, 8)
            SetupLine().arrive(1)
            NumberedBox(title: "Tell Takes your idea") {
                HStack(spacing: 10) {
                    TextField("What is your video about?", text: $flow.idea, prompt: Text("What is your video about?").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).font(Theme.sans(15)).focusEffectDisabled()
                        .focused($typing)
                        .onSubmit(next)
                    Button(action: next) {
                        HStack(spacing: 6) { Text("Write my script"); Image(systemName: "return").font(.system(size: 10, weight: .bold)) }
                    }
                    .buttonStyle(AccentButtonStyle(kind: .accent))
                    .disabled(flow.idea.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, 16).padding(.trailing, 6).frame(height: 46)
                // Two fills, no stroke: a stroked capsule this tall drew short bars past both ends.
                .background {
                    ZStack {
                        Capsule().fill(Theme.accent.opacity(0.5))
                        Capsule().fill(Theme.paper).padding(1.5)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(["How I plan my week", "A tool I use every day", "My biggest mistake this year"], id: \.self) { s in
                        Button { flow.idea = s; typing = true } label: { Text(s) }.buttonStyle(BracketButtonStyle(active: flow.idea == s))
                    }
                }
            }
            .arrive(2)
            Text(Onboarding.canWrite ? "Takes writes while you pick the look." : "Takes starts writing when setup is done. You pick the look while it writes.")
                .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                .arrive(3)
            Spacer(minLength: 0)
        }
        .frame(width: 660)
        .frame(maxWidth: .infinity)
        // The cursor waits in the field, so typing the idea is the first thing that works.
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func next() {
        guard !flow.idea.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onNext()
    }
}

/// 3b. Not yet: say what you do, and Takes suggests three videos for this week.
private struct SuggestPage: View {
    @Bindable var flow: Onboarding
    @State private var what = ""
    @State private var ideas: [Onboarding.Suggestion] = []
    @State private var busy = false
    @State private var failed = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 14) {
            PageHead(title: "Let us find your first video.",
                     text: "Say what you do. Takes suggests three videos you can make this week.")
                .arrive(0).padding(.top, 30).padding(.bottom, 8)
            SetupLine().arrive(1)
            NumberedBox(title: "What do you do?") {
                HStack(spacing: 10) {
                    TextField("", text: $what, prompt: Text("I run a small design studio in Berlin").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).font(Theme.sans(15)).focusEffectDisabled()
                        .focused($typing)
                        .onSubmit(suggest)
                    Button(action: suggest) {
                        HStack(spacing: 6) {
                            if busy { ProgressView().controlSize(.mini) }
                            Text(ideas.isEmpty ? "Suggest" : "New ideas")
                        }
                    }
                    .buttonStyle(AccentButtonStyle(kind: ideas.isEmpty ? .accent : .quiet))
                    .disabled(what.trimmingCharacters(in: .whitespaces).isEmpty || busy || !Onboarding.canWrite)
                }
                .padding(.leading, 16).padding(.trailing, 6).frame(height: 46)
                .background(Theme.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border))
                ForEach(Array(ideas.enumerated()), id: \.element) { i, s in
                    row(s).transition(.opacity.combined(with: .move(edge: .bottom))).arrive(i)
                }
                if failed {
                    Text("Takes could not suggest ideas this time. Try again, or go Back and type your own.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                } else if !Onboarding.canWrite {
                    Text("Takes suggests ideas once setup is done.").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                }
            }
            .arrive(2)
            Spacer(minLength: 0)
        }
        .frame(width: 660)
        .frame(maxWidth: .infinity)
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func row(_ s: Onboarding.Suggestion) -> some View {
        let on = flow.idea == s.title
        return Button { withAnimation(Theme.spring) { flow.idea = s.title } } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(Theme.sans(13.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(s.why).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(s.kind).font(Theme.mono(10, .bold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(on ? Theme.accentSoft.opacity(0.5) : Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.accent : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func suggest() {
        let about = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !about.isEmpty, !busy, Onboarding.canWrite else { return }
        busy = true; failed = false
        let post = flow.postOn
        Task {
            let got = await Onboarding.suggest(about, on: post)
            busy = false
            failed = got.isEmpty
            withAnimation(Theme.spring) {
                if !got.isEmpty { ideas = got; flow.idea = got[0].title }
            }
        }
    }
}

/// 4. The look: the styles Takes ships, and "Your own" from up to 3 videos.
private struct LookPage: View {
    @Environment(AppModel.self) var app
    @Bindable var flow: Onboarding

    var body: some View {
        ZStack {
            if flow.ownStage {
                OwnLook(flow: flow).transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                tiles.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) { writing.padding(16) }
    }

    /// "Takes is writing your script", while it does: nothing waits for the look.
    @ViewBuilder private var writing: some View {
        if let s = flow.started, app.chats.chat(s).running {
            HStack(spacing: 7) {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
                Text("Takes is writing your script").font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .transition(.opacity)
        }
    }

    private var tiles: some View {
        VStack(spacing: 0) {
            PageHead(title: "How should your videos look?",
                     text: "Takes edits every video in this look: captions, colors, cuts and music. You can change it for one video at any time.")
                .arrive(0).padding(.top, 40)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(Onboarding.looks.enumerated()), id: \.offset) { i, l in
                    tile(l.name, l.note).arrive(i + 1)
                }
                ownTile.arrive(Onboarding.looks.count + 1)
            }
            .padding(.top, 26)
            Spacer(minLength: 0)
        }
    }

    private func tile(_ name: String, _ note: String) -> some View {
        let on = flow.look == name
        return Button { withAnimation(Theme.spring) { flow.look = name } } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    if let img = Onboarding.tile(name, root: app.library.root) {
                        Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: 100, height: 168).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(on ? 1 : 0), lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(note).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 3)
            }
            .frame(width: 106, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ownTile: some View {
        Button {
            withAnimation(Theme.spring) { flow.look = nil; flow.ownStage = true }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.border).frame(width: 40, height: 52).rotationEffect(.degrees(-10)).offset(x: -6, y: 4)
                        RoundedRectangle(cornerRadius: 7).fill(Theme.faint.opacity(0.5)).frame(width: 40, height: 52).rotationEffect(.degrees(8)).offset(x: 4, y: 2)
                        RoundedRectangle(cornerRadius: 7).fill(Theme.accent).frame(width: 40, height: 52)
                            .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white))
                    }
                    Text("Drop videos you like").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center).padding(.horizontal, 8)
                }
                .frame(width: 100, height: 168)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.faint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .padding(3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                    Text("From up to 3 videos").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 3)
            }
            .frame(width: 106, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 4b. Your own look: the New style stage. Each dropped video or image pops in as a card.
private struct OwnLook: View {
    @Bindable var flow: Onboarding
    @State private var over = false
    @State private var thumbs: [URL: NSImage] = [:]

    var body: some View {
        VStack(spacing: 14) {
            PageHead(title: "Show Takes a look you like.",
                     text: "Takes turns it into a style that every video can use. Your script keeps going.")
                .padding(.top, 26)
            stage
            HStack(spacing: 9) {
                Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Theme.faint)
                TextField("", text: $flow.ownWords, prompt: Text("Paste a link, or say what you like about it").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(Theme.sans(13)).focusEffectDisabled()
            }
            .padding(.horizontal, 13).frame(height: 40)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            Spacer(minLength: 0)
        }
        .frame(width: 660)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $over) { providers in
            NewStyleSheet.urls(from: providers) { add($0) }
            return true
        }
    }

    private var stage: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            if flow.ownFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.faint)
                    Text(over ? "Let go to add it" : "Drop a video or an image").font(Theme.sans(13.5, .semibold))
                    Button("choose a file", action: choose).buttonStyle(.plain)
                        .font(Theme.sans(12)).foregroundStyle(Theme.accentInk)
                }
            } else {
                HStack(spacing: 14) {
                    ForEach(Array(flow.ownFiles.enumerated()), id: \.element) { i, url in
                        card(url, tilt: [-5.0, 4, -2][i % 3])
                            .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .offset(y: -60)).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                Text("\(flow.ownFiles.count) of \(NewStyleSheet.most)").font(Theme.sans(11.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 24).background(Theme.accent, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                if flow.ownFiles.count < NewStyleSheet.most {
                    Button("Add another", action: choose).buttonStyle(BracketButtonStyle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 230)
        .background(Theme.surface.opacity(over ? 1 : 0.6), in: shape)
        .overlay(shape.strokeBorder(Theme.accent.opacity(over ? 1 : 0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .animation(.spring(response: 0.45, dampingFraction: 0.62), value: flow.ownFiles)
    }

    private func card(_ url: URL, tilt: Double) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let t = thumbs[url] { Image(nsImage: t).resizable().scaledToFill() }
                else { Theme.hover.overlay(Image(systemName: "film").foregroundStyle(Theme.faint)) }
            }
            .frame(width: 104, height: 156).clipped()
            Button { flow.ownFiles.removeAll { $0 == url } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain).padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .rotationEffect(.degrees(tilt))
        .help(url.lastPathComponent)
    }

    private func add(_ url: URL) {
        guard flow.ownFiles.count < NewStyleSheet.most, !flow.ownFiles.contains(url) else { return }
        flow.ownFiles.append(url)
        Task {
            if let t = await Onboarding.thumb(url) { thumbs[url] = t }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image]
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }
}
