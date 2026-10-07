import AppKit
import AVFoundation
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case camera = "Camera", cameraScreen = "Camera + Screen"
    var id: String { rawValue }
}

enum Phase: Equatable {
    case idle, countdown(Int), starting, recording(Date), finishing
}

// @Observable, not ObservableObject: a view now redraws only for the properties it reads. Before,
// every change (a toast, a notice, the file on the stage) redrew every view that held the model,
// and the menus with them (2026-10-02).
@MainActor
@Observable
final class AppModel {
    let library = Library()
    let camera = CameraRecorder()
    let screen = ScreenRecorder()
    /// The song under the video (Sounds.swift).
    let bed = MusicBed()
    /// Claude chats, one per session (Chat.swift).
    let chats = ChatHub()
    /// Posts marked ready, scheduled or posted, with their times.
    let posts = PostQueue()

    @ObservationIgnored @AppStorage("mode") private var modeStore: Mode = .camera
    @ObservationIgnored @AppStorage("countdown") private var countdownStore = true
    @ObservationIgnored @AppStorage("autoScroll") private var autoScrollStore = true
    @ObservationIgnored @AppStorage("speed") private var speedStore: Double = 40
    @ObservationIgnored @AppStorage("fontSize") private var fontSizeStore: Double = 34
    // The iPhone app keeps the same name for its switch.
    @ObservationIgnored @AppStorage("prompterFollowVoice") private var followVoiceStore = true
    var mode: Mode {
        get { access(keyPath: \.mode); return modeStore }
        set { withMutation(keyPath: \.mode) { modeStore = newValue } }
    }
    var countdownOn: Bool {
        get { access(keyPath: \.countdownOn); return countdownStore }
        set { withMutation(keyPath: \.countdownOn) { countdownStore = newValue } }
    }
    var autoScroll: Bool {
        get { access(keyPath: \.autoScroll); return autoScrollStore }
        set { withMutation(keyPath: \.autoScroll) { autoScrollStore = newValue } }
    }
    var speed: Double {
        get { access(keyPath: \.speed); return speedStore }
        set { withMutation(keyPath: \.speed) { speedStore = newValue } }
    }
    var fontSize: Double {
        get { access(keyPath: \.fontSize); return fontSizeStore }
        set { withMutation(keyPath: \.fontSize) { fontSizeStore = newValue } }
    }
    /// Voice follow (2026-10-07): the prompters keep your place as you talk. Off: they scroll at `speed`.
    var followVoice: Bool {
        get { access(keyPath: \.followVoice); return followVoiceStore }
        set { withMutation(keyPath: \.followVoice) { followVoiceStore = newValue }; syncVoice() }
    }
    let voice = VoiceFollow()
    /// The prompters follow the voice now. False while it can't hear (they scroll at `speed`).
    var following: Bool { followVoice && !voice.failed }

    /// What every prompter shows: a storyboard shot's own lines, else the open script.
    var promptText: String { shot?.say ?? library.current?.activeText ?? "" }
    /// Changes when the prompters show another script (session, variant or shot).
    var promptKey: String {
        guard let doc = library.current else { return "" }
        return shot.map { "\(doc.url.path)#shot-\($0.id)" } ?? "\(doc.url.path)#\(doc.activeDraft)"
    }

    var phase: Phase = .idle { didSet { if phase != oldValue { holdCamera() } } }
    var error: String?
    var naming = false
    var scrolling = false {
        // Every teleprompter timer listens for this, including one whose view SwiftUI already replaced.
        didSet {
            if !scrolling { NotificationCenter.default.post(name: .takesStopScrolling, object: nil) }
            if scrolling != oldValue { syncVoice() }
        }
    }
    var resetToken = 0 { didSet { voice.jump(to: 0) } }

    /// Voice follow listens while the script plays.
    private func syncVoice() {
        if scrolling && followVoice { voice.start() } else { voice.stop() }
    }
    /// A take file playing in the left pane instead of the live camera.
    var preview: URL? {
        didSet {
            guard preview != oldValue else { return }
            effects.video = preview
            holdCamera()
            if preview.map({ Asset.kind(of: $0) != .video }) ?? true { player = nil }
        }
    }
    /// The post tab fills the window and hides the camera, so the camera can stop. It hides the
    /// player too, so a video that plays there stops.
    var postView = false {
        didSet {
            guard postView != oldValue else { return }
            if postView { player?.pause() }
            holdCamera()
        }
    }
    /// Storyboard and B-roll fill the stage too: the camera stops and a playing file pauses, as
    /// under Post. Before, both ran on unseen behind the tab (2026-10-03).
    var stageCovered = false {
        didSet {
            guard stageCovered != oldValue else { return }
            if stageCovered { player?.pause() }
            holdCamera()
        }
    }
    /// A board (performance, comments, styles, or a plugin's: Plugins.swift) fills the window in
    /// place of the sessions. Like the post tab, it hides the camera and the player. It stays shut
    /// while a take records.
    enum Board: Equatable { case performance, comments, styles, plugin(String) }
    var board: Board? {
        didSet {
            if board != nil && isRecording { board = nil; return }
            guard board != oldValue else { return }
            if board != nil { player?.pause() }
            holdCamera()
        }
    }
    /// Opens the board, or shuts it when it is already open.
    func toggle(_ b: Board) {
        if !Features.socialBoards, b == .performance || b == .comments { return }
        Perf.mark("board \(b)"); board = board == b ? nil : b
    }
    /// The file the Styles board plays on its left, for comments.
    var styleFile: URL?
    let performance = PerfBoard()
    /// The LinkedIn comment drafts and their reviews (Copilot.swift).
    let copilot = CopilotStore()
    /// The player of the file in `preview`, when it is a video. Set by PlayerView.
    @ObservationIgnored weak var player: AVPlayer? { didSet { if player !== oldValue { bed.attach(player); effects.attach(player) } } }
    /// The sound effects placed on the video on screen (Sounds.swift).
    let effects = EffectTrack()
    /// Bumped after a frame is saved, so the Assets tab rescans at once.
    var stillsSaved = 0
    /// Short message over the video ("Saved stills/…"). Clears itself.
    var toast: String?
    /// Thumbnails Takes is putting on a video as its cover now (Cover.swift).
    var coverWork: Set<URL> = []
    /// What Claude asked to show while the user looked at something else (open_in_app from a chat
    /// in another session). Takes never jumps there by itself: the session gets a dot, and
    /// going to it shows the file (2026-10-01, parallel sessions). Unseen ones survive a quit or
    /// an update (2026-10-04).
    var notices: [AgentNotice] = AgentNotice.restore(UserDefaults.standard.data(forKey: AgentNotice.key)) {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(notices), forKey: AgentNotice.key) }
    }
    /// A phone that asked to pair (Phone.swift), until the user allows it or not.
    var phonePair: PhonePairRequest?
    /// The server the iPhone app talks to.
    private(set) var phone: PhoneServer?
    /// Drawing an area on the video for a review comment (C).
    var commentMode = false
    /// The review player in the post preview, so C, Space and ←/→ reach it there too.
    @ObservationIgnored weak var postReview: PostReview?
    var sessionsToggle = 0
    /// The cleanup sheet for the open session (Publish.swift).
    var cleaningUp = false

    @ObservationIgnored private var recordTask: Task<Void, Never>?
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let watch = FileWatch()

    private struct Pending {
        let doc: SessionDoc
        let number: Int
        let cam: URL
        let camStart: Date
        let screen: URL?
        let screenStart: Date?
        let script: String?
        let hook: String?
        let shot: String?
    }

    /// The storyboard shot the next take films (the Storyboard tab's Record button). The script
    /// column shows its lines while it records; after the take, the tab goes back to the storyboard.
    var shot: StoryShot?

    func record(shot: StoryShot) {
        guard !isRecording else { return }
        self.shot = shot
        preview = nil
        SessionMode.set(.record)
        toggleRecord()
    }

    var isRecording: Bool { phase != .idle }
    /// The Record screen is daylight while you prepare and goes dark from the countdown to the
    /// end of the take: a dark prompter does not light your face, and the change says "on air".
    var lightsDown: Bool { phase != .idle || lightsDownForSnapshot }
    @ObservationIgnored var lightsDownForSnapshot = false

    /// The session on screen, so a switch can save what it showed.
    @ObservationIgnored private var shown: URL?

    /// Each session opens on the tab and the file it showed last (2026-10-02).
    private func showView(of doc: SessionDoc) {
        rememberView()
        shown = doc.url
        let v = SessionView.read(doc.url)
        guard !isRecording else { preview = nil; return }
        if let f = opening, Self.inside(f, doc.url) { present(f); return }
        SessionMode.set(v.mode)
        if v.mode == .assets || v.mode == .sounds, let f = v.file, FileManager.default.fileExists(atPath: f.path) {
            // Paused where he left it: a session he clicks past must not start to play.
            pendingSeek = Asset.kind(of: f) == .video ? v.time ?? 0 : nil
            preview = f
        } else {
            preview = nil
        }
    }

    /// Saves the tab and the open file of the session on screen.
    func rememberView() {
        guard let s = shown, !isRecording else { return }
        let tab = SessionMode(rawValue: UserDefaults.standard.string(forKey: "rightTab") ?? "") ?? .record
        let t = preview.flatMap { Asset.kind(of: $0) == .video ? player?.currentTime().seconds : nil }
        SessionView.write(s, mode: tab, file: preview, time: t.flatMap { $0.isFinite ? $0 : nil })
    }

    /// Running under swift test (Swift Testing loads no XCTestCase, so that check missed it).
    nonisolated static let testing = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.processName.contains("swiftpm-testing-helper")
        || Bundle.main.bundlePath.hasSuffix(".xctest")
        || ProcessInfo.processInfo.arguments.contains { $0.hasSuffix(".xctest") || $0.contains("PackageTests") }

    init() {
        // The Styles tab of a session became the Styles board (2026-10-02).
        if UserDefaults.standard.string(forKey: "rightTab") == "library" {
            UserDefaults.standard.set(SessionMode.record.rawValue, forKey: "rightTab")
        }
        // Tests leave the app's logs alone: their perf lines and stall samples went into
        // ~/Library/Logs/Takes beside the app's and read as the app's own (2026-10-04).
        if !Self.testing { HangWatch.start(); Perf.start(); PostFile.warmPortraits(library.root) }
        copilot.askChat = { [chats] text in chats.comments.send(text, title: "Comments", onStage: nil) }
        voice.source = { [weak self] in self?.promptText ?? "" }
        voice.problem = { [weak self] in self?.show(toast: $0) }
        library.onOpen = { [weak self] doc in
            guard let self else { return }
            // Make the session's chat now, not while the chat corner draws (that changed the
            // observed chat list in the middle of a view update).
            _ = self.chats.chat(doc.url)
            self.wire(doc)
            self.showView(of: doc)
            self.loadSong(doc)
        }
        // A new session opens with the chat in the half screen beside the recorder: on his first
        // launch Jeremy did not find the chat (2026-10-06).
        library.onCreate = { [weak self] _ in
            guard let self, !self.isRecording else { return }
            self.chats.docked = true
            self.chats.open = true
        }
        if let doc = library.current { _ = chats.chat(doc.url); wire(doc); loadSong(doc); shown = doc.url }
        screen.refreshDisplays()
        Task { await camera.boot() }
        if !Self.testing {
            phone = PhoneServer(app: self)
            phone?.start()
        }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKey(e) ?? e
        }) { monitors.append(m) }
        monitors.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.library.reload()
                self.screen.refreshDisplays()
            }
        })
        monitors.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rememberView()
                self?.library.current?.close()
                self?.chats.stopAll()  // a running claude would go on without the app
            }
        })
        // Changes Claude makes through the MCP server show up without a click: FSEvents tells us,
        // so an idle app does no disk work at all.
        watch.watch(library.root)
        library.onRoot = { [weak self] url in self?.watch.watch(url) }
        monitors.append(NotificationCenter.default.addObserver(
            forName: .takesFilesChanged, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                // FileWatch sends at most one change a second, however many files a render writes.
                // Only folders that can change the sidebar or the open script count: a render into
                // edits/ used to rescan the whole library every second (2026-10-03).
                guard let self, !self.isRecording else { return }
                let paths = note.object as? [String] ?? []
                guard Library.matters(paths, root: self.library.root) else { return }
                self.library.reload()
            }
        })
        // Safety net for a script edit that arrived while you typed (reload waits 5 s after typing).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.posts.settle()
                guard let self, !self.isRecording, NSApp.isActive else { return }
                self.library.reload()
            }
        }
        pollTimer?.tolerance = 5
        // The camera runs only while you can see it.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification,
                     NSApplication.didBecomeActiveNotification] {
            monitors.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdCamera() }
            })
        }
    }

    /// takes://open?path=<project folder, session folder, or a file in a session>
    /// (used by the MCP server's open_in_app tool). Many Claude chats run at once, and the user works
    /// while they do, so a request never changes the screen or plays a video: it waits as a notice
    /// (the pill on the stage, a dot in the sidebar) until he clicks it (2026-10-01).
    func handle(url: URL) {
        guard url.scheme == "takes",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value else { return }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        // Only this library's files (2026-10-04: a script building a made-up library in /tmp
        // called the MCP tools, and each new session there became a notice here).
        guard Self.inside(target, library.root) else { return }
        // Nothing on screen yet (the app just opened): showing a folder disturbs nothing.
        var isDir: ObjCBool = false
        if library.current == nil, !isRecording, board == nil,
           FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            go(target)
            return
        }
        notices.removeAll { $0.path == target }
        notices.append(AgentNotice(path: target, session: Self.session(containing: target)))
    }

    /// A link or card the user clicked (a file in a chat reply, a post, a Performance row): it opens
    /// now. handle(url:) is for the chats' requests and only leaves a notice; a click went there
    /// too, so a click on a video in the chat only made a notice (2026-10-04).
    func follow(_ url: URL) {
        var path = url.isFileURL ? url.path : nil
        if url.scheme == "takes" {
            path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
        }
        guard let path else { return }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard Self.inside(target, library.root) else { return }
        notices.removeAll { $0.path == target }
        go(target)
    }

    /// The session folder a path is in (or is), if any.
    nonisolated static func session(containing url: URL) -> URL? {
        var dir = url
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appending(path: "session.json").path) { return dir.standardizedFileURL }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The notice the stage pill shows: one for the session on screen first, else the newest.
    func notice(for session: URL?) -> AgentNotice? {
        let key = session?.standardizedFileURL
        return notices.last { key != nil && $0.session == key } ?? notices.last
    }

    /// Shows a notice's file now: its session, then the file on the stage.
    nonisolated static func inside(_ url: URL, _ root: URL) -> Bool {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let u = url.standardizedFileURL.resolvingSymlinksInPath().path
        return u == r || u.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// The user looked at a session's chat: its notices are seen, so they go.
    func seen(_ session: URL) {
        let s = session.standardizedFileURL
        notices.removeAll { $0.session == s }
    }

    func show(_ n: AgentNotice) {
        notices.removeAll { $0.id == n.id }
        go(n.path)
    }

    /// A file a notice or a link asked for, waiting for its session to open.
    @ObservationIgnored private var opening: URL?
    /// Where that file starts playing (a ⌘K search hit).
    @ObservationIgnored private var openingTime: Double?

    /// A file of the session on screen, on the tab that shows it, with the session's chat open
    /// beside it: a script on Script, a storyboard on Storyboard, anything else plays on the
    /// stage with the Assets list.
    private func present(_ f: URL) {
        opening = nil
        defer { openingTime = nil }
        let parts = f.pathComponents
        if parts.contains("storyboard") {
            SessionMode.set(.storyboard)
        } else if f.lastPathComponent == "script.md" || parts.contains("variants") {
            preview = nil
            SessionMode.set(.write)
        } else {
            SessionMode.set(.assets)
            pendingSeek = Asset.kind(of: f) == .video ? openingTime : nil
            preview = f
        }
        chats.open = true
    }

    /// A project, a session, or a file in one: show it.
    func go(_ url: URL) {
        guard !isRecording else { return }
        var target = url
        var file: URL?
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue,
           StyleLib.owner(containing: target) != nil {
            // A library file: it plays on the Styles board.
            board = .styles
            styleFile = target
            chats.open = true
            return
        } else if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            file = target
            if let p = PostPlatform.shown.first(where: { target.path.hasSuffix("/" + $0.rel) }) {
                // The post opens on its tab, on its platform's side, not on the stage.
                file = nil
                UserDefaults.standard.set("post", forKey: "rightTab")
                UserDefaults.standard.set(p.rawValue, forKey: "postPlatform")
            }
            var dir = target.deletingLastPathComponent()
            while dir.pathComponents.count > 1,
                  !FileManager.default.fileExists(atPath: dir.appending(path: "session.json").path) {
                dir = dir.deletingLastPathComponent()
            }
            target = dir
        }
        // The file shows once its session is on screen. Before (2026-10-04), a 300 ms timer set it,
        // and the session that opened after it put back its last tab: the file played unseen
        // behind Post, Storyboard or B-roll, or the session cleared it.
        opening = file
        defer {
            if let f = opening, let doc = library.current, Self.inside(f, doc.url) { present(f) }
        }
        board = nil
        library.reload()
        // A file in one of your styles: keep the project and session on show.
        if target.standardizedFileURL == library.root.standardizedFileURL { return }
        if library.projects.contains(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) {
            library.selectedProject = target
            return
        }
        let project = target.deletingLastPathComponent()
        library.selectedProject = library.projects.first { $0.url.standardizedFileURL == project.standardizedFileURL }?.url
        if let s = library.sessions.first(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) {
            library.selectedSessions = [s.url]
        }
    }

    private func wire(_ doc: SessionDoc) {
        doc.onScriptSettled = { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.autoName(doc)
        }
    }

    // MARK: Camera

    /// The live camera costs the most. Stop it while a file plays over it, the post view covers it,
    /// or no window shows it.
    /// Recording, and the countdown before it, always keep it on.
    func holdCamera() {
        let seen = (NSApp?.windows ?? []).contains { $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible) }
        camera.hold(Self.holdsCamera(idle: phase == .idle, preview: preview != nil || postView || stageCovered || board != nil, seen: seen))
    }

    nonisolated static func holdsCamera(idle: Bool, preview: Bool, seen: Bool) -> Bool {
        idle && (preview || !seen)
    }

    // MARK: Naming

    func autoName(_ doc: SessionDoc) {
        let words = doc.script.split { $0.isWhitespace }.count
        guard !doc.meta.named, !naming, phase == .idle, words >= 12 else { return }
        Task { await aiName(doc) }
    }

    func aiName(_ doc: SessionDoc) async {
        guard !naming else { return }
        naming = true
        let title = await Namer.title(for: doc.script, project: doc.projectName)
        naming = false
        guard let title, phase == .idle, library.current === doc else { return }
        rename(doc, to: title, named: true)
    }

    func rename(_ doc: SessionDoc, to title: String, named: Bool = true) {
        guard phase == .idle else { return }
        doc.rename(to: title, named: named)
        library.currentDidRename()
    }

    /// Registers the way back from a rename on the window's undo stack. Undoing it registers
    /// the redo.
    func undoableRename(_ doc: SessionDoc, back old: String) {
        guard let undo = NSApp.keyWindow?.undoManager else { return }
        undo.registerUndo(withTarget: doc) { [weak self] d in
            guard let self, self.phase == .idle else { return }
            let now = d.meta.title
            self.rename(d, to: old)
            self.undoableRename(d, back: now)
        }
        undo.setActionName("Rename")
    }

    // MARK: Recording

    func toggleRecord() {
        switch phase {
        case .idle: recordTask = Task { await start() }
        case .countdown: recordTask?.cancel(); phase = .idle; endShot()
        case .recording: Task { await stop() }
        case .starting: camera.cancelStart(); screen.cancelStart()
        case .finishing: break
        }
    }

    private func start() async {
        error = nil
        guard let doc = library.current ?? library.createSession() else { return }
        doc.flushScript()
        doc.snapshotDirty()
        preview = nil
        bed.pause()  // the mic would hear it
        await camera.resume()
        resetToken += 1
        scrolling = false
        if countdownOn {
            for i in (1...3).reversed() {
                phase = .countdown(i)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
        phase = .starting
        library.isRecording = true
        let n = doc.nextTakeNumber
        let nn = String(format: "%02d", n)
        let camURL = doc.url.appending(path: "take-\(nn)-camera.mov")
        let screenURL = mode == .cameraScreen ? doc.url.appending(path: "take-\(nn)-screen.mov") : nil
        let micID = camera.audioID
        do {
            async let camStart = camera.startRecording(to: camURL)
            var screenStart: Date?
            if let screenURL { screenStart = try await screen.startRecording(to: screenURL, micID: micID) }
            let cs = try await camStart
            pending = Pending(doc: doc, number: n, cam: camURL, camStart: cs, screen: screenURL, screenStart: screenStart,
                              script: doc.activeDraft == "main" ? nil : doc.draftName(doc.activeDraft),
                              hook: shot == nil ? HookStore.current(doc.activeText, HookStore.read(doc.url).hooks)?.text : nil,
                              shot: shot?.id)
            phase = .recording(Date())
            if autoScroll { scrolling = true }
        } catch {
            self.error = error is CancellationError ? nil : error.localizedDescription
            await camera.stopRecording()
            await screen.stopRecording()
            for u in [camURL, screenURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
            library.isRecording = false
            phase = .idle
            endShot()
        }
    }

    /// Back to the storyboard after a shot's take (or a cancelled one).
    private func endShot() {
        guard shot != nil else { return }
        shot = nil
        SessionMode.set(.storyboard)
    }

    private func stop() async {
        guard case .recording = phase, let p = pending else { return }
        phase = .finishing
        scrolling = false
        async let a: Void = camera.stopRecording()
        async let b: Void = screen.stopRecording()
        _ = await (a, b)

        var takes = [Take(number: p.number, kind: .camera, file: p.cam.lastPathComponent,
                          startedAt: p.camStart, duration: await Self.duration(p.cam), script: p.script, hook: p.hook, shot: p.shot)]
        if let s = p.screen, let ss = p.screenStart {
            takes.append(Take(number: p.number, kind: .screen, file: s.lastPathComponent,
                              startedAt: ss, duration: await Self.duration(s), script: p.script, hook: p.hook, shot: p.shot))
        }
        p.doc.addTakes(takes)
        if p.shot != nil { p.doc.fileShotTake(p.number) }
        pending = nil
        library.isRecording = false
        phase = .idle
        library.loadSessions()
        autoName(p.doc)
        endShot()
    }

    private static func duration(_ url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }

    // MARK: Stills

    /// A time to seek to when the next video opens (a reply's "v4 @ 0:15" link).
    var pendingSeek: Double?

    /// Opens a file of any session, at a time for a video (a ⌘K search hit).
    func open(_ url: URL, at time: Double?) {
        openingTime = time
        follow(url)
    }

    /// Opens a file in the stage, at a time for a video.
    func jump(to url: URL, at time: Double?) {
        guard FileManager.default.fileExists(atPath: url.path) else { show(toast: "\(url.lastPathComponent) is gone"); return }
        pendingSeek = Asset.kind(of: url) == .video ? time : nil
        if preview == url { preview = nil; DispatchQueue.main.async { self.preview = url } } else { preview = url }
    }

    var canSaveFrame: Bool {
        guard let p = preview, library.current != nil else { return false }
        return Asset.kind(of: p) == .video
    }

    /// A video or still in the player that can take review comments.
    var canComment: Bool {
        guard let p = preview, library.current != nil else { return false }
        return Asset.kind(of: p) == .video || Asset.kind(of: p) == .image
    }

    /// Saves the frame the player shows now into the session's stills/ folder. Pauses first.
    func saveFrame() {
        guard canSaveFrame, let video = preview, let doc = library.current, let player else { return }
        player.pause()
        let time = player.currentTime()
        Task {
            do {
                let url = try await FrameGrabber.save(video: video, at: time, session: doc.url)
                stillsSaved += 1
                show(toast: "Saved stills/\(url.lastPathComponent)")
            } catch {
                show(toast: "Could not save the frame: \(error.localizedDescription)")
            }
        }
    }

    /// The session's song, ready under its videos (not playing).
    func loadSong(_ doc: SessionDoc) {
        effects.dir = SoundLib.dir(root: library.root)
        effects.session = doc.url
        effects.cues = doc.meta.sfx ?? []
        doc.onMeta = { [weak self, weak doc] m in
            guard let self, let doc, self.library.current === doc else { return }
            self.effects.cues = m.sfx ?? []
        }
        guard let m = doc.meta.music else { bed.stop(); return }
        bed.load(SoundLib.dir(root: library.root).appending(path: m.file), start: m.start, volume: m.volume)
    }

    func show(toast text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    // MARK: Keys

    /// Space = play/pause script, ↑/↓ = speed (while recording), Esc cancels the countdown,
    /// S = save the current frame of the video in the player, C = comment on an area of it,
    /// ←/→ = one frame (⇧ one second).
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        var c = KeyContext()
        if case .countdown = phase { c.countdown = true }
        if case .recording = phase { c.recording = true }
        c.typing = KeyRouter.isTyping(NSApp.keyWindow?.firstResponder)
        c.hasPreview = preview != nil
        c.videoOnStage = canSaveFrame
        c.canComment = canComment
        c.commentMode = commentMode
        c.hasPlayer = player != nil
        if postView && phase == .idle {
            // The post view hides the stage. Its keys go to the post's review player, if any.
            let review = postReview
            c.hasPreview = true
            c.videoOnStage = review != nil
            c.canComment = review != nil
            c.commentMode = review?.mode ?? false
            c.hasPlayer = review != nil
            guard let review, let action = KeyRouter.action(key: e.keyCode, modifiers: e.modifierFlags, c)
            else { return e }
            switch action {
            case .toggleComment: review.mode.toggle()
            case .endComment: review.mode = false
            case .playPause: review.clock?.toggle()
            case .nudge(let dir, let frame): if let p = review.clock?.player { Self.nudge(p, dir, frame: frame) }
            default: return e
            }
            return nil
        }
        guard let action = KeyRouter.action(key: e.keyCode, modifiers: e.modifierFlags, c) else { return e }
        switch action {
        case .toggleRecord: toggleRecord()
        case .toggleScroll: scrolling.toggle()
        case .saveFrame: saveFrame()
        case .toggleComment: commentMode.toggle()
        case .endComment: commentMode = false
        case .playPause:
            if player?.timeControlStatus == .paused { player?.play() } else { player?.pause() }
        case .nudge(let dir, let frame): nudge(dir, frame: frame)
        case .speed(let d): speed = min(300, max(5, speed + Double(d)))
        }
        return nil
    }

    /// Moves the video in the player by one second, or by one frame.
    private func nudge(_ dir: Int, frame: Bool) {
        if let player { Self.nudge(player, dir, frame: frame) }
    }

    static func nudge(_ player: AVPlayer, _ dir: Int, frame: Bool) {
        guard let item = player.currentItem else { return }
        player.pause()
        if frame { item.step(byCount: dir); return }
        let d = item.duration.isNumeric ? item.duration.seconds : .greatestFiniteMagnitude
        let t = max(0, min(d, player.currentTime().seconds + Double(dir)))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// ⌘B: ContentView hides or shows the sidebar.
    func toggleSidebars() {
        NotificationCenter.default.post(name: .takesToggleSidebar, object: nil)
    }

    /// ⇧⌘B: ContentView hides or shows the session list.
    func toggleSessions() { sessionsToggle += 1 }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = library.root
        if panel.runModal() == .OK, let url = panel.url { library.setRoot(url) }
    }
}

extension Notification.Name {
    static let takesStopScrolling = Notification.Name("takesStopScrolling")
}

extension Notification.Name {
    static let takesToggleSidebar = Notification.Name("takesToggleSidebar")
}

/// Something a Claude chat wanted the user to see, held until he looks (AppModel.notices).
struct AgentNotice: Identifiable, Equatable, Codable {
    var id = UUID()
    let path: URL
    /// nil: a project or a library file.
    let session: URL?

    nonisolated static let key = "notices"

    /// The saved notices whose file is still there. A file deleted while Takes was closed
    /// has nothing left to show.
    nonisolated static func restore(_ data: Data?) -> [AgentNotice] {
        guard let data, let saved = try? JSONDecoder().decode([AgentNotice].self, from: data) else { return [] }
        return saved.filter { FileManager.default.fileExists(atPath: $0.path.path) }
    }

    /// The file in words, for the header card: "Edit v2" and "Linux phones" from
    /// edits/linux-phones-v2.mp4. Raw file names read as gibberish (2026-10-04).
    nonisolated static func describe(_ path: URL, session: URL?) -> (what: String, name: String) {
        let path = path.standardizedFileURL
        if let session, path == session.standardizedFileURL { return ("Session", "") }
        let inside = session.map { s in Array(path.pathComponents.dropFirst(s.standardizedFileURL.pathComponents.count)) } ?? []
        let top = inside.count > 1 ? inside[0] : ""
        var stem = path.deletingPathExtension().lastPathComponent
        var version = ""
        if let r = stem.range(of: #"[-_ ]v(\d+)$"#, options: .regularExpression) {
            version = " v" + stem[r].drop { !$0.isNumber }
            stem = String(stem[..<r.lowerBound])
        }
        var isDir: ObjCBool = false
        let folder = path.pathExtension.isEmpty && FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
        let what: String
        switch top {
        case "edits": what = "Edit"
        case "thumbnails": what = "Thumbnail"
        case "stills": what = "Frame"
        case "storyboard": what = "Storyboard"
        case "posts": what = "Post"
        case "variants": what = "Script version"
        default:
            if path.lastPathComponent == "script.md" { what = "Script" }
            else if folder { what = session == nil ? "Project" : "Folder" }
            else {
                switch Asset.kind(of: path) {
                case .video: what = "Video"
                case .image: what = "Image"
                case .audio: what = "Audio"
                case .other: what = "File"
                }
            }
        }
        var name = stem.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "script" under "Script", "storyboard" under "Storyboard": say it once.
        if name.lowercased() == what.lowercased() { name = "" }
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return (what + version, name)
    }
}
