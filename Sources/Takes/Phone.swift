import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI
import UniformTypeIdentifiers

// The iPhone app (2026-10-02, ios/). The user chats with the Claude of each session, watches edits,
// picks covers, sends files and records takes from his phone. Takes is the engine; the phone is a
// remote. The phone reaches this server over Tailscale:
//
//   iPhone ──HTTPS, tailnet only──> tailscale serve :8444 ──> 127.0.0.1:8796 (this server)
//
// Who may talk to it:
//   1. Only tailnet requests: `tailscale serve` adds Tailscale-User-Login. It must be the Mac's
//      own Tailscale login.
//   2. Only a paired phone: the first time, the phone asks; Takes shows "Allow" on the Mac. The
//      phone keeps the token in its Keychain behind Face ID.
// Never `tailscale funnel` this: that puts it on the public internet.

struct PhoneSession: Codable, Hashable {
    var id: String          // path in the library: "<Project>/<session folder>"
    var title: String
    var project: String
    var created: Date
    var updated: Date
    var takes: Int
    var running = false     // Claude is replying
    var unread = false      // Claude replied, not read yet
    var notice = false      // Claude wants him to look at a file
    var published = false
    var archived = false
    var preview: String?    // a picture or video for the row's thumbnail (a path for /thumb)
    /// How far the video got, for the phone's cards: idea, script, board, recorded, edit, posted.
    var stage: String?
    var shots: Int?         // storyboard shots, when there is a storyboard
    /// Its posts that are ready, scheduled or posted, for the list's dots and times (2026-10-09).
    var plan: [PhonePlanned]? = nil
}

/// One post in the posting plan (PostQueue), as the Mac's sidebar shows it on the session's row.
struct PhonePlanned: Codable, Hashable {
    var platform: String
    var status: String
    var at: Date?
}

struct PhoneFile: Codable, Hashable {
    var path: String        // absolute
    var name: String
    var folder: String      // "edits", "thumbnails", "takes", …
    var kind: String        // video, image, audio, other
    var size: Int64
    var modified: Date
    var take: Int?
    var keeper: Bool?
    var duration: Double?
    var shot: String?       // a take filed under a storyboard shot
    var model: String?      // the AI model that made it (generated/), as the Mac's Assets tab shows
    /// A take's best cut (2026-10-09).
    var cut: PhoneCut? = nil
    /// An image: the chat box draft of Change Image…, and the ask of Make Final when it is a GPT Image draft.
    var change: String? = nil
    var final: String? = nil
}

/// The storyboard for the phone's Board tab: the shots in order, with their sketch, takes and comments.
struct PhoneShot: Codable {
    var id: String
    var section: String
    var kind: String
    var say: String
    var how: String
    var seconds: Double
    var start: Double
    var image: String?      // absolute path of the sketch, or of the shot's clip (the phone shows a frame)
    var error: String?
    var comments: [Comment]
    /// Width over height of the frame: the storyboard's format, or the clip's own shape (2026-10-05).
    var ratio: Double?
    /// Every clip or still tried (A B C…), the one in the video, and Make Final's ask for each
    /// GPT Image draft among them (2026-10-09). Paths are absolute.
    var variants: [String]? = nil
    var video: String? = nil
    var finals: [String: String]? = nil
    var generating: Bool? = nil
}

struct PhonePost: Codable, Hashable {
    var text: String
    var media: String?
    var cover: String?
    var status: String
    var firstComment: String?
    /// Other versions of the post (posts/variants/), oldest first.
    var variants: [PhonePostVariant] = []
    /// Claude's opening options (posts/hooks.json).
    var hooks: [Hook] = []
    /// Saved versions in posts/history (2026-10-09).
    var history: Int? = nil
}

/// The post for one more platform (X, YouTube, Vertical), next to the LinkedIn post (2026-10-05).
struct PhonePlatformPost: Codable, Hashable {
    var platform: String
    var name: String
    var text: String
    var title: String
    var media: String?
    var cover: String?
    var status: String
    var url: String?
    var limit: Int
    /// Other versions, opening options and saved versions of this post (2026-10-09).
    var variants: [PhonePostVariant]? = nil
    var hooks: [Hook]? = nil
    var history: Int? = nil
    /// When it goes out, in its own zone, and whether the platform still has an older time or text.
    var at: Date? = nil
    var tz: String? = nil
    var needsUpdate: Bool? = nil
    /// Vertical: TikTok, Reels, Shorts (VerticalPlace raw values) it goes to.
    var places: [String]? = nil
}

/// A post on a side a plugin adds to the Post tab (2026-10-07), for example a launch post.
struct PhoneSidePost: Codable, Hashable {
    /// The side's id and name.
    var side: String
    var name: String
    /// The post's file name: what the phone sends back with a change.
    var file: String
    var title: String
    var text: String
    var link: String
    /// "r/ClaudeAI".
    var place: String
    var flair: String
    var user: String
    var media: String
    var status: String
    var postedURL: String
    /// The site's submit page with the title (and link) filled in.
    var submit: String?
    var titleLimit: Int
    var textLimit: Int?
}

struct PhonePostVariant: Codable, Hashable {
    var slug: String
    var name: String
    var author: String
    var note: String
    var text: String
}

/// Who the phone's LinkedIn preview shows as the author: the name, headline and photo set on the Mac.
struct PhoneProfile: Codable, Hashable {
    var name: String
    var headline: String
    var photo: Bool
}

struct PhoneChat: Codable {
    var running: Bool
    var messages: [ChatMessage]
    var context: ChatContext?
    /// Messages waiting for the run to end, as the user wrote them (2026-10-09).
    var queued: [String] = []

    @MainActor init(_ c: ClaudeChat?) {
        running = c?.running ?? false
        messages = c?.messages ?? []
        context = c?.context
        queued = (c?.queued ?? []).map(CopilotAsk.shown)
    }
}

struct PhoneSessionDetail: Codable {
    var session: PhoneSession
    var folder: String
    var script: String
    var files: [PhoneFile]
    var post: PhonePost?
    var chat: PhoneChat
    var openComments: Int
    var profile: PhoneProfile?
    var storyboard: [PhoneShot]?
    /// Every platform with a post, LinkedIn first. Older phones read only `post`.
    var posts: [PhonePlatformPost]?
    /// The posts on the plugins' sides. Nil in the public copy.
    var sides: [PhoneSidePost]?
    /// The style this video is edited in (PhoneStyles.swift).
    var style: PhoneSessionStyle?
    /// The Script tab's draft bar (2026-10-09): the variants, the favorite draft, how many saved
    /// versions there are, and the script's hooks.
    var scriptVariants: [PhonePostVariant]? = nil
    var scriptFavorite: String? = nil
    var scriptHistory: Int? = nil
    var scriptHooks: [Hook]? = nil
    /// Where it is marked published (Platforms.all names; "" for somewhere else), for the More panel.
    var publishedOn: [String]? = nil
}

/// One published post on the phone's performance tab: its latest numbers.
struct PhonePerfPost: Codable {
    var session: String
    var title: String
    var project: String
    var platform: String?
    var url: String?
    var at: Date
    var reach: Int?
    var likes: Int?
    var comments: Int?
    var reposts: Int?
    var measured: Date?
}

/// A phone that asked to pair, waiting for the user to allow it on the Mac.
struct PhonePairRequest: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let login: String
}

/// Paired phones: a name and the SHA-256 of each token. In Application Support/Takes/phones.json.
struct PairedPhone: Codable, Hashable {
    var name: String
    var hash: String
    var paired: Date
    var seen: Date?
}

final class PhoneServer: PhoneHandler, @unchecked Sendable {
    static let port: UInt16 = 8796
    static let httpsPort = 8444
    /// Uploads from the phone go here in the session.
    static let uploads = "uploads"

    private weak var app: AppModel?
    private var listener: PhoneListener?
    private let lock = NSLock()
    private var phones: [PairedPhone] = []
    private var events: [ObjectIdentifier: PhoneConnection] = [:]
    /// The Mac's own Tailscale login. Requests from any other login get no answer.
    private var login: String?
    private var root: URL
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]

    static var phonesFile: URL { ClaudeChat.boardFolder.appending(path: "phones.json") }

    @MainActor
    init(app: AppModel) {
        self.app = app
        root = app.library.root.standardizedFileURL
        phones = (try? JSONDecoder.iso.decode([PairedPhone].self, from: Data(contentsOf: Self.phonesFile))) ?? []
    }

    /// For tests: a server over one folder, with no app and no paired phones. Not started.
    /// `demo` (the README's phone pictures): any caller on 127.0.0.1 may ask, and pairing needs no click.
    init(root: URL, demo: Bool = false) {
        self.root = root.standardizedFileURL
        self.demo = demo
    }
    private var demo = false

    /// Whose posts these are. The demo never shows the Mac's own profile: only the made-up creator
    /// that scripts/public/demo.py writes to <root>/.creator.json.
    private var currentProfile: PhoneProfile {
        guard demo else { return Self.profile() }
        let c = demoCreator
        return PhoneProfile(name: c["name"] ?? "Sam Rivera", headline: c["headline"] ?? "Video creator",
                            photo: demoPhoto != nil)
    }
    private var demoCreator: [String: String] {
        let f = lock.withLock { root }.appending(path: ".creator.json")
        return ((try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: String]) ?? [:]
    }
    private var demoPhoto: URL? {
        demoCreator["avatar"].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    @MainActor
    func start() {
        let l = PhoneListener(handler: self)
        do { try l.start(port: Self.port) } catch {
            NSLog("Takes phone server: \(error)")
            return
        }
        listener = l
        Task.detached(priority: .utility) { [weak self] in
            let me = Tailscale.login()
            self?.lock.withLock { self?.login = me }
            Tailscale.serve(https: Self.httpsPort, to: Self.port)
        }
        tick = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        awake = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAwake() }
        }
        keepAwake()
    }

    private var tick: Timer?
    private var awake: Timer?

    // MARK: Pairing

    var paired: [PairedPhone] { lock.withLock { phones } }

    private func savePhones() {
        let list = paired
        try? FileManager.default.createDirectory(at: ClaudeChat.boardFolder, withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(list).write(to: Self.phonesFile, options: .atomic)
    }

    @MainActor
    func forgetAll() {
        lock.withLock { phones = [] }
        savePhones()
        keepAwake()
    }

    /// The user clicked Allow or Don't Allow on the Mac.
    @MainActor
    func answer(_ r: PhonePairRequest, allow: Bool) {
        app?.phonePair = nil
        lock.withLock { waiting.removeValue(forKey: r.id) }?.resume(returning: allow)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Who is asking

    /// nil when the request may go on; else the error to send.
    func gate(_ req: PhoneRequest, needsToken: Bool = true) -> PhoneError? {
        if demo { return nil }
        guard let who = req.header("tailscale-user-login") else {
            return PhoneError(403, "Only through Tailscale")
        }
        let me = lock.withLock { login }
        if let me, me.lowercased() != who.lowercased() { return PhoneError(403, "This Tailscale login is not the user's") }
        guard needsToken else { return nil }
        let token = req.header("authorization").map { $0.replacingOccurrences(of: "Bearer ", with: "") }
            ?? req.query["token"] ?? ""
        let h = Self.hash(token)
        let ok: Bool = lock.withLock {
            guard let i = phones.firstIndex(where: { $0.hash == h }) else { return false }
            if (phones[i].seen.map { -$0.timeIntervalSinceNow > 60 } ?? true) { phones[i].seen = Date() }
            return true
        }
        return ok ? nil : PhoneError(401, "This phone is not paired. Pair it again in the app.")
    }

    /// An absolute path in the library, or nil.
    func inLibrary(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let base = lock.withLock { root }.path + "/"
        return url.path.hasPrefix(base) && !url.path.contains("/../") ? url : nil
    }

    func session(_ id: String?) -> URL? {
        guard let id, !id.isEmpty, !id.contains("..") else { return nil }
        let url = lock.withLock { root }.appending(path: id).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.appending(path: "session.json").path) ? url : nil
    }

    // MARK: Requests

    func uploadTarget(_ req: PhoneRequest) -> Result<URL, PhoneError> {
        if let e = gate(req) { return .failure(e) }
        guard req.path == "/api/upload" else { return .failure(PhoneError(404, "No such call")) }
        guard let s = session(req.query["session"]) else { return .failure(PhoneError(404, "No such session")) }
        let name = Self.clean(req.query["name"] ?? "")
        guard !name.isEmpty else { return .failure(PhoneError(400, "The file needs a name")) }
        let dir = s.appending(path: Self.uploads)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return .success(dir.appending(path: ".\(UUID().uuidString).part"))
    }

    /// A safe file name: no folders, no leading dot.
    static func clean(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let safe = last.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.hasPrefix(".") ? String(safe.drop(while: { $0 == "." })) : safe
    }

    func respond(_ req: PhoneRequest) async -> PhoneResponse {
        if req.path == "/api/pair" && req.method == "POST" {
            if let e = gate(req, needsToken: false) { return .error(e.status, e.message) }
            return await pair(req)
        }
        if req.path == "/api/ping" {
            if let e = gate(req, needsToken: false) { return .error(e.status, e.message) }
            return .encode(["ok": "takes"])
        }
        if let e = gate(req) {
            if let f = req.file { try? FileManager.default.removeItem(at: f) }
            return .error(e.status, e.message)
        }
        if req.path.hasPrefix("/api/chat"), let lane = Self.lane(req.query["id"]) {
            return await boardChat(req, lane: lane)
        }
        if !Features.socialBoards, req.path.hasPrefix("/api/copilot") || req.path == "/api/performance" {
            return .error(404, "Not in this build")
        }
        // The demo shows no phone build: that is this Mac's own.
        if demo && req.path.hasPrefix("/api/update") { return .error(404, "Not in the demo") }
        switch (req.method, req.path) {
        case ("GET", "/api/update"): return .encode(PhoneUpdate.shared.status())
        case ("POST", "/api/update/install"):
            // The install ends the app on the phone, so answer before it starts.
            guard PhoneUpdate.shared.staged() != nil else { return .error(404, "No update waits") }
            PhoneUpdate.shared.install()
            return .encode(PhoneUpdate.shared.status())
        case ("GET", "/api/sessions"): return .encode(await sessions())
        case ("POST", "/api/sessions"):
            // {"project": "…", "title": "…", "idea": "…"}: all optional. An idea goes to the new
            // session's Claude as the first message.
            let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
            return await MainActor.run { self.create(project: b["project"], title: b["title"], idea: b["idea"]) }
        case ("GET", "/api/projects"):
            return .encode(projects())
        case ("GET", "/api/copilot"):
            return .json(await copilot())
        case ("GET", "/api/copilot/photo"):
            guard let f = copilotPhoto(req.query["id"]) else { return .error(404, "No photo") }
            return .file(f, type: Self.type(of: f))
        case ("POST", "/api/copilot"):
            // {"id": "…", "action": "approve" | "decline" | "feedback" | "skip" | "unskip" | "pullback" | "posted" | "best", …}
            let b = ((try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]) ?? [:]
            return await MainActor.run { self.decide(b) }
        case ("POST", "/api/copilot/run"):
            // {"lane": "find" | "post", "count": 5}
            let b = ((try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]) ?? [:]
            return await MainActor.run { self.run(lane: b["lane"] as? String ?? "find", count: b["count"] as? Int) }
        case ("GET", "/api/session"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return .encode(await detail(s))
        case ("GET", "/api/chat"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return .encode(await chat(s))
        case ("POST", "/api/chat"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
            return await send(b["text"] ?? "", to: s, origin: Self.origin(b), tokens: b["tokens"] == "1")
        case ("POST", "/api/chat/stop"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            await MainActor.run { self.app?.chats.existing(s)?.stop() }
            return .encode(["ok": true])
        case ("POST", "/api/chat/read"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            await MainActor.run {
                self.app?.chats.existing(s)?.unread = false
                self.app?.notices.removeAll { $0.session == s }
            }
            return .encode(["ok": true])
        case ("POST", "/api/cover"):
            // Older phones still send it; the cover goes to the LinkedIn post unless ?platform= says.
            guard let img = inLibrary(req.query["path"]), Cover.can(img) else { return .error(400, "Only a thumbnail in a session can be a cover") }
            let p = req.query["platform"].flatMap(PostPlatform.init(rawValue:)) ?? .linkedin
            await MainActor.run { self.app?.useCover(img, on: p) }
            return .encode(["ok": true])
        case ("POST", "/api/archive"):
            // ?id=…&on=1 (archive) or on=0 (back to the list).
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let on = req.query["on"] != "0"
            await MainActor.run {
                if let lib = self.app?.library { lib.setArchived([s], on) } else if let d = self.doc(s) {
                    d.meta.archived = on ? true : nil
                    d.save()
                }
            }
            return .encode(["ok": true])
        case ("POST", "/api/keeper"):
            guard let s = session(req.query["id"]), let n = Int(req.query["take"] ?? "") else { return .error(400, "Which take?") }
            await MainActor.run { self.doc(s)?.toggleKeeper(n) }
            return .encode(["ok": true])
        case ("GET", "/api/comments"):
            guard let s = commentRoot(req.query["id"]) else { return .error(404, "No such session") }
            return .encode(CommentStore.read(s).comments)
        case ("POST", "/api/comments"):
            // {"file": "script.md" | "posts/linkedin.md", "quote": "…" (none = all of it), "text": "…"}
            // or {"file": "edits/hook-v2.mp4", "start": 3.0, "end": 6.0, "rect": [x, y, w, h], "text": "…"}
            // or {"file": "storyboard/storyboard.json", "shot": "s3", "text": "…"}: feedback on a storyboard shot.
            guard let s = commentRoot(req.query["id"]) else { return .error(404, "No such session") }
            guard let b = try? JSONDecoder().decode(PhoneComment.self, from: req.body),
                  let text = b.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .error(400, "A comment needs some text")
            }
            if let shot = b.shot, !shot.isEmpty {
                guard Storyboard.read(s)?.shots.contains(where: { $0.id == shot }) == true else { return .error(404, "No such shot") }
                return .encode(CommentStore.addText(s, file: Storyboard.commentFile, quote: nil, text: text, shot: shot))
            }
            if Self.commentable(b.file) || (library(req.query["id"]) != nil && ["README.md", "tokens.json"].contains(b.file)) {
                let quote = b.quote.flatMap { $0.isEmpty ? nil : $0 }
                return .encode(CommentStore.addText(s, file: b.file, quote: quote, text: text))
            }
            guard Self.commentableMedia(b.file, in: s) else { return .error(400, "Comments go on a script, a post, a video or a picture") }
            let rect = b.rect.flatMap { r in r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil }
            let video = Asset.kind(of: s.appending(path: b.file)) == .video
            let end = b.end.flatMap { e in b.start.map { e - $0 >= 0.1 ? e : nil } ?? nil }
            return .encode(CommentStore.addMedia(s, file: b.file, start: video ? b.start ?? 0 : nil,
                                                 end: video ? end : nil, rect: rect, text: text))
        case ("POST", "/api/comments/reply"):
            // {"id": "c3", "text": "…"} or {"id": "c3", "resolved": "true" | "false"}
            guard let s = commentRoot(req.query["id"]) else { return .error(404, "No such session") }
            guard let b = try? JSONDecoder().decode([String: String].self, from: req.body), let id = b["id"] else {
                return .error(400, "Which comment?")
            }
            CommentStore.change(s) { f in
                guard let i = f.comments.firstIndex(where: { $0.id == id }) else { return }
                if let t = b["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    f.comments[i].replies = (f.comments[i].replies ?? []) + [Reply(by: "user", text: t, at: ISO8601DateFormatter().string(from: Date()))]
                    f.comments[i].status = "open"
                }
                if let r = b["resolved"] { f.comments[i].status = r == "true" ? "resolved" : "open" }
            }
            return .encode(CommentStore.read(s).comments.first { $0.id == id })
        case ("POST", "/api/script"), ("POST", "/api/post"):
            // {"text": "…", "base": the text the phone started from}. A text that changed on the Mac
            // since then (Claude, or an edit there) is not overwritten: 409, and the phone reloads.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            guard let b = try? JSONDecoder().decode([String: String].self, from: req.body), let text = b["text"] else {
                return .error(400, "No text")
            }
            let ok = await MainActor.run {
                req.path == "/api/script" ? self.saveScript(text, base: b["base"], in: s)
                    : self.savePost(text, base: b["base"], in: s, req.query["platform"].flatMap(PostPlatform.init(rawValue:)) ?? .linkedin)
            }
            return ok ? .encode(["ok": true]) : .error(409, "It changed on the Mac while you edited. Pull to reload, then edit again.")
        case ("POST", "/api/post/draft"):
            // {"action": "promote", "slug"}: the variant becomes the post that goes out.
            // {"action": "hook", "hook": id, "draft": "main" | slug}: the hook opens that draft.
            // {"action": "save", "slug", "text", "base"}: an edit of a variant.
            // ?platform= (2026-10-09): X, YouTube and vertical have variants and hooks too. Also
            // {"action": "new" | "delete" | "rename" | "restore", "slug", "name", "path"}.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            guard let b = try? JSONDecoder().decode([String: String].self, from: req.body) else { return .error(400, "No action") }
            let p = req.query["platform"].flatMap(PostPlatform.init(rawValue:)) ?? .linkedin
            let failed = await MainActor.run { Self.postStoreDraft(b, in: s, p) }
            if let failed { return .error(failed.hasPrefix("It changed") ? 409 : 400, failed) }
            return .encode(["ok": true])
        case ("POST", "/api/side"):
            // ?side=hn: {"file", and "title", "text" or "status", "base": the text the phone started from}.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            guard let side = Plugins.postSide(req.query["side"] ?? ""), side.phoneSave != nil else { return .error(404, "No such side") }
            guard let b = try? JSONDecoder().decode([String: String].self, from: req.body) else { return .error(400, "No change") }
            let failed = await MainActor.run { side.phoneSave?(s, b) }
            if let failed { return .error(failed.hasPrefix("It changed") ? 409 : 400, failed) }
            return .encode(["ok": true])
        case ("GET", "/api/styles"):
            return .encode(await styles())
        case ("GET", "/api/style"):
            // ?name=<Style>, or ?id=<library folder inside the root> (a project's own looks).
            let dir = req.query["name"].flatMap { n in StyleLib.styleNames(root: libraryRoot).contains(n) ? StyleLib.style(n, root: libraryRoot) : nil }
                ?? library(req.query["id"])
            guard let dir else { return .error(404, "No such style") }
            return .encode(await style(dir))
        case ("POST", "/api/style"):
            let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
            return await MainActor.run { self.changeStyle(b) }
        case ("POST", "/api/session/style"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
            return await MainActor.run { self.setStyle(b, in: s) }
        case ("GET", "/api/profile/photo"):
            if demo { return demoPhoto.map { .file($0, type: "image/jpeg") } ?? .error(404, "No photo") }
            guard FileManager.default.fileExists(atPath: LinkedIn.photoURL.path) else { return .error(404, "No photo") }
            return .file(LinkedIn.photoURL, type: "image/jpeg")
        case ("GET", "/api/performance"):
            return .json(performance())
        case ("PUT", "/api/upload"):
            return await finishUpload(req)
        case ("GET", "/api/events"): return .events
        case ("GET", "/media"), ("HEAD", "/media"):
            guard let f = inLibrary(req.query["path"]), FileManager.default.fileExists(atPath: f.path) else { return .error(404, "No such file") }
            return .file(f, type: Self.type(of: f))
        case ("GET", "/thumb"):
            guard let f = inLibrary(req.query["path"]) else { return .error(404, "No such file") }
            guard let jpg = await Self.thumb(f, width: Int(req.query["w"] ?? "") ?? 480) else { return .error(404, "No picture") }
            return .file(jpg, type: "image/jpeg")
        default:
            return await actions(req) ?? .error(404, "No such call")
        }
    }

    /// The author of the phone's LinkedIn previews. The same defaults as the post tab's @AppStorage.
    /// Each platform's post that exists, with its cover: the phone's Post tab switches between them.
    @MainActor static func platformPosts(_ s: URL) -> [PhonePlatformPost]? {
        let all = Cover.platforms().compactMap { p -> PhonePlatformPost? in
            guard let c = PostFile.read(s, p) else { return nil }
            return PhonePlatformPost(platform: p.rawValue, name: p.name, text: c.text, title: c.title,
                                     media: PostFile.media(c, in: s, p)?.path, cover: Cover.current(s, p)?.path,
                                     status: c.status.rawValue, url: c.meta["url"], limit: p.limit,
                                     variants: PostFile.variants(s, p).map { PhonePostVariant(slug: $0.slug, name: $0.name, author: $0.author, note: $0.note, text: $0.text) },
                                     hooks: HookStore.read(file: PostFile.hooksURL(s, p)).hooks,
                                     history: PostFile.versionCount(s, p),
                                     at: c.at, tz: c.at == nil ? nil : c.tz.identifier, needsUpdate: c.needsUpdate,
                                     places: p == .vertical ? c.places.map(\.rawValue) : nil)
        }
        // The blog article (Features.blog): the phone shows it as the blog does (2026-10-09).
        var withArticle = all
        if Features.blog, let c = PostFile.read(s, .article) {
            withArticle.append(PhonePlatformPost(platform: "article", name: PostPlatform.article.name, text: c.text, title: c.title,
                                                 media: nil, cover: nil, status: c.status.rawValue, url: c.meta["url"],
                                                 limit: PostPlatform.article.limit, history: PostFile.versionCount(s, .article),
                                                 at: c.at, tz: c.at == nil ? nil : c.tz.identifier, needsUpdate: c.needsUpdate))
        }
        return withArticle.isEmpty ? nil : withArticle
    }

    /// Width over height of a clip's picture, turned the way it plays. Nil if it has no video.
    static func clipRatio(_ url: URL) async -> Double? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, turn) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(turn)
        return r.width > 0 && r.height > 0 ? Double(abs(r.width) / abs(r.height)) : nil
    }

    static func profile() -> PhoneProfile {
        let d = UserDefaults.standard
        return PhoneProfile(name: d.string(forKey: "linkedinName") ?? "You",
                            headline: d.string(forKey: "linkedinHeadline")
                                ?? "",
                            photo: FileManager.default.fileExists(atPath: LinkedIn.photoURL.path))
    }

    /// The phone's script edit. An open session takes it through its document (so the Mac's editor
    /// shows it at once); a closed one through a document of its own. Both keep the old and the
    /// new text in history.
    @MainActor private func saveScript(_ text: String, base: String?, in s: URL) -> Bool {
        let open = app?.library.current.flatMap { $0.url == s ? $0 : nil }
        let doc = open ?? SessionDoc(url: s)
        if let base, doc.script != base, doc.script != text { return false }
        guard doc.script != text else { return true }
        doc.snapshot(note: "Before the phone edit")
        doc.script = text
        doc.flushScript()
        doc.snapshot(note: "Edited on the phone")
        return true
    }

    @MainActor private func savePost(_ text: String, base: String?, in s: URL, _ p: PostPlatform = .linkedin) -> Bool {
        let old = PostFile.read(s, p)
        if let base, let old, old.text != base, old.text != text { return false }
        guard old?.text != text else { return true }
        if let old { PostFile.snapshot(s, draft: "main", text: old.text, note: "Before the phone edit", p) }
        var c = old ?? PostFile.Content(text: text)
        c.text = text
        PostFile.write(c, to: s, p)
        PostFile.snapshot(s, draft: "main", text: text, note: "Edited on the phone", p)
        return true
    }

    /// Variants and hooks of the LinkedIn post, through the Mac post tab's own PostStore. Nil when
    /// done, or what went wrong.
    @MainActor static func postDraft(_ b: [String: String], in s: URL) -> String? {
        postStoreDraft(b, in: s, .linkedin)
    }

    /// The script, its variants, and the posts. Not media: those need a time and a frame.
    /// A video or picture inside the session.
    static func commentableMedia(_ file: String, in session: URL) -> Bool {
        guard !file.isEmpty, !file.contains(".."), !file.hasPrefix("/") else { return false }
        let url = session.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return Asset.kind(of: url) == .video || Asset.kind(of: url) == .image
    }

    static func commentable(_ file: String) -> Bool {
        !file.contains("..") && (file == "script.md" || (file.hasPrefix("variants/") && file.hasSuffix(".md"))
            || PostPlatform.allCases.contains { file == $0.rel }
            || (file.hasPrefix("posts/variants/") && file.hasSuffix(".md")))
    }

    /// The Signal dashboard (social.json as it is) and the latest numbers of each published post.
    private func performance() -> Data {
        let fm = FileManager.default
        let root = lock.withLock { self.root }
        var posts: [PhonePerfPost] = []
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        where !project.lastPathComponent.hasPrefix("_") {
            for s in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                guard let meta = Store.readMeta(s) else { continue }
                for p in meta.published ?? [] {
                    let last = p.latest
                    posts.append(PhonePerfPost(session: String(s.path.dropFirst(root.path.count + 1)), title: meta.title,
                                               project: project.lastPathComponent, platform: p.platform, url: p.url, at: p.at,
                                               reach: last?.reach, likes: last?.likes, comments: last?.comments,
                                               reposts: last?.reposts, measured: last?.at))
                }
            }
        }
        posts.sort { $0.at > $1.at }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let list = (try? enc.encode(posts)) ?? Data("[]".utf8)
        let social = (try? Data(contentsOf: SocialData.file(root))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) != nil ? $0 : nil }
        var out = Data("{\"posts\":".utf8)
        out.append(list)
        out.append(Data(",\"social\":".utf8))
        out.append(social ?? Data("null".utf8))
        out.append(Data(",\"profile\":".utf8))
        out.append((try? enc.encode(currentProfile)) ?? Data("null".utf8))
        out.append(Data("}".utf8))
        return out
    }

    private func pair(_ req: PhoneRequest) async -> PhoneResponse {
        if demo { return .encode(["token": "demo"]) }
        let name = (try? JSONDecoder().decode([String: String].self, from: req.body))?["name"] ?? "iPhone"
        let r = PhonePairRequest(name: String(name.prefix(60)), login: req.header("tailscale-user-login") ?? "")
        let allowed: Bool = await withCheckedContinuation { c in
            lock.withLock { waiting[r.id] = c }
            Task { @MainActor in self.app?.phonePair = r }
            // No answer in two minutes: no.
            Task {
                try? await Task.sleep(for: .seconds(120))
                await MainActor.run { if self.app?.phonePair == r { self.app?.phonePair = nil } }
                self.lock.withLock { self.waiting.removeValue(forKey: r.id) }?.resume(returning: false)
            }
        }
        guard allowed else { return .error(403, "Not allowed on the Mac") }
        let token = Self.newToken()
        lock.withLock { phones.append(PairedPhone(name: r.name, hash: Self.hash(token), paired: Date())) }
        savePhones()
        await MainActor.run {
            self.app?.show(toast: "\(r.name) can now use Takes")
            self.keepAwake()
        }
        return .encode(["token": token])
    }

    // MARK: Library

    private func sessions() async -> [PhoneSession] {
        let (root, state) = await MainActor.run { () -> (URL, [URL: (Bool, Bool, Bool)]) in
            var state: [URL: (Bool, Bool, Bool)] = [:]
            for c in self.app?.chats.all ?? [] {
                if let s = c.session { state[s.standardizedFileURL] = (c.running, c.unread, false) }
            }
            for n in self.app?.notices ?? [] {
                if let s = n.session { state[s, default: (false, false, false)].2 = true }
            }
            return (self.app?.library.root.standardizedFileURL ?? self.root, state)
        }
        lock.withLock { self.root = root }
        let fm = FileManager.default
        var out: [PhoneSession] = []
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for p in projects where p.hasDirectoryPath && !p.lastPathComponent.hasPrefix("_") {
            let dirs = (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for d in dirs where d.hasDirectoryPath {
                let s = d.standardizedFileURL
                guard let meta = Store.readMeta(s) else { continue }
                out.append(summary(s, meta: meta, root: root, state: state[s]))
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }

    private func summary(_ s: URL, meta: SessionMeta, root: URL, state: (Bool, Bool, Bool)?) -> PhoneSession {
        let chatDate = Store.modified(ClaudeChat.file(s))
        let shots = Storyboard.read(s)?.shots.count
        let updated = [meta.createdAt, chatDate, Store.modified(s.appending(path: "session.json")), Store.modified(s.appending(path: "edits"))]
            .compactMap { $0 }.max() ?? meta.createdAt
        return PhoneSession(id: String(s.path.dropFirst(root.path.count + 1)), title: meta.title,
                            project: s.deletingLastPathComponent().lastPathComponent, created: meta.createdAt,
                            updated: updated, takes: Set(meta.takes.map(\.number)).count,
                            running: state?.0 ?? false, unread: state?.1 ?? false, notice: state?.2 ?? false,
                            published: !(meta.published ?? []).isEmpty, archived: meta.archived == true,
                            preview: Self.preview(s, meta: meta)?.path,
                            stage: Self.stage(s, meta: meta, shots: shots), shots: shots,
                            plan: Self.plan(s))
    }

    /// The session's posts that are not drafts: what the Mac's sidebar reads from PostQueue.
    static func plan(_ s: URL) -> [PhonePlanned]? {
        let all = PostPlatform.allCases.compactMap { p -> PhonePlanned? in
            guard let c = PostFile.read(s, p), c.status != .draft else { return nil }
            return PhonePlanned(platform: p.rawValue, status: c.status.rawValue, at: c.at)
        }
        return all.isEmpty ? nil : all
    }

    /// The phone's row for one session, after a rename or a move gave it a new folder.
    @MainActor func phoneSession(_ s: URL) -> PhoneSession {
        let root = libraryRoot
        let meta = Store.readMeta(s) ?? SessionMeta(title: s.lastPathComponent, createdAt: Date())
        let c = appModel?.chats.existing(s)
        return summary(s, meta: meta, root: root, state: c.map { ($0.running, $0.unread, false) })
    }

    /// The furthest step the session reached: posted, an edit, a take, a storyboard, a script.
    static func stage(_ s: URL, meta: SessionMeta, shots: Int?) -> String {
        if !(meta.published ?? []).isEmpty { return "posted" }
        if PostFile.newest(s.appending(path: "edits"), .video) != nil { return "edit" }
        if !meta.takes.isEmpty { return "recorded" }
        if (shots ?? 0) > 0 { return "board" }
        let script = (try? String(contentsOf: s.appending(path: "script.md"), encoding: .utf8)) ?? ""
        return script.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 ? "script" : "idea"
    }

    /// What the session looks like, best first: the post's cover or media (else the newest edit or
    /// thumbnail), the keeper take, the newest take, a still, the first storyboard sketch.
    static func preview(_ s: URL, meta: SessionMeta) -> URL? {
        let fm = FileManager.default
        if let c = Cover.current(s), fm.fileExists(atPath: c.path) { return c }
        if let m = PostFile.media(PostFile.read(s), in: s) { return m }
        let takes = meta.takes.sorted { ($0.keeper ? 1 : 0, $0.kind == .camera ? 1 : 0, $0.startedAt) > ($1.keeper ? 1 : 0, $1.kind == .camera ? 1 : 0, $1.startedAt) }
        if let t = takes.lazy.map({ s.appending(path: $0.file) }).first(where: { fm.fileExists(atPath: $0.path) }) { return t }
        if let still = PostFile.newest(s.appending(path: "stills"), .image) { return still }
        if let img = Storyboard.read(s)?.shots.lazy.compactMap(\.image).first {
            let u = Storyboard.folder(s).appending(path: img)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private func detail(_ s: URL) async -> PhoneSessionDetail {
        let root = lock.withLock { self.root }
        let meta = Store.readMeta(s) ?? SessionMeta(title: s.lastPathComponent, createdAt: Date())
        let (state, chat) = await MainActor.run { () -> ((Bool, Bool, Bool), PhoneChat) in
            let c = self.app?.chats.chat(s)
            c?.heal(force: true)
            let notice = self.app?.notices.contains { $0.session == s } ?? false
            return ((c?.running ?? false, c?.unread ?? false, notice),
                    PhoneChat(c))
        }
        var files: [PhoneFile] = []
        let cuts = Self.cuts(s)
        for t in meta.takes {
            let u = s.appending(path: t.file)
            let a = Self.attributes(u)
            files.append(PhoneFile(path: u.path, name: t.name ?? "Take \(t.number)", folder: "takes", kind: "video",
                                   size: a.size, modified: a.modified ?? t.startedAt, take: t.number,
                                   keeper: t.keeper, duration: t.duration, shot: t.shot, cut: cuts[t.number]))
        }
        let fm = FileManager.default
        // Every folder the Mac's Assets tab shows (generated/ and others too, 2026-10-07), not a fixed list.
        for folder in Self.folders(s) {
            let dir = s.appending(path: folder)
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where !u.hasDirectoryPath && !u.lastPathComponent.hasSuffix(".json") {
                let a = Self.attributes(u)
                let kind = Self.kind(u)
                let rel = "\(folder)/\(u.lastPathComponent)"
                files.append(PhoneFile(path: u.standardizedFileURL.path, name: u.lastPathComponent, folder: folder,
                                       kind: kind, size: a.size, modified: a.modified ?? Date(),
                                       model: folder == "generated" ? MadeWith.label(for: u) : nil,
                                       change: kind == "image" ? Higgsfield.imageDraft(rel) : nil,
                                       final: kind == "image" && Higgsfield.isDraft(u) ? Higgsfield.finalAsk(rel) : nil))
            }
        }
        files.sort { $0.modified > $1.modified }
        let first = await MainActor.run { PostFile.firstComment(s) }
        var post = PostFile.read(s).map { c in
            PhonePost(text: c.text, media: PostFile.media(c, in: s)?.path, cover: Cover.current(s)?.path, status: c.status.rawValue,
                      firstComment: first.isEmpty ? nil : first)
        }
        let drafts = await MainActor.run {
            (PostFile.variants(s).map { PhonePostVariant(slug: $0.slug, name: $0.name, author: $0.author, note: $0.note, text: $0.text) },
             HookStore.read(file: PostFile.hooksURL(s)).hooks)
        }
        if var p = post {
            p.variants = drafts.0
            p.hooks = drafts.1
            p.history = await MainActor.run { PostFile.versionCount(s) }
            post = p
        }
        let platforms = await MainActor.run { Self.platformPosts(s) }
        let script = await MainActor.run { () -> ([PhonePostVariant], String?, Int, [Hook]) in
            let d = self.doc(s)
            return ((d?.variants ?? []).map { PhonePostVariant(slug: $0.slug, name: $0.name, author: $0.author, note: $0.note, text: $0.text) },
                    d?.meta.favorite, d?.historyCount ?? 0, HookStore.read(s).hooks)
        }
        let sides = await MainActor.run { Plugins.postSides.flatMap { $0.phone?(s) ?? [] } }
        let allComments = CommentStore.read(s).comments
        let open = allComments.filter(\.open).count
        let profile = currentProfile
        var board: [PhoneShot]?
        if let b = Storyboard.read(s) {
            var shots: [PhoneShot] = []
            for (x, start) in zip(b.shots, b.starts) {
                // A clip shows in its own shape, as on the Mac.
                var ratio = Double(b.ratio)
                if let v = x.video, let r = await Self.clipRatio(s.appending(path: v)) { ratio = r }
                shots.append(PhoneShot(id: x.id, section: x.section.rawValue, kind: x.kind, say: x.say, how: x.how, seconds: x.length,
                          start: start, image: x.video.map { s.appending(path: $0).path } ?? x.image.map { Storyboard.folder(s).appending(path: $0).path },
                          error: x.error,
                          comments: allComments.filter { $0.shot == x.id }, ratio: ratio,
                          variants: x.variants.isEmpty ? nil : Self.shotVariants(x, in: s).all,
                          video: x.video.map { s.appending(path: $0).path },
                          finals: Self.shotVariants(x, in: s).finals.nilIfEmpty,
                          generating: x.generating == nil ? nil : true))
            }
            board = shots
        }
        return PhoneSessionDetail(session: summary(s, meta: meta, root: root, state: state), folder: s.path,
                                  script: (try? String(contentsOf: s.appending(path: "script.md"), encoding: .utf8)) ?? "",
                                  files: files, post: post, chat: chat, openComments: open, profile: profile,
                                  storyboard: board?.isEmpty == false ? board : nil,
                                  posts: platforms, sides: sides.isEmpty ? nil : sides,
                                  style: Self.sessionStyle(s, meta: meta, root: root),
                                  scriptVariants: script.0, scriptFavorite: script.1, scriptHistory: script.2,
                                  scriptHooks: script.3.isEmpty ? nil : script.3,
                                  publishedOn: (meta.published ?? []).map { $0.platform ?? "" })
    }

    private func chat(_ s: URL) async -> PhoneChat {
        await MainActor.run {
            let c = self.app?.chats.chat(s)
            c?.heal(force: true)
            return PhoneChat(c)
        }
    }

    /// Every message to /api/chat comes from the phone. It says which screen the user was on
    /// ("from") and whether he dictated it ("voice": "1"), so Claude knows what "this" is and
    /// reads past transcription slips. A phone without that still counts as the phone.
    nonisolated static func origin(_ b: [String: String]) -> String {
        let place: String
        switch b["from"] {
        case "Chat": place = "in this session's chat"
        case "Files": place = "on this session's Files tab (its takes, edits and other files)"
        case "Script": place = "on this session's Script tab, reading the script"
        case "Board": place = "on this session's Board tab, looking at the storyboard"
        case "Post": place = "on this session's Post tab, looking at the LinkedIn post"
        case "Comments": place = "on the Comments board"
        case "Performance": place = "on the Performance board"
        case "Styles": place = "on the Styles board (every style, its guide, colours, type and parts)"
        case let other?: place = "on the \(other) screen"
        case nil: place = ""
        }
        var s = "The user sent his latest message from the Takes app on his iPhone, not from the Mac"
        s += place.isEmpty ? "." : ", while \(place). \"This\" most likely means what that screen shows."
        if b["voice"] == "1" { s += " He dictated it: read past words the transcription got wrong." }
        return s + " He may be away from the Mac: don't count on him seeing anything on its screen."
    }

    /// `tokens`: a phone from 2026-10-05 on says "@comments" when the open comments should go with
    /// the message, as the Mac's box does. An older phone sends them with every message.
    private func send(_ text: String, to s: URL, origin: String?, tokens: Bool = false) async -> PhoneResponse {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentions = ClaudeChat.mentionsComments(typed)
        let text = tokens ? ClaudeChat.withoutCommentsToken(typed) : typed
        guard !text.isEmpty else { return .error(400, "The message is empty") }
        let meta = Store.readMeta(s)
        let title = meta?.title ?? s.lastPathComponent
        let ok: Bool = await MainActor.run {
            guard let c = self.app?.chats.chat(s) else { return false }
            // While Takes works the message waits in the queue, as on the Mac (2026-10-09: the phone
            // could not queue; the Mac said "still replying").
            c.heal(force: true)
            // A new session from the phone's + starts empty and untitled: the first message is the idea.
            let first = c.messages.isEmpty && meta?.named == false
            let comments = !tokens || mentions
            let said = first ? Self.firstChat(text)
                : comments && !ClaudeChat.isCompact(text) ? ClaudeChat.withComments(text, CommentStore.read(s).comments) : text
            c.send(said, title: title, onStage: nil, origin: origin)
            return true
        }
        return ok ? .encode(["ok": true]) : .error(404, "No chat for this session")
    }

    /// For the style routes (PhoneStyles.swift).
    var libraryRoot: URL { lock.withLock { root } }
    var appModel: AppModel? { app }
    @MainActor func sessionDoc(_ s: URL) -> SessionDoc? { doc(s) }

    @MainActor
    private func doc(_ s: URL) -> SessionDoc? {
        if let d = app?.library.current, d.url.standardizedFileURL == s { return d }
        return SessionDoc(url: s)
    }

    // MARK: New sessions

    /// The projects a new session can go in.
    private func projects() -> [String] {
        let root = lock.withLock { self.root }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return dirs.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") }
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A new session from the phone. The Mac stays on the session it shows.
    @MainActor private func create(project: String?, title: String?, idea: String?) -> PhoneResponse {
        guard let app else { return .error(503, "Takes is not ready") }
        let root = app.library.root.standardizedFileURL
        let name = Self.projectName(project)
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = root.appending(path: name)
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let now = Date()
        let base = "\(SessionDoc.dayFormatter.string(from: now))-\(title.isEmpty ? "untitled" : Library.slug(title))"
        var url = p.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = p.appending(path: "\(base)-\(n)"); n += 1 }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let doc = SessionDoc(url: url)
        doc.meta = SessionMeta(title: title.isEmpty ? "Untitled" : title, createdAt: now, named: !title.isEmpty)
        doc.save()
        app.library.reload()
        // Show it on the Mac too (2026-10-02): a session in another project was easy to miss.
        // With nothing open it opens; else a pill on the stage and a dot on the project waits.
        if app.library.current == nil, !app.isRecording, app.board == nil {
            app.go(url)
        } else {
            let s = url.standardizedFileURL
            app.notices.removeAll { $0.path == s }
            app.notices.append(AgentNotice(path: s, session: s))
        }
        let idea = (idea ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !idea.isEmpty {
            app.chats.chat(url).send(Self.firstAsk(idea, titled: !title.isEmpty), title: doc.meta.title, onStage: nil)
        }
        let s = url.standardizedFileURL
        var out = summary(s, meta: doc.meta, root: root, state: nil)
        out.running = !idea.isEmpty
        return .encode(out)
    }

    /// "Inbox" when none is given. No folders, no hidden or "_" names.
    static func projectName(_ raw: String?) -> String {
        let clean = (raw ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(clean.drop { $0 == "." || $0 == "_" })
        return safe.isEmpty ? "Inbox" : safe
    }

    /// The first message to a new session's Claude: The user's idea and what to do with it.
    static func firstAsk(_ idea: String, titled: Bool) -> String {
        idea + "\n\n(New session from my phone. Write a first script in script.md"
            + (titled ? "." : " and give the session a short title.") + ")"
    }

    /// The first message in an untitled session: what the user said, and what to do with it.
    static func firstChat(_ text: String) -> String {
        text + "\n\n(New session from my phone. Talk the idea through with me. When you know what the video "
            + "is about, give the session a short title; write script.md when I ask or the idea is clear.)"
    }

    // MARK: Comment copilot

    /// The boards' chats: "find" or "post" (Comments), "performance". The phone names them
    /// board:comments, board:comments-post and board:performance.
    static func lane(_ id: String?) -> String? {
        switch id {
        case "board:comments": "find"
        case "board:comments-post": "post"
        case "board:performance": "performance"
        case "board:styles": "styles"
        default: nil
        }
    }

    @MainActor private func boardChat(_ lane: String) -> ClaudeChat? {
        guard let hub = app?.chats else { return nil }
        switch lane {
        case "post": return hub.commentsPost
        case "performance": return hub.board
        case "styles": return hub.styles
        default: return hub.comments
        }
    }

    private func boardChat(_ req: PhoneRequest, lane: String) async -> PhoneResponse {
        switch (req.method, req.path) {
        case ("GET", "/api/chat"):
            return .encode(await MainActor.run { () -> PhoneChat in
                let c = self.boardChat(lane)
                // The phone asks: a chat that says it runs with no live process settles now.
                c?.heal(force: true)
                return PhoneChat(c)
            })
        case ("POST", "/api/chat"):
            let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
            let text = (b["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .error(400, "The message is empty") }
            // While a run works, the message steers it (as ⌘Return on the Mac).
            await MainActor.run { self.boardChat(lane)?.send(text, title: lane == "performance" ? "Performance" : lane == "styles" ? "Styles" : "Comments", onStage: nil, now: true, origin: Self.origin(b)) }
            return .encode(["ok": true])
        case ("POST", "/api/chat/stop"):
            await MainActor.run { self.boardChat(lane)?.stop() }
            return .encode(["ok": true])
        case ("POST", "/api/chat/read"):
            await MainActor.run { self.boardChat(lane)?.unread = false }
            return .encode(["ok": true])
        default:
            return .error(404, "No such call")
        }
    }

    /// Every suggestion as its file has it, and what runs now.
    private func copilot() async -> Data {
        let (root, finding, posting, redrafting) = await MainActor.run { () -> (URL, Bool, Bool, Bool) in
            let root = self.app?.library.root ?? self.root
            return (root, self.app?.chats.comments.running ?? false, self.app?.chats.commentsPost.running ?? false,
                    self.app?.copilot.runner.running ?? false)
        }
        let dir = CopilotStore.suggestions(root)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let items = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] }
            .sorted { ($0["created"] as? String ?? "") < ($1["created"] as? String ?? "") }
        var out: [String: Any] = ["items": items, "finding": finding, "posting": posting, "redrafting": redrafting]
        // Your name and photo, for your comment under the post (as on LinkedIn).
        if let p = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(currentProfile)) { out["profile"] = p }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// The post author's photo, saved next to the suggestion.
    private func copilotPhoto(_ id: String?) -> URL? {
        guard let id, !id.isEmpty, !id.contains("/"), !id.contains("..") else { return nil }
        let dir = CopilotStore.suggestions(lock.withLock { root })
        guard let data = try? Data(contentsOf: dir.appending(path: id + ".json")),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let photo = (d["post"] as? [String: Any])?["photo"] as? String else { return nil }
        let f = dir.appending(path: Self.clean(photo))
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// The user's decision from the phone, the same as on the board.
    @MainActor private func decide(_ b: [String: Any]) -> PhoneResponse {
        guard let app, let id = b["id"] as? String, let action = b["action"] as? String else { return .error(400, "Which suggestion?") }
        let store = app.copilot
        store.scan(app.library.root)
        guard let s = store.items.first(where: { $0.id == id }) else { return .error(404, "No such suggestion") }
        let text = (b["text"] as? String) ?? ""
        let variant = b["variant"] as? Int
        switch action {
        case "approve":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, "The comment is empty") }
            store.approve(s, text: text, variant: variant ?? 0)
        case "decline":
            let reason = DeclineReason(rawValue: b["reason"] as? String ?? "") ?? .other
            store.decline(s, wrongPost: b["wrongPost"] as? Bool ?? false, reason: reason, note: b["note"] as? String ?? "")
        case "feedback":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .error(400, "The note is empty") }
            store.feedback(s, note: text, variant: variant, edit: b["edit"] as? String, send: true)  // the phone has no feedback pill
        case "skip": store.skip(s)
        case "unskip": store.unskip(s.id)
        case "pullback": store.pullBack(s)
        case "posted": store.markPosted(s, url: b["url"] as? String ?? "")
        case "best": store.toggleBest(s)
        default: return .error(400, "No such action")
        }
        return .encode(["ok": true])
    }

    /// Run now (find posts) or Post approved, as on the board: a new conversation in its chat.
    /// The Mac's panel stays as it is.
    @MainActor private func run(lane: String, count: Int?) -> PhoneResponse {
        guard let app, let c = boardChat(lane) else { return .error(503, "Takes is not ready") }
        guard !c.running else { return .error(409, "It is still running.") }
        let ask: String
        if lane == "post" {
            app.copilot.scan(app.library.root)
            let n = app.copilot.approved.count
            guard n > 0 else { return .error(400, "Nothing approved to post") }
            ask = CopilotAsk.post(n)
        } else {
            ask = CopilotAsk.find(min(max(count ?? 5, 1), 15))
        }
        c.reset()
        c.send(ask, title: "Comments", onStage: nil)
        return .encode(["ok": true])
    }

    // MARK: Uploads

    private func finishUpload(_ req: PhoneRequest) async -> PhoneResponse {
        guard let part = req.file, let s = session(req.query["session"]) else { return .error(400, "No file") }
        let name = Self.clean(req.query["name"] ?? "file")
        if req.query["as"] == "take" {
            guard Asset.kind(of: URL(fileURLWithPath: name)) == .video else {
                try? FileManager.default.removeItem(at: part)
                return .error(400, "A take must be a video")
            }
            let ext = (name as NSString).pathExtension.lowercased()
            let duration = try? await AVURLAsset(url: part, options: [AVURLAssetOverrideMIMETypeKey: "video/quicktime"]).load(.duration).seconds
            let file: String? = await MainActor.run {
                guard let doc = self.doc(s) else { return nil }
                let n = doc.nextTakeNumber
                let f = SessionDoc.takeFile(number: n, slug: "", kind: .camera, ext: ext.isEmpty ? "mov" : ext)
                guard (try? FileManager.default.moveItem(at: part, to: s.appending(path: f))) != nil else { return nil }
                var t = Take(number: n, kind: .camera, file: f, startedAt: Date())
                t.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                t.name = "Phone"
                // A take recorded for a storyboard shot on the phone's Board tab.
                if let shot = req.query["shot"], Storyboard.read(s)?.shots.contains(where: { $0.id == shot }) == true {
                    t.shot = shot
                }
                doc.addTakes([t])
                if t.shot != nil { doc.fileShotTake(n) }
                self.app?.library.reload()
                self.app?.show(toast: "Take \(n) came from the phone")
                return doc.meta.takes.first { $0.number == n }?.file ?? f
            }
            guard let file else { try? FileManager.default.removeItem(at: part); return .error(500, "Could not add the take") }
            return .encode(["path": s.appending(path: file).path])
        }
        let dir = s.appending(path: Self.uploads)
        var target = dir.appending(path: name)
        var i = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            target = dir.appending(path: ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)")
            i += 1
        }
        do { try FileManager.default.moveItem(at: part, to: target) } catch {
            try? FileManager.default.removeItem(at: part)
            return .error(500, "Could not save the file")
        }
        return .encode(["path": target.path])
    }

    // MARK: Live updates

    /// What the phone needs to hear about: each chat's state, and the notices.
    private var said: [String: String] = [:]
    private var lastBeat = Date()

    func eventsOpened(_ c: PhoneConnection) {
        lock.withLock { events[ObjectIdentifier(c)] = c }
        Task { @MainActor in self.said = [:] }
    }

    func eventsClosed(_ c: PhoneConnection) { _ = lock.withLock { events.removeValue(forKey: ObjectIdentifier(c)) } }

    private func broadcast(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return }
        for c in lock.withLock({ Array(events.values) }) { c.event(data) }
    }

    @MainActor
    private func watch() {
        guard let app, !lock.withLock({ events.isEmpty }) else { return }
        let root = app.library.root.standardizedFileURL
        var chats: [(String, ClaudeChat)] = [("board:comments", app.chats.comments), ("board:comments-post", app.chats.commentsPost),
                                              ("board:performance", app.chats.board), ("board:styles", app.chats.styles)]
        for c in app.chats.all {
            guard let s = c.session?.standardizedFileURL, s.path.hasPrefix(root.path + "/") else { continue }
            chats.append((String(s.path.dropFirst(root.path.count + 1)), c))
        }
        for (id, c) in chats {
            let last = c.messages.last
            let sig = "\(c.running)|\(c.unread)|\(c.messages.count)|\(last?.id.uuidString ?? "")|\(last?.text.count ?? 0)|\(last?.done ?? true)|\(c.context?.used ?? 0)|\(c.context?.window ?? 0)"
            guard said["chat:" + id] != sig else { continue }
            said["chat:" + id] = sig
            let tail = c.messages.suffix(3).compactMap { m -> Any? in
                (try? JSONEncoder().encode(m)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            var ev: [String: Any] = ["type": "chat", "id": id, "running": c.running, "unread": c.unread,
                                     "count": c.messages.count, "tail": tail]
            // The ring on the phone follows each reply and a /compact (2026-10-03: it only
            // changed when the chat was opened again).
            if let ctx = c.context { ev["context"] = ["used": ctx.used, "window": ctx.window] }
            broadcast(ev)
        }
        // A suggestion added, changed or redrafted: the phone's Comments tab reloads.
        let copilot = "\(Store.modified(CopilotStore.suggestions(root))?.timeIntervalSince1970 ?? 0)|\(app.copilot.runner.running)"
        if said["copilot"] != copilot {
            said["copilot"] = copilot
            broadcast(["type": "copilot"])
        }
        let notices = app.notices.map(\.path.path)
        let sig = notices.joined(separator: "|")
        if said["notices"] != sig {
            said["notices"] = sig
            broadcast(["type": "notices", "paths": notices])
        }
        if -lastBeat.timeIntervalSinceNow > 20 {
            lastBeat = Date()
            broadcast(["type": "beat"])
        }
    }

    // MARK: Keep the Mac awake

    private var assertion: IOPMAssertionID = 0

    /// A sleeping Mac cannot answer the phone. With a phone paired and the charger in, Takes keeps
    /// the Mac from idle sleep (the display still sleeps). On battery it lets the Mac sleep.
    @MainActor
    private func keepAwake() {
        let charging = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue()) != nil
        let want = charging && !paired.isEmpty
        if want && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Takes: the phone app can reach the Mac" as CFString, &assertion)
        } else if !want && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Files

    static func attributes(_ u: URL) -> (size: Int64, modified: Date?) {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return ((a?[.size] as? NSNumber)?.int64Value ?? 0, a?[.modificationDate] as? Date)
    }

    /// The session's folders with files for the phone: what the Assets tab shows, less the takes
    /// (they come from session.json) and the "_" work folders.
    nonisolated static func folders(_ s: URL) -> [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: s, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: .skipsHiddenFiles)) ?? []
        return dirs.filter(\.hasDirectoryPath).map(\.lastPathComponent)
            .filter { !$0.hasPrefix("_") && !AssetStore.skipFolders.contains($0) }
            .sorted()
    }

    static func kind(_ u: URL) -> String {
        switch Asset.kind(of: u) {
        case .video: "video"
        case .image: "image"
        case .audio: "audio"
        case .other: "other"
        }
    }

    static func type(of u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "md", "txt", "srt", "vtt": return "text/plain; charset=utf-8"
        default: return UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    static var thumbFolder: URL { URL.cachesDirectory.appending(path: "Takes/phone-thumbs") }

    /// A JPEG at most `width` px wide: a frame for a video, the picture for an image. Cached on disk.
    static func thumb(_ u: URL, width: Int) async -> URL? {
        let w = max(64, min(width, 1600))
        let a = attributes(u)
        let key = hash("\(u.path)|\(a.modified?.timeIntervalSince1970 ?? 0)|\(w)")
        let out = thumbFolder.appending(path: key + ".jpg")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try? FileManager.default.createDirectory(at: thumbFolder, withIntermediateDirectories: true)
        var cg: CGImage?
        switch Asset.kind(of: u) {
        case .video:
            let asset = AVURLAsset(url: u)
            let secs = (try? await asset.load(.duration).seconds) ?? 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: w, height: w * 2)
            let at = CMTime(seconds: secs.isFinite && secs > 0 ? min(3, secs * 0.2) : 0, preferredTimescale: 600)
            cg = try? await gen.image(at: at).image
        case .image:
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: w] as CFDictionary)
        default: return nil
        }
        guard let cg, let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}

/// The `tailscale` command. All of it is best effort: without Tailscale the phone cannot connect,
/// and nothing else changes.
enum Tailscale {
    static var binary: String? {
        ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ args: [String]) -> Data? {
        guard let bin = binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// The login of this Mac's Tailscale user, e.g. "someone@gmail.com".
    static func login() -> String? {
        guard let data = run(["status", "--json"]),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = j["Self"] as? [String: Any], let uid = me["UserID"] as? NSNumber,
              let users = j["User"] as? [String: Any], let u = users[uid.stringValue] as? [String: Any] else { return nil }
        return u["LoginName"] as? String
    }

    /// The phone's address: https://<this Mac>.<tailnet>.ts.net:<https>.
    static func address(https: Int) -> String? {
        guard let data = run(["status", "--json"]),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = j["Self"] as? [String: Any], let dns = me["DNSName"] as? String else { return nil }
        let host = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
        return "https://\(host):\(https)"
    }

    /// `tailscale serve` for the tailnet only. It stays set up across restarts; this only adds it
    /// when it is missing.
    static func serve(https: Int, to port: UInt16) {
        if let data = run(["serve", "status", "--json"]), String(decoding: data, as: UTF8.self).contains("127.0.0.1:\(port)") { return }
        _ = run(["serve", "--bg", "--https=\(https)", "http://127.0.0.1:\(port)"])
    }
}

/// "iPhone wants to use Takes": Allow or Don't Allow, at the top of the window.
struct PhonePairBanner: View {
    @Environment(AppModel.self) var app

    var body: some View {
        if let r = app.phonePair {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.name) wants to use Takes").font(Theme.sans(13, .semibold))
                    Text("It can chat with Takes, see your sessions and send files. \(r.login)")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button("Don't Allow") { app.phone?.answer(r, allow: false) }
                Button("Allow") { app.phone?.answer(r, allow: true) }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.top, 12)
        }
    }
}

/// A new comment from the phone: on text (quote) or on a video or picture (start, end, rect).
struct PhoneComment: Decodable {
    var file: String
    var text: String?
    var quote: String?
    var start: Double?
    var end: Double?
    var rect: [Double]?
    var shot: String?
}

extension Dictionary {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
