import AppKit
import SwiftUI

/// The welcome on the first launch (2026-10-06, prototype): three pages in a modal over the
/// window. 1: who does what (you talk, Takes does the rest). 2: how you work (the prompter, then
/// the chat). 3: the first step: type an idea and Takes writes the script, or record at once.
/// Shown once, to a library without projects. Help › Show Welcome Again shows it again.
@MainActor @Observable
final class Onboarding {
    static let shared = Onboarding()
    static let doneKey = "onboarded"
    static let pages = 3
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

    /// First launch only. A library with projects in it means someone uses Takes already.
    func startIfNew(_ library: Library) {
        let d = UserDefaults.standard
        guard !shown, !d.bool(forKey: Self.doneKey) else { return }
        if !library.projects.isEmpty { d.set(true, forKey: Self.doneKey); return }
        show()
    }

    func show() { page = 0; forward = true; shown = true }

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

    /// Writing a script needs only Claude. ffmpeg comes in later, for the edit.
    static var canWrite: Bool { Setup.shared.claude == .ok && Setup.shared.signedIn == .ok }

    static func ask(_ idea: String) -> String {
        "Write a short video script about: \(idea). Keep it under a minute, in my words, and put it in the session's script."
    }

    /// The idea goes to the chat of a new session, and the window opens on Script with the chat
    /// open, so the script shows up where it will be read.
    func write(_ idea: String, app: AppModel) {
        let idea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty, Self.canWrite, let doc = app.library.createSession() else { return }
        // Named after the idea, before the chat starts: a rename moves the folder the chat works in.
        app.rename(doc, to: idea, named: true)
        app.chats.open = true
        // On the Script tab, beside the docked chat: the script Takes writes shows up where the
        // new user is looking.
        app.chats.docked = true
        app.chats.chat(doc.url).send(Self.ask(idea), title: doc.meta.title, onStage: nil)
        SessionMode.set(.write)
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

    @ViewBuilder private func page(_ i: Int) -> some View {
        switch i {
        case 0: WelcomePage()
        case 1: HowPage()
        default: StartPage(flow: flow)
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
                Button("Skip") { flow.finish() }.buttonStyle(BracketButtonStyle())
            }
            if flow.page > 0 {
                Button("Back") { flow.go(flow.page - 1) }.buttonStyle(AccentButtonStyle(kind: .quiet))
            }
            if flow.page < Onboarding.pages - 1 {
                Button { flow.go(flow.page + 1) } label: {
                    HStack(spacing: 6) { Text("Next"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)) }
                }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Look around first") { flow.finish() }.buttonStyle(AccentButtonStyle(kind: .quiet))
            }
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

/// 2. How you work: one picture. The script beside the camera, and under it the ask.
private struct HowPage: View {
    var body: some View {
        PageFrame(title: "Record, then just ask.",
                  text: "Your script scrolls next to the camera. Then tell Takes what you want.",
                  after: 2) {
            VStack(spacing: 14) {
                stage.arrive(0)
                TypedAsk().arrive(1)
            }
            .frame(width: 540)
            .padding(.top, 36)
        }
    }

    /// The camera on the left, the script on the right, the line you read marked in red.
    private var stage: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let face = Onboarding.creator {
                    Image(nsImage: face).resizable().interpolation(.high).scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.75), Theme.secondary.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "person.fill").font(.system(size: 92)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).offset(y: 14)
                }
                HStack(spacing: 5) {
                    BlinkingDot()
                    Text("REC").font(Theme.mono(10, .bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(10)
            }
            .frame(width: 240).clipped()
            ScrollingScript()
        }
        .frame(height: 168)
        .background(Theme.stage)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The script as it runs in the prompter: one line after the other moves up to the red mark.
private struct ScrollingScript: View {
    @Environment(\.accessibilityReduceMotion) var still
    /// The creator reads what Takes does, so the picture explains the app while it moves.
    static let lines = ["Hi, this is Takes.", "Tell it your idea.", "It writes your script.",
                        "You read it right here.", "Takes cuts the video", "and writes the posts."]
    /// The read line, in three copies of the script: the middle copy is on screen, so a line
    /// always sits above and below, and the jump back to the start is not seen.
    @State private var at = lines.count
    let row: CGFloat = 32

    private func line(_ i: Int) -> some View {
        let d = abs(i - at)
        return Text(Self.lines[i % Self.lines.count])
            .foregroundStyle(.white.opacity(d == 0 ? 1 : d == 1 ? 0.45 : 0.18))
            .frame(height: row, alignment: .leading)
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<Self.lines.count * 3, id: \.self) { i in line(i) }
                }
                .padding(.leading, 26)
                .offset(y: g.size.height / 2 - (CGFloat(at) + 0.5) * row)
                Capsule().fill(Theme.danger).frame(width: 3, height: 18)
                    .position(x: 13, y: g.size.height / 2)
            }
        }
        .font(Theme.sans(15, .semibold))
        .frame(maxWidth: .infinity)
        .clipped()
        .task {
            guard !still else { return }
            let n = Self.lines.count
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5 * Onboarding.pace))
                withAnimation(.easeInOut(duration: 0.55 * Onboarding.pace)) { at += 1 }
                if at >= 2 * n {
                    try? await Task.sleep(for: .seconds(0.6 * Onboarding.pace))
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { at -= n }
                }
            }
        }
    }
}

private struct BlinkingDot: View {
    @Environment(\.accessibilityReduceMotion) var still
    @State private var dim = false

    var body: some View {
        Circle().fill(Theme.danger).frame(width: 7, height: 7)
            .opacity(dim ? 0.25 : 1)
            // Steps, not a repeatForever: an endless animation redraws the window every frame.
            .task {
                guard !still else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.8 * Onboarding.pace))
                    withAnimation(.easeInOut(duration: 0.3 * Onboarding.pace)) { dim.toggle() }
                }
            }
    }
}

/// The chat box. The ask types itself in once the page is in, and the send button answers.
private struct TypedAsk: View {
    @Environment(\.accessibilityReduceMotion) var still
    static let ask = "Make a short from my best take."
    @State private var typed = 0
    @State private var sent = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                Text(Self.ask.prefix(typed)).font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                if typed < Self.ask.count { Rectangle().fill(Theme.accent).frame(width: 1.5, height: 16) }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(typed == Self.ask.count ? 1 : 0.35), in: Circle())
                .scaleEffect(sent ? 1.12 : 1)
        }
        .padding(.leading, 18).padding(.trailing, 6)
        .frame(height: 42)
        .background(Theme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
        .task {
            guard !still else { typed = Self.ask.count; return }
            try? await Task.sleep(for: .seconds(0.9 * Onboarding.pace))
            while typed < Self.ask.count && !Task.isCancelled {
                typed += 1
                try? await Task.sleep(for: .milliseconds(38 * Onboarding.pace))
            }
            withAnimation(.smooth(duration: 0.2 * Onboarding.pace)) { sent = true }
            try? await Task.sleep(for: .seconds(0.2 * Onboarding.pace))
            withAnimation(.smooth(duration: 0.3 * Onboarding.pace)) { sent = false }
        }
    }
}

/// 3. The first step. With setup left to do, the steps come first (1), then the idea (2).
private struct StartPage: View {
    @Environment(AppModel.self) var app
    var flow: Onboarding
    private var setup = Setup.shared
    @State private var idea = ""
    @FocusState private var typing: Bool

    init(flow: Onboarding) { self.flow = flow }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 8) {
                Text("Make your first video.").font(Theme.display(36))
                Text("Tell Takes your idea. It writes the script into a new session, and you read it on camera.")
                    .font(Theme.sans(14.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: 580)
                Text(Onboarding.sessionLine)
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                    .frame(maxWidth: 580)
            }
            .arrive(0)
            .padding(.bottom, 28)
            VStack(alignment: .leading, spacing: 14) {
                if setup.needed { connect }
                ideaBox
            }
            .frame(width: 660)
            .arrive(1)
            HStack(spacing: 10) {
                Rule().frame(width: 60)
                Text("or").font(Theme.sans(12)).foregroundStyle(Theme.faint)
                Rule().frame(width: 60)
            }
            .padding(.vertical, 14)
            .arrive(2)
            Button { flow.recordNow(app: app) } label: {
                HStack(spacing: 8) {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    Text("Record without a script")
                }
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .arrive(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 20)
        // The cursor waits in the field, so typing the idea is the first thing that works.
        .onAppear { if Onboarding.canWrite { DispatchQueue.main.async { typing = true } } }
        .onChange(of: Onboarding.canWrite) { _, ready in if ready { typing = true } }
        .background(alignment: .top) {
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 380)
                .frame(height: 300).allowsHitTesting(false)
        }
    }

    private func number(_ n: Int, done: Bool = false) -> some View {
        ZStack {
            Circle().fill(done ? Theme.live : Theme.accent)
            if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)) }
            else { Text("\(n)").font(Theme.mono(11, .bold)) }
        }
        .foregroundStyle(Theme.paper)
        .frame(width: 20, height: 20)
    }

    /// The three setup steps, in one line each.
    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                number(1, done: Onboarding.canWrite)
                Text("Connect Takes to Claude").font(Theme.sans(13.5, .semibold))
                Spacer()
                Text("About 2 minutes").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 8) {
                item("Claude Code", setup.claude, "Install", setup.installClaude)
                item("Sign in", setup.claude == .ok ? setup.signedIn : .missing, "Sign in", setup.signIn,
                     enabled: setup.claude == .ok)
                item("Video tools", setup.ffmpeg, "Get", setup.installFFmpeg)
            }
        }
        .card(padding: 14)
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
        .padding(.horizontal, 10).frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private var ideaBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            if setup.needed {
                HStack(spacing: 8) {
                    number(2)
                    Text("Tell Takes your idea").font(Theme.sans(13.5, .semibold))
                }
            }
            HStack(spacing: 10) {
                TextField("What is your video about?", text: $idea, prompt: Text("What is your video about?").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(Theme.sans(15)).focusEffectDisabled()
                    .focused($typing)
                    .disabled(!Onboarding.canWrite)
                    .onSubmit(write)
                Button(action: write) {
                    HStack(spacing: 6) { Text("Write my script"); Image(systemName: "return").font(.system(size: 10, weight: .bold)) }
                }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                .disabled(idea.trimmingCharacters(in: .whitespaces).isEmpty || !Onboarding.canWrite)
            }
            .padding(.leading, 18).padding(.trailing, 6).frame(height: 48)
            // Two fills, no stroke: a stroked capsule this tall drew short bars past both ends.
            .background {
                ZStack {
                    Capsule().fill(Theme.accent.opacity(0.5))
                    Capsule().fill(Theme.paper).padding(1.5)
                }
            }
            HStack(spacing: 6) {
                ForEach(["How I plan my week", "A tool I use every day", "My biggest mistake this year"], id: \.self) { s in
                    Button { idea = s; typing = true } label: { Text(s) }.buttonStyle(BracketButtonStyle())
                        .disabled(!Onboarding.canWrite)
                }
            }
        }
        .padding(setup.needed ? 14 : 0)
        .background { if setup.needed { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border) } }
    }

    private func write() { flow.write(idea, app: app) }
}
