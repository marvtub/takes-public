import Foundation
import SwiftUI
import UIKit

/// What the app knows: where the Mac is, whether Face ID unlocked it, the sessions, the live
/// stream and the uploads.
@MainActor
final class Model: ObservableObject {
    enum Phase: Equatable { case pairing, locked, open }

    @Published var phase: Phase
    @Published var sessions: [Session] = []
    @Published var error: String?
    /// The Mac answers. Back online, the changes that waited go out (Outbox).
    @Published var connected = false {
        didSet { if connected && !oldValue { Task { await outbox.flush() } } }
    }
    /// The chat on screen, kept live by the event stream. Its own object: a streaming reply
    /// redraws the chat, not every screen that reads the model.
    let live = LiveChat()
    var chat: Chat? { live.chat }
    var chatID: String? {
        get { live.id }
        set { if live.id != newValue { live.id = newValue } }
    }
    /// The Mac's Performance chat is updating the numbers.
    @Published var performanceRunning = false
    @Published var performanceTick = 0
    /// Goes up when the Mac's comment suggestions change: the Comments tab reloads.
    @Published var copilotTick = 0
    /// A new build of this app waits on the Mac; Update installs it (the Mac ends and reopens the app).
    @Published var update: AppUpdate?
    @Published var updating = false
    private var updates: Task<Void, Never>?
    let uploads = Uploads()
    /// Changes made while the Mac was away, until it has them.
    let outbox = Outbox()

    @AppStorage("server") var server = ""
    private(set) var token: String?
    private var stream: Task<Void, Never>?
    private var probe: Task<Void, Never>?
    private var leftAt: Date?
    /// Face ID again after this long away.
    static let relock: TimeInterval = 5 * 60

    /// Built once per server and token: rows ask for it to make every picture URL.
    var api: API {
        let key = server + "|" + (token ?? "") + "|\(renamed.count)"
        if let apiCache, apiCache.key == key { return apiCache.api }
        var a = API(base: URL(string: server) ?? URL(string: "https://invalid")!, token: token)
        a.renamed = renamed
        apiCache = (key, a)
        return a
    }
    private var apiCache: (key: String, api: API)?

    /// A video started offline has a phone id ("phone/…") until the Mac makes it; then this maps
    /// the phone id to the Mac's, so screens that still hold the phone id reach the right session.
    private(set) var renamed: [String: String] = (UserDefaults.standard.dictionary(forKey: "renamedSessions") as? [String: String]) ?? [:]
    func resolve(_ id: String) -> String { renamed[id] ?? id }

    init() {
        // UI tests point the app at a stand-in server.
        if let s = ProcessInfo.processInfo.environment["TAKES_SERVER"] {
            Vault.delete()
            UserDefaults.standard.set(s, forKey: "server")
        }
        phase = Vault.hasToken ? .locked : .pairing
        uploads.model = self
        outbox.model = self
        // Takes that were uploading when the app quit: never send them twice.
        uploads.session.getAllTasks { [outbox] tasks in
            let ids = tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) }
            Task { @MainActor in outbox.inFlight(ids) }
        }
        // The list from last time, so the app opens on it while it asks the Mac for a fresh one.
        if phase != .pairing { sessions = withLocal(Cache.load([Session].self, "sessions") ?? []) }
    }

    // MARK: Pair and unlock

    func pair() async {
        error = nil
        do {
            try await API(base: URL(string: server)!, token: nil).ping()
        } catch {
            self.error = "Can't reach the Mac at \(server). Is Tailscale on, and Takes open? (\(error.localizedDescription))"
            return
        }
        do {
            let t = try await API(base: URL(string: server)!, token: nil).pair(name: UIDevice.current.name)
            try Vault.save(t)
            token = t
            phase = .open
            await refresh()
            listen()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unlock() async {
        guard phase == .locked else { return }
        guard let t = await Vault.load() else { return }
        token = t
        phase = .open
        await refresh()
        listen()
    }

    func unpair() {
        Vault.delete()
        Cache.clear()
        token = nil
        stream?.cancel()
        sessions = []
        phase = .pairing
    }

    func scene(_ p: ScenePhase) {
        switch p {
        case .background:
            leftAt = Date()
        case .active:
            if phase == .open, let leftAt, -leftAt.timeIntervalSinceNow > Self.relock {
                token = nil
                stream?.cancel()
                phase = .locked
            } else if phase == .open, leftAt != nil {
                // Only after real time away: Control Center and Face ID also make the app active.
                listen()
                Task { await refresh() }
            }
            leftAt = nil
        default: break
        }
    }

    // MARK: Data

    func refresh() async {
        do {
            let fresh = try await api.sessions()
            Task.detached { Cache.save(fresh, "sessions") }
            let all = withLocal(fresh)
            if all != sessions {
                sessions = all
            }
            if !connected { connected = true }
            if error != nil { error = nil }
            await outbox.flush()
            Task { await prefetch() }
        } catch let e as APIError where e.status == 401 {
            unpair()
            error = "The Mac forgot this phone. Pair it again."
        } catch {
            connected = false
            self.error = error.localizedDescription
        }
    }

    /// Asks the Mac whether a new build of this app waits. An older Mac Takes answers 404: nothing.
    func checkUpdate() async {
        guard phase == .open, let u = try? await api.appUpdate() else { return }
        let next = u.stamp == nil ? nil : u
        if next != update { update = next }
        if updating, u.installing != true { updating = false }
    }

    /// The Mac installs the build, which ends this app; it opens again on the new one.
    func installUpdate() async {
        guard !updating else { return }
        updating = true
        do { update = try await api.installUpdate() } catch {
            updating = false
            update?.error = error.localizedDescription
        }
    }

    /// The Mac's event stream: chat changes and notices. Reconnects when it drops.
    func listen() {
        updates?.cancel()
        updates = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkUpdate()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // A failed change can mark the Mac away while the stream still runs: ask it now and then.
        probe?.cancel()
        probe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !self.connected, self.phase == .open else { continue }
                if (try? await self.api.ping()) != nil { self.connected = true }
            }
        }
        stream?.cancel()
        stream = Task { [weak self] in
            var wait: UInt64 = 1
            while !Task.isCancelled {
                guard let self, let r = Optional(self.api.request("/api/events")) else { return }
                do {
                    var req = r
                    req.timeoutInterval = 90
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    if !self.connected { self.connected = true }
                    wait = 1
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let ev = try? API.decoder.decode(LiveEvent.self, from: Data(line.dropFirst(6).utf8)) else { continue }
                        self.apply(ev)
                    }
                } catch {
                    if Task.isCancelled { return }
                    if self.connected { self.connected = false }
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait = min(wait * 2, 20)
            }
        }
    }

    private func apply(_ ev: LiveEvent) {
        switch ev.type {
        case "chat":
            guard let id = ev.id else { return }
            if id == "board:performance", let r = ev.running {
                // A finished update: the performance tab loads the new numbers.
                if performanceRunning && !r { performanceTick += 1 }
                if performanceRunning != r { performanceRunning = r }
            }
            // Events come up to 2.5 times a second per chat: write only what changed, so the
            // list does not redraw (and re-sort) on every tick.
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                var s = sessions[i]
                let running = ev.running ?? false
                if running && !s.running { s.updated = Date() }
                s.running = running
                s.unread = ev.unread ?? false
                if s != sessions[i] { sessions[i] = s }
            }
            guard id == chatID, var c = live.chat else { return }
            c.running = ev.running ?? c.running
            if let ctx = ev.context { c.context = ctx }
            for m in ev.tail ?? [] {
                if let i = c.messages.lastIndex(where: { $0.id == m.id }) {
                    if c.messages[i] != m { c.messages[i] = m }
                } else { c.messages.append(m) }
            }
            if c != live.chat { live.chat = c }
            // Lost a message on the way: fetch all of it, once.
            if let n = ev.count, n != c.messages.count, !loadingChat.contains(id) {
                loadingChat.insert(id)
                Task { await self.loadChat(id); self.loadingChat.remove(id) }
            }
        case "beat":
            // Every 20 s: a chat on screen that says Claude works asks the Mac again. The Mac
            // settles a run whose process is gone, so "working" cannot stay for good (2026-10-03).
            if let id = chatID, live.chat?.running == true, !loadingChat.contains(id) {
                loadingChat.insert(id)
                Task { await self.loadChat(id); self.loadingChat.remove(id) }
            }
        case "copilot":
            copilotTick += 1
        case "notices":
            let paths = Set(ev.paths ?? [])
            var next = sessions
            for i in next.indices {
                next[i].notice = paths.contains { $0.contains("/" + next[i].id + "/") || $0.hasSuffix("/" + next[i].id) }
            }
            if next != sessions { sessions = next }
        default: break
        }
    }

    private var loadingChat: Set<String> = []

    func loadChat(_ id: String) async {
        guard let c = try? await api.chat(id) else { return }
        if chatID == id, live.chat != c { live.chat = c }
    }

    /// The session on screen: its chat goes live. `read` tells the Mac it was seen; a background
    /// reload passes false.
    func open(_ id: String, chat c: Chat, read: Bool = true) {
        let id = resolve(id)
        let streaming = live.id == id && live.chat?.running == true
        chatID = id
        // A reload must not swap a streaming reply for an older copy. One that says Claude is done
        // always wins: else a missed "done" kept the chat working for good (2026-10-03).
        if live.chat != c && !(streaming && !read && c.running) { live.chat = c }
        guard read else { return }
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].unread || sessions[i].notice {
            sessions[i].unread = false
            sessions[i].notice = false
        }
        Task { try? await api.read(id) }
    }

    /// A message to a chat. Without the Mac it waits on the phone and shows in the chat.
    /// `from` names the screen it was sent from and `voice` says it was dictated: the Mac tells
    /// Claude, so it knows what the user is looking at and reads past transcription slips.
    func say(_ text: String, in id: String, from: String? = nil, voice: Bool = false) async -> Bool {
        var json: [String: Any] = ["text": text]
        if let from { json["from"] = from }
        if voice { json["voice"] = "1" }
        let op = Outbox.Op(.say, session: id, path: "/api/chat", query: ["id": id], json: json)
        do {
            switch try await outbox.send(op) {
            case .now:
                if chatID == id, var c = live.chat, !c.running {
                    c.running = true
                    live.chat = c
                }
            case .queued(let o):
                if chatID == id, var c = live.chat {
                    c.messages.append(Self.waitingMessage(o))
                    live.chat = c
                }
            }
            // Then the Mac's own state: the message may have queued, or the run may have ended
            // before this answer came, and no event would correct a "working" set here (2026-10-03).
            if chatID == id { await loadChat(id) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: Changes (they wait on the phone when the Mac is away)

    /// Saves the script or the post. Throws when the Mac said no (it changed there meanwhile).
    func save(_ what: String, _ id: String, text: String, base: String) async throws {
        let op = Outbox.Op(what == "script" ? .script : .post, session: id, path: "/api/" + what, query: ["id": id],
                           json: ["text": text, "base": base])
        _ = try await outbox.send(op)
    }

    func postDraft(_ id: String, _ body: [String: String]) async throws {
        _ = try await outbox.send(Outbox.Op(.postDraft, session: id, path: "/api/post/draft", query: ["id": id], json: body))
    }

    /// Shows at once; the outbox brings it to the Mac.
    func archive(_ id: String, _ on: Bool) async {
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].archived = on }
        _ = try? await outbox.send(Outbox.Op(.archive, session: id, path: "/api/archive", query: ["id": id, "on": on ? "1" : "0"]))
    }

    func keeper(_ id: String, take: Int) async {
        _ = try? await outbox.send(Outbox.Op(.keeper, session: id, path: "/api/keeper", query: ["id": id, "take": String(take)]))
    }

    func cover(_ path: String) async throws {
        _ = try await outbox.send(Outbox.Op(.cover, session: "", path: "/api/cover", query: ["path": path]))
    }

    /// A decision on a comment draft (approve, decline, skip, feedback, posted …).
    func decide(_ id: String, _ action: String, _ extra: [String: Any] = [:]) async throws {
        var body = extra
        body["id"] = id
        body["action"] = action
        _ = try await outbox.send(Outbox.Op(.decide, session: id, path: "/api/copilot", json: body))
    }

    /// A comment on the script or the post (quote: the words it is about).
    func comment(_ id: String, file: String, quote: String?, text: String) async -> Comment? {
        var body = ["file": file, "text": text]
        if let quote { body["quote"] = quote }
        return await comment(id, body)
    }

    /// A comment on a video (a moment or a range) or a picture, with an area or the whole frame.
    func comment(_ id: String, media file: String, start: Double?, end: Double?, rect: CGRect?, text: String) async -> Comment? {
        var body: [String: Any] = ["file": file, "text": text]
        if let start { body["start"] = start }
        if let end { body["end"] = end }
        if let rect { body["rect"] = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init) }
        return await comment(id, body)
    }

    /// Feedback on a storyboard shot.
    func comment(_ id: String, shot: String, text: String) async -> Comment? {
        await comment(id, ["file": "storyboard/storyboard.json", "shot": shot, "text": text])
    }

    private func comment(_ id: String, _ body: [String: Any]) async -> Comment? {
        switch try? await outbox.send(Outbox.Op(.comment, session: id, path: "/api/comments", query: ["id": id], json: body)) {
        case .now(let data)?: return try? API.decoder.decode(Comment.self, from: data)
        case .queued(let o)?: return Self.waitingComment(o)
        case nil: return nil
        }
    }

    func reply(_ id: String, comment: String, text: String) async {
        _ = try? await outbox.send(Outbox.Op(.reply, session: id, path: "/api/comments/reply", query: ["id": id],
                                             json: ["id": comment, "text": text]))
    }

    func resolve(_ id: String, comment: String, _ resolved: Bool) async {
        _ = try? await outbox.send(Outbox.Op(.resolve, session: id, path: "/api/comments/reply", query: ["id": id],
                                             json: ["id": comment, "resolved": resolved ? "true" : "false"]))
    }

    // MARK: New videos

    /// A new, empty video. Without the Mac it starts on the phone: it shows in the list, and
    /// everything done in it waits; the Mac makes it first when it is back, then the rest follows.
    func newVideo(project: String) async throws -> Session {
        if connected, let s = try? await api.newSession(project: project, title: "", idea: "") { return s }
        let id = "phone/" + UUID().uuidString
        var op = Outbox.Op(.newSession, session: id, path: "/api/sessions", json: ["project": project, "title": "", "idea": ""])
        op.created = Date()
        outbox.add(op)
        let s = Self.localSession(op)
        let d = SessionDetail(session: s, folder: "", script: "", files: [], post: nil,
                              chat: Chat(running: false, messages: []), openComments: 0, profile: nil, storyboard: nil)
        Cache.save(d, "session-" + id)
        return s
    }

    /// The Mac made a video that started on the phone.
    func adopt(_ local: String, as real: Session) {
        renamed[local] = real.id
        UserDefaults.standard.set(renamed, forKey: "renamedSessions")
        if let i = sessions.firstIndex(where: { $0.id == local }) { sessions[i] = real } else { sessions.insert(real, at: 0) }
        if chatID == local { chatID = real.id }
    }

    /// The Mac's list plus the videos that wait on the phone to be made.
    func withLocal(_ list: [Session]) -> [Session] {
        let local = outbox.ops.filter { $0.kind == .newSession }.map(Self.localSession)
        return local.reversed() + list.filter { s in !local.contains { $0.id == s.id } }
    }

    static func localSession(_ op: Outbox.Op) -> Session {
        Session(id: op.session, title: "New video", project: op.string("project") ?? "Inbox", created: op.created,
                updated: op.created, takes: 0, running: false, unread: false, notice: false, published: false, preview: nil)
    }

    // MARK: Reading, with the phone's copy when the Mac is away

    private var prefetched: Date?

    /// Keeps a copy of the newest sessions, their comments, the comment drafts and the numbers,
    /// so they open offline even when the user never opened them on the phone. At most every 10 min.
    func prefetch() async {
        if let p = prefetched, -p.timeIntervalSinceNow < 600 { return }
        prefetched = Date()
        let recent = sessions.filter { !$0.published }.sorted { $0.updated > $1.updated }.prefix(12)
        for s in recent {
            guard connected else { return }
            if let d = try? await api.detail(s.id) { let k = "session-" + s.id; Task.detached(priority: .utility) { Cache.save(d, k) } }
            if let c = try? await api.comments(s.id) { let k = "comments-" + s.id; Task.detached(priority: .utility) { Cache.save(c, k) } }
        }
        if let raw = try? await api.copilotData() { Cache.saveData(raw, "copilot") }
        if let raw = try? await api.performanceData() { Cache.saveData(raw, "performance") }
    }

    /// The session's comments: the Mac's, or the last copy, with the waiting changes on top.
    func comments(_ id: String) async -> [Comment]? {
        let key = "comments-" + id
        var list: [Comment]?
        if connected, let c = try? await api.comments(id) {
            list = c
            Task.detached(priority: .utility) { Cache.save(c, key) }
        } else {
            list = Cache.load([Comment].self, key)
        }
        return list.map { patch(comments: $0, in: id) }
    }

    /// A session as the phone shows it: the Mac's copy with the waiting changes on top.
    func patch(_ detail: SessionDetail) -> SessionDetail {
        var d = detail
        let id = resolve(d.session.id)
        for op in outbox.ops where op.session == id && op.refused == nil {
            switch op.kind {
            case .script: if let t = op.string("text") { d.script = t }
            case .post: if let t = op.string("text") { d.post?.text = t }
            case .postDraft:
                if op.string("action") == "save", let t = op.string("text"),
                   let i = d.post?.variants?.firstIndex(where: { $0.slug == op.string("slug") }) {
                    d.post?.variants?[i].text = t
                }
            case .say: d.chat.messages.append(Self.waitingMessage(op))
            case .comment:
                let c = Self.waitingComment(op)
                if let shot = c.shot, let i = d.storyboard?.firstIndex(where: { $0.id == shot }) {
                    d.storyboard?[i].comments.append(c)
                } else {
                    d.openComments += 1
                }
            default: break
            }
        }
        return d
    }

    func patch(comments list: [Comment], in id: String) -> [Comment] {
        var c = list
        let id = resolve(id)
        for op in outbox.ops where op.session == id && op.refused == nil {
            switch op.kind {
            case .comment: c.append(Self.waitingComment(op))
            case .reply:
                if let i = c.firstIndex(where: { $0.id == op.string("id") }) {
                    c[i].replies = (c[i].replies ?? []) + [.init(by: "user", text: op.string("text") ?? "", at: Dates.plain.string(from: op.created))]
                }
            case .resolve:
                if let i = c.firstIndex(where: { $0.id == op.string("id") }) {
                    c[i].status = op.string("resolved") == "true" ? "resolved" : "open"
                }
            default: break
            }
        }
        return c
    }

    /// The comment drafts with the waiting decisions on top.
    func patch(_ copilot: Copilot) -> Copilot {
        var c = copilot
        for op in outbox.ops where op.kind == .decide && op.refused == nil {
            guard let i = c.items.firstIndex(where: { $0.id == op.session }) else { continue }
            switch op.string("action") {
            case "approve": c.items[i].status = "approved"; c.items[i].final = op.string("text") ?? c.items[i].final
            case "feedback": c.items[i].status = "redraft"
            case "decline": c.items[i].status = "declined"
            case "skip": c.items[i].skipped = op.created
            case "unskip": c.items[i].skipped = nil
            case "pullback": c.items[i].status = "review"
            case "posted": c.items[i].status = "posted"
            default: break
            }
        }
        return c
    }

    /// A message or comment that waits for the Mac. Its id is the change's, so screens can mark it.
    static func waitingMessage(_ op: Outbox.Op) -> Message {
        Message(id: op.id, role: .user, text: op.string("text") ?? "", toolID: nil, done: true)
    }

    static func waitingComment(_ op: Outbox.Op) -> Comment {
        let j = op.json
        return Comment(id: "waiting-" + op.id.uuidString, file: j["file"] as? String ?? "", quote: j["quote"] as? String,
                       text: j["text"] as? String ?? "", status: "open", by: "user", at: Dates.plain.string(from: op.created),
                       replies: nil, shot: j["shot"] as? String, start: j["start"] as? Double, end: j["end"] as? Double,
                       rect: j["rect"] as? [Double])
    }
}

/// The chat on screen and its session id.
@MainActor
final class LiveChat: ObservableObject {
    @Published var chat: Chat?
    @Published var id: String?
}

// MARK: - Cache

/// The last answer of each screen, kept on the phone, so a screen shows it at once and swaps in
/// the fresh one when the Mac answers. Caches folder (iOS may clear it), files locked with the phone.
enum Cache {
    static let dir = URL.cachesDirectory.appending(path: "mac")
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601  // API.decoder reads it back
        return e
    }()

    static func file(_ key: String) -> URL {
        dir.appending(path: key.replacingOccurrences(of: "/", with: "|") + ".json")
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? encoder.encode(value) else { return }
        saveData(data, key)
    }

    static func saveData(_ data: Data, _ key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: [.atomic, .completeFileProtection])
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        loadData(key).flatMap { try? API.decoder.decode(T.self, from: $0) }
    }

    static func loadData(_ key: String) -> Data? { try? Data(contentsOf: file(key)) }

    static func clear() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - Uploads

/// Files on their way to the Mac. A background URLSession: an upload goes on when the user leaves
/// the app or locks the phone, and iOS retries it when the network comes back.
@MainActor
final class Uploads: NSObject, ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: Int
        var name: String
        var session: String
        var asTake: Bool
        var sent: Int64 = 0
        var total: Int64 = 0
        var done = false
        var failed: String?
        var path: String?
        /// The outbox change this upload belongs to (a take).
        var op: UUID?
        var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }
    }

    @Published var items: [Item] = []
    weak var model: Model?
    /// Finished uploads hand their path on: the chat puts it in the message.
    var finished: ((Item) -> Void)?
    var backgroundDone: (() -> Void)?
    private var answers: [Int: Data] = [:]

    nonisolated static let identifier = "de.marvinaziz.takes.phone.uploads"

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    /// Copies the file into the app's own folder first: the background session needs a file it
    /// can still read after the picker let go of the original.
    @discardableResult
    func send(_ file: URL, name: String, to sessionID: String, asTake: Bool, shot: String? = nil) -> Int? {
        guard let model else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "outbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appending(path: UUID().uuidString + "-" + name)
        do {
            if file.path.hasPrefix(dir.path) { try FileManager.default.moveItem(at: file, to: copy) }
            else { try FileManager.default.copyItem(at: file, to: copy) }
        } catch {
            model.error = "Could not read \(name)."
            return nil
        }
        let task = session.uploadTask(with: model.api.upload(session: sessionID, name: name, asTake: asTake, shot: shot), fromFile: copy)
        task.taskDescription = copy.path
        let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? 0
        items.append(Item(id: task.taskIdentifier, name: name, session: sessionID, asTake: asTake, total: size))
        task.resume()
        return task.taskIdentifier
    }

    /// A take from the outbox. The file stays where it is: the outbox deletes it once the Mac has it.
    func start(_ op: Outbox.Op, file: URL) {
        guard let model else { return }
        var r = model.outbox.request(op)
        r.timeoutInterval = 600
        let task = session.uploadTask(with: r, fromFile: file)
        task.taskDescription = op.id.uuidString
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        items.removeAll { $0.op == op.id }
        items.append(Item(id: task.taskIdentifier, name: op.name ?? "take", session: op.session,
                          asTake: op.query["as"] == "take", total: size, op: op.id))
        task.resume()
    }

    func clearDone() { items.removeAll { $0.done && $0.failed == nil } }
}

extension Uploads: URLSessionDataDelegate {
    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData _: Int64,
                                totalBytesSent sent: Int64, totalBytesExpectedToSend total: Int64) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            // The callback comes many times a second: redraw the bar at most once per 1%.
            let t = total > 0 ? total : items[i].total
            let step = max(t / 100, 1)
            guard sent == t || sent / step != items[i].sent / step || items[i].total != t else { return }
            items[i].sent = sent
            items[i].total = t
        }
    }

    nonisolated func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        MainActor.assumeIsolated { answers[id, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let op = task.taskDescription.flatMap(UUID.init(uuidString:))
        if op == nil, let f = task.taskDescription { try? FileManager.default.removeItem(atPath: f) }
        MainActor.assumeIsolated {
            let body = answers.removeValue(forKey: id) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let op {
                model?.outbox.uploaded(op, status: error == nil ? status : 0,
                                       error: (json?["error"] as? String) ?? error?.localizedDescription)
                // No Mac: the take waits on the phone (the bar says so), no red error.
                if error != nil || status == 0 { items.removeAll { $0.id == id }; return }
            }
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].done = true
            if let error {
                items[i].failed = error.localizedDescription
            } else if status != 200 {
                items[i].failed = (json?["error"] as? String) ?? "The Mac answered \(status)"
            } else {
                items[i].path = json?["path"] as? String
                items[i].sent = items[i].total
                finished?(items[i])
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundDone?()
            backgroundDone = nil
        }
    }
}
