import Foundation

// The phone's Board and Assets pages (2026-10-09): a shot's variants and its takes' best cuts, the
// B-roll library, and the song and sound effects under the video. Each route calls what the Mac's
// own buttons call (Storyboard.pick, TakeCut.start, BrollLib, SessionDoc.setMusic and addEffect).
// AI makers get no buttons here: the phone asks the chat. The phone side is
// ios/TakesPhone/Library.swift and BoardView.swift. Public.

/// A take's best cut (cuts.json), as the Board's take thumb shows it.
struct PhoneCut: Codable, Hashable {
    var state: String
    var start: Double?
    var end: Double?
    var clean: Bool?
    var why: String?
    var error: String?
    var by: String?
}

/// A clip of the B-roll library.
struct PhoneBrollClip: Codable, Hashable {
    var path: String
    var title: String
    var vertical: Bool?
    var added: Bool
}

struct PhoneBrollFolder: Codable, Hashable {
    var folder: String
    var name: String
    var clips: [PhoneBrollClip]
}

/// A song or an effect of the sound library.
struct PhoneSound: Codable, Hashable {
    var rel: String
    var title: String
    var group: String
    var path: String
}

/// A past conversation of a session's chat, as the Mac's Past conversations list shows it.
struct PhonePastChat: Codable, Hashable {
    var file: String
    var title: String
    var date: Date?
    var count: Int
}

struct PhoneSounds: Codable, Hashable {
    var sounds: [PhoneSound]
}

extension PhoneServer {
    /// The routes in this file, or nil.
    func boardRoutes(_ req: PhoneRequest) async -> PhoneResponse? {
        let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
        switch (req.method, req.path) {
        case ("POST", "/api/shot"):
            // {"action": "pick", "shot", "path"}: that variant goes in the video (Use B in the video).
            // {"action": "cut", "take"}: Find the Best Cut (again). {"action": "unlink", "take"}: Take it off this shot.
            // {"action": "star", "take"}: Star as the keeper, or unstar.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run { self.shot(b, in: s) }
        case ("GET", "/api/broll"):
            let s = session(req.query["id"])
            return .encode(Self.broll(root: libraryRoot, session: s))
        case ("POST", "/api/broll"):
            // {"action": "add" | "remove", "path": a library clip} | {"action": "save", "path": a session video, "folder"}.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return Self.brollChange(b, in: s, root: libraryRoot)
        case ("GET", "/api/sounds"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return .encode(Self.sounds(s, root: libraryRoot))
        case ("POST", "/api/sounds"):
            // {"action": "use", "file", "video"?, "at"?}: ask the chat to mix it into the video.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run { self.soundChange(b, in: s) }
        case ("GET", "/api/chat/history"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                .encode(self.sessionChat(s).past().map { PhonePastChat(file: $0.file.lastPathComponent, title: $0.title, date: $0.date, count: $0.count) })
            }
        case ("POST", "/api/chat/history"):
            // {"action": "resume" | "forget", "file"}: the Mac's Past conversations list (2026-10-09).
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                let c = self.sessionChat(s)
                guard let p = c.past().first(where: { $0.file.lastPathComponent == b["file"] }) else { return .error(404, "No such conversation") }
                switch b["action"] {
                case "resume":
                    if c.running { return .error(409, "Takes is still replying. Try again when it is done.") }
                    c.resume(p)
                case "forget": c.forget(p)
                default: return .error(400, "Resume or forget?")
                }
                return .encode(PhoneChat(c))
            }
        case ("GET", "/api/search"):
            // ?q=&filter=all|takes|edits|broll|stills|scripts&project=: ⌘K (PhoneSearch.swift).
            return await search(req)
        case ("GET", "/api/article"):
            // The blog article as the Mac's Article side draws it (2026-10-09): its page, its blocks and
            // head for takes.render. Private: off where Features.blog is off (the public copy).
            guard Features.blog else { return .error(404, "No such call") }
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            guard let c = PostFile.read(s, .article) else { return .error(404, "No article yet") }
            return .encode(["html": ArticlePage.html, "blocks": ArticleView.Coordinator.blocks(c.text),
                            "head": ArticleHead(c).json, "markdown": c.text, "title": c.title, "folder": s.path])
        case ("GET", "/api/article/font"):
            guard Features.blog, let dir = SessionFiles.fontDir, let n = req.query["name"], !n.contains("/"),
                  FileManager.default.fileExists(atPath: dir.appending(path: n).path) else { return .error(404, "No such font") }
            return .file(dir.appending(path: n), type: "font/woff2")
        case ("GET", "/api/plugins"):
            // The plugin screens the phone shows at the foot of its list (2026-10-09). None in the public copy.
            return .encode(Plugins.all.filter { $0.phone != nil }.map { PhonePluginInfo(id: $0.id, title: $0.title, icon: $0.icon) })
        case ("POST", "/api/chat/new"):
            // New conversation: the open one goes to the history, as the Mac's ⌘N in the chat.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                let c = self.sessionChat(s)
                c.reset()
                return .encode(PhoneChat(c))
            }
        default:
            for hook in Plugins.phoneHooks { if let r = await hook.route(req, libraryRoot) { return r } }
            return nil
        }
    }

    /// The session's chat: the app's own, or one read from disk when there is no app (tests).
    @MainActor private func sessionChat(_ s: URL) -> ClaudeChat {
        appModel?.chats.chat(s) ?? ClaudeChat(session: s)
    }

    // MARK: Shots

    @MainActor private func shot(_ b: [String: String], in s: URL) -> PhoneResponse {
        guard let d = sessionDoc(s) else { return .error(404, "No such session") }
        let take = b["take"].flatMap(Int.init)
        switch b["action"] {
        case "pick":
            guard let id = b["shot"], let p = b["path"] else { return .error(400, "Which shot and clip?") }
            let rel = p.hasPrefix(s.path + "/") ? String(p.dropFirst(s.path.count + 1)) : p
            guard Storyboard.read(s)?.shots.first(where: { $0.id == id })?.variants.contains(rel) == true else {
                return .error(404, "No such variant")
            }
            return Storyboard.pick(s, shot: id, rel) ? .encode(["ok": true]) : .error(500, "Could not change the storyboard")
        case "cut":
            guard let n = take, d.meta.takes.contains(where: { $0.number == n }) else { return .error(404, "No such take") }
            if TakeCut.read(s)[String(n)]?.state == "running" { return .error(409, "Gemini is finding it already") }
            TakeCut.start(s, take: n)
            return .encode(["ok": true])
        case "unlink":
            guard let n = take, d.meta.takes.contains(where: { $0.number == n }) else { return .error(404, "No such take") }
            d.link(take: n, to: nil)
            return .encode(["ok": true])
        case "star":
            guard let n = take, d.meta.takes.contains(where: { $0.number == n }) else { return .error(404, "No such take") }
            d.toggleKeeper(n)
            return .encode(["ok": true])
        default:
            return .error(400, "Pick, cut, unlink or star?")
        }
    }

    /// The shot's variants as paths, and the ask that makes the final of each GPT Image draft.
    static func shotVariants(_ x: StoryShot, in s: URL) -> (all: [String], finals: [String: String]) {
        var finals: [String: String] = [:]
        let all = x.variants.map { rel -> String in
            let u = s.appending(path: rel)
            if Higgsfield.isDraft(u) { finals[u.path] = Higgsfield.finalAsk(rel, shot: x.id) }
            return u.path
        }
        return (all, finals)
    }

    static func cuts(_ s: URL) -> [Int: PhoneCut] {
        var out: [Int: PhoneCut] = [:]
        for (k, c) in TakeCut.read(s) {
            guard let n = Int(k) else { continue }
            out[n] = PhoneCut(state: c.state, start: c.start, end: c.end, clean: c.clean, why: c.why, error: c.error, by: c.by)
        }
        return out
    }

    // MARK: B-roll

    static func broll(root: URL, session: URL?) -> [PhoneBrollFolder] {
        BrollLib.scan(BrollLib.dir(root: root)).map { f in
            PhoneBrollFolder(folder: f.url.lastPathComponent, name: f.name, clips: f.clips.map { c in
                PhoneBrollClip(path: c.url.path, title: c.title, vertical: c.vertical,
                               added: session.map { BrollLib.inSession(c, $0) != nil } ?? false)
            })
        }
    }

    static func brollChange(_ b: [String: String], in s: URL, root: URL) -> PhoneResponse {
        let dir = BrollLib.dir(root: root).standardizedFileURL
        switch b["action"] {
        case "add", "remove":
            guard let p = b["path"], p.hasPrefix(dir.path + "/"), !p.contains(".."),
                  FileManager.default.fileExists(atPath: p) else { return .error(404, "No such clip") }
            let u = URL(fileURLWithPath: p)
            let clip = BrollClip(url: u, folder: u.deletingLastPathComponent().lastPathComponent)
            do {
                if b["action"] == "add" { try BrollLib.add(clip, to: s) } else { try BrollLib.remove(clip, from: s) }
            } catch { return .error(500, "Could not change it: \(error.localizedDescription)") }
            return .encode(["ok": true])
        case "save":
            // Assets' Save to B-roll: Gemini names it and files it, in about a minute.
            guard let p = b["path"], p.hasPrefix(s.path + "/"), !p.contains(".."), FileManager.default.fileExists(atPath: p),
                  Asset.kind(of: URL(fileURLWithPath: p)) == .video else { return .error(404, "No such video") }
            let folder = b["folder"].flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? "Clips"
            guard Voice.launch(["--broll-save", p, folder]) else { return .error(500, "Could not start the save") }
            return .encode(["ok": true])
        default:
            return .error(400, "Add, remove or save?")
        }
    }

    // MARK: Sound

    static func sounds(_ s: URL, root: URL) -> PhoneSounds {
        PhoneSounds(sounds: SoundLib.scan(SoundLib.dir(root: root)).map { PhoneSound(rel: $0.rel, title: $0.title, group: $0.group, path: $0.url.path) })
    }

    /// Use on the phone asks the session's chat, as on the Mac: Takes never plays sound over a video.
    @MainActor private func soundChange(_ b: [String: String], in s: URL) -> PhoneResponse {
        guard b["action"] == "use" else { return .error(400, "Use? Update the Takes app on the phone.") }
        let lib = SoundLib.dir(root: libraryRoot)
        guard let rel = b["file"], !rel.contains(".."), FileManager.default.fileExists(atPath: lib.appending(path: rel).path),
              let sound = SoundLib.scan(lib).first(where: { $0.rel == rel }) else { return .error(404, "No such sound") }
        var video: SoundsPane.EffectRef?
        if let v = b["video"], let at = b["at"].flatMap(Double.init) {
            guard !v.contains(".."), FileManager.default.fileExists(atPath: s.appending(path: v).path) else { return .error(404, "No such video") }
            video = SoundsPane.EffectRef(url: s.appending(path: v), at: (at * 10).rounded() / 10)
        }
        guard let c = appModel?.chats.chat(s) else { return .error(404, "No chat for this session") }
        c.heal(force: true)
        c.send(SoundsPane.ask(sound, video: video, session: s), title: Store.readMeta(s)?.title ?? s.lastPathComponent, onStage: nil,
               origin: Self.origin(["from": "Sound"]), shown: SoundsPane.isEffect(sound) ? "Add “\(sound.title)”" : "Use “\(sound.title)” as the music")
        return .encode(["ok": true])
    }
}
