import Foundation

// The phone's everyday actions (2026-10-09): trash, rename, move, clean voice, script variants and
// history, post history. Each route calls the code the Mac's own buttons call (Library,
// SessionDoc, VoiceMix, PostStore), so the phone never does a thing its own way. The phone side is
// ios/TakesPhone/Actions.swift. Public: everything here works on a fresh Mac.

/// A saved version of the script or a post, for the phone's history list.
struct PhoneVersion: Codable, Hashable {
    var path: String
    var created: Date
    var author: String
    var note: String
    var draft: String
    var draftName: String
    var text: String
}

/// A take's clean voice, as the Mac's Voice panel shows it.
struct PhoneVoice: Codable, Hashable {
    var state: String
    var on: Bool
    var strength: Double
    var quiet: Bool
    var summary: String
    var error: String?
    var started: Date?
    var estimate: Double
    /// The blended WAV edits use, once it exists.
    var file: String?
}

extension PhoneServer {
    /// The routes in this file, or nil when the request is not one of them.
    func actions(_ req: PhoneRequest) async -> PhoneResponse? {
        let b = (try? JSONDecoder().decode([String: String].self, from: req.body)) ?? [:]
        switch (req.method, req.path) {
        case ("POST", "/api/trash"):
            // {"what": "take", "take"} | {"what": "unstarred"} | {"what": "session"} | {"what": "file", "path"}
            // | {"what": "project", "project"}: all to the macOS Trash, as the Mac's menus do.
            if b["what"] == "project" { return await MainActor.run { self.trashProject(b["project"]) } }
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run { self.trash(b, in: s) }
        case ("POST", "/api/rename"):
            // {"what": "take", "take", "name"} | {"what": "session", "name"} | {"what": "project", "project", "name"}
            if b["what"] == "project" { return await MainActor.run { self.renameProject(b["project"], to: b["name"]) } }
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run { self.rename(b, in: s) }
        case ("POST", "/api/move"):
            // {"project": "<name>"}: the session goes to that project. The answer has its new id.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run { self.move(s, to: b["project"]) }
        case ("POST", "/api/published"):
            // {"platform": "LinkedIn" (Platforms.all) or "" for somewhere else, "on": "1" | "0"}
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                guard let d = self.sessionDoc(s) else { return .error(404, "No such session") }
                let p = b["platform"].flatMap { $0.isEmpty ? nil : $0 }
                if let p, !Platforms.all.contains(p) { return .error(400, "No such platform") }
                d.setPublished(p, b["on"] != "0")
                self.appModel?.library.loadSessions()
                return .encode(["ok": true])
            }
        case ("GET", "/api/voice"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                guard let mix = Self.voiceMix(s, req.query) else { return .error(404, "No such take") }
                return .encode(Self.voice(mix))
            }
        case ("POST", "/api/voice"):
            // {"take", "kind", "action": "clean"} cleans (again) from the raw take;
            // {"take", "kind", "action": "set", "on", "strength", "loudness": "normal" | "quiet"} changes the mix.
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                guard let mix = Self.voiceMix(s, b) else { return .error(404, "No such take") }
                switch b["action"] {
                case "clean": mix.start()
                case "set":
                    guard mix.ready else { return .error(409, "Clean the voice first") }
                    if let on = b["on"] { mix.on = on == "1" }
                    if let v = b["strength"].flatMap(Double.init) { mix.strength = max(0, min(1, v)) }
                    if let l = b["loudness"] { mix.quiet = l == "quiet" }
                    mix.changed()
                default: return .error(400, "Clean or set?")
                }
                return .encode(Self.voice(mix))
            }
        case ("GET", "/api/script/history"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            return await MainActor.run {
                guard let d = self.sessionDoc(s) else { return .error(404, "No such session") }
                d.snapshotDirty()
                return .encode(d.versions().map { Self.version($0, name: d.draftName($0.draft)) })
            }
        case ("POST", "/api/script/draft"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let failed = await MainActor.run { () -> String? in
                guard let d = self.sessionDoc(s) else { return "No such session" }
                return Self.scriptDraft(b, in: d)
            }
            if let failed { return .error(failed.hasPrefix("It changed") ? 409 : 400, failed) }
            return .encode(["ok": true])
        case ("GET", "/api/post/history"):
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let p = req.query["platform"].flatMap(PostPlatform.init(rawValue:)) ?? .linkedin
            return await MainActor.run {
                let store = PostStore(p)
                store.load(s)
                return .encode(PostFile.versions(s, p).map { Self.version($0, name: store.name(of: $0.draft)) })
            }
        case ("POST", "/api/schedule"):
            // ?platform=; {"action": "set", "at": ISO 8601, "tz"} | "ready" | "clear" | "draft": the Mac's
            // SchedulePanel (Set time, Ready No Time Yet, Remove the Time, Back to Draft) (2026-10-09).
            guard let s = session(req.query["id"]) else { return .error(404, "No such session") }
            let p = req.query["platform"].flatMap(PostPlatform.init(rawValue:)) ?? .linkedin
            let failed = await MainActor.run { Self.schedule(b, in: s, p) }
            if let failed { return .error(400, failed) }
            return .encode(["ok": true])
        default:
            return await boardRoutes(req)
        }
    }

    // MARK: Schedule

    /// What the Mac's SchedulePanel does, through the same PostStore. Nil when done.
    @MainActor static func schedule(_ b: [String: String], in s: URL, _ p: PostPlatform) -> String? {
        let post = PostStore(p)
        post.load(s)
        defer { post.close() }
        guard let c = post.content else { return "No post yet" }
        switch b["action"] {
        case "set":
            let f = ISO8601DateFormatter()
            guard let d = b["at"].flatMap(f.date(from:)) else { return "Which time?" }
            let z = b["tz"].flatMap(TimeZone.init(identifier:)) ?? c.tz
            post.update { c in
                c.plan(d, in: z)
                if c.status == .draft { c.status = .ready }
            }
        case "ready":
            guard c.status == .draft else { return "It is not a draft" }
            post.update { $0.status = .ready }
        case "clear":
            guard c.at != nil, c.status != .posted else { return "It has no time to remove" }
            post.update { $0.plan(nil, in: $0.tz) }
        case "draft":
            guard c.status != .draft else { return "It is a draft already" }
            post.update { $0.status = .draft; $0.plan(nil, in: $0.tz) }
        default:
            return "Set, ready, clear or draft?"
        }
        return nil
    }

    // MARK: Trash

    @MainActor private func trash(_ b: [String: String], in s: URL) -> PhoneResponse {
        let app = appModel
        switch b["what"] {
        case "take":
            guard let n = b["take"].flatMap(Int.init) else { return .error(400, "Which take?") }
            if app?.isRecording == true { return .error(409, "Takes is recording. Trash it when the take is done.") }
            guard let d = sessionDoc(s), d.meta.takes.contains(where: { $0.number == n }) else { return .error(404, "No such take") }
            // As the Assets menu: the player lets go of it first.
            if d.meta.takes.contains(where: { $0.number == n && d.fileURL($0) == app?.preview }) { app?.preview = nil }
            d.trashTake(n)
            return .encode(["ok": true])
        case "unstarred":
            if app?.isRecording == true { return .error(409, "Takes is recording. Try again when the take is done.") }
            let n: Int
            if let lib = app?.library { n = lib.trashNonKeepers([Store.dir(s)]) } else {
                guard let d = sessionDoc(s) else { return .error(404, "No such session") }
                let losers = Set(d.meta.takes.filter { !$0.keeper }.map(\.number))
                for t in losers { d.trashTake(t) }
                n = losers.count
            }
            return .encode(["trashed": n])
        case "session":
            if app?.isRecording == true, app?.library.current?.url.standardizedFileURL == s {
                return .error(409, "Takes is recording in this session.")
            }
            if app?.chats.existing(s)?.running == true { return .error(409, "Takes is still replying in this session. Stop it first.") }
            if let lib = app?.library { lib.trashSessions([Store.dir(s)]) } else {
                do { try FileManager.default.trashItem(at: s, resultingItemURL: nil) } catch {
                    return .error(500, "Could not move it to the Trash: \(error.localizedDescription)")
                }
            }
            return .encode(["ok": true])
        case "file":
            // Any other file the Files tab shows (an edit, a thumbnail, a still): Assets' "Move to Trash".
            guard let f = inLibrary(b["path"]), f.path.hasPrefix(s.path + "/"),
                  FileManager.default.fileExists(atPath: f.path), !f.hasDirectoryPath else { return .error(404, "No such file") }
            if Voice.take(for: f, in: s) != nil { return .error(400, "That is a take: trash the take") }
            guard ![ "session.json", "script.md", "SESSION.md"].contains(f.lastPathComponent) else { return .error(400, "That file stays") }
            if app?.preview == f { app?.preview = nil }
            do { try FileManager.default.trashItem(at: f, resultingItemURL: nil) } catch {
                return .error(500, "Could not move it to the Trash: \(error.localizedDescription)")
            }
            return .encode(["ok": true])
        default:
            return .error(400, "Trash what?")
        }
    }

    @MainActor private func trashProject(_ name: String?) -> PhoneResponse {
        guard let p = project(name) else { return .error(404, "No such project") }
        if let app = appModel {
            if app.isRecording, app.library.current?.url.deletingLastPathComponent().standardizedFileURL == p {
                return .error(409, "Takes is recording in this project.")
            }
            if app.chats.all.contains(where: { $0.running && $0.session?.deletingLastPathComponent().standardizedFileURL == p }) {
                return .error(409, "Takes is still replying in this project. Stop it first.")
            }
            app.library.trashProject(app.library.projects.first { $0.url.standardizedFileURL == p }?.url ?? p)
        } else {
            do { try FileManager.default.trashItem(at: p, resultingItemURL: nil) } catch {
                return .error(500, "Could not move it to the Trash: \(error.localizedDescription)")
            }
        }
        return .encode(["ok": true])
    }

    /// A project folder in the library by its name.
    func project(_ name: String?) -> URL? {
        guard let name, !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.hasPrefix("_") else { return nil }
        let u = libraryRoot.appending(path: name).standardizedFileURL
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue ? u : nil
    }

    // MARK: Rename and move

    @MainActor private func rename(_ b: [String: String], in s: URL) -> PhoneResponse {
        let name = (b["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch b["what"] {
        case "take":
            guard let n = b["take"].flatMap(Int.init) else { return .error(400, "Which take?") }
            guard let d = sessionDoc(s), d.meta.takes.contains(where: { $0.number == n }) else { return .error(404, "No such take") }
            if appModel?.isRecording == true { return .error(409, "Takes is recording. Rename it when the take is done.") }
            d.renameTake(n, to: name)
            return .encode(["ok": true])
        case "session":
            guard !name.isEmpty else { return .error(400, "A session needs a name") }
            if let e = busy(s) { return .error(409, e) }
            guard let d = sessionDoc(s) else { return .error(404, "No such session") }
            if let app = appModel, app.library.current === d {
                app.rename(d, to: name)
            } else {
                d.rename(to: name)
                appModel?.library.loadSessions()
            }
            return .encode(phoneSession(d.url.standardizedFileURL))
        default:
            return .error(400, "Rename what?")
        }
    }

    @MainActor private func renameProject(_ old: String?, to raw: String?) -> PhoneResponse {
        guard let p = project(old) else { return .error(404, "No such project") }
        let name = PhoneServer.projectName(raw)
        guard raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return .error(400, "A project needs a name") }
        if let app = appModel {
            if app.chats.all.contains(where: { $0.running && $0.session?.deletingLastPathComponent().standardizedFileURL == p }) {
                return .error(409, "Takes is still replying in this project. Rename it when it is done.")
            }
            let url = app.library.projects.first { $0.url.standardizedFileURL == p }?.url ?? p
            guard let moved = app.library.renameProject(url, to: name) else { return .error(409, "That name is taken") }
            return .encode(["project": moved.lastPathComponent])
        }
        let target = p.deletingLastPathComponent().appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else { return .error(409, "That name is taken") }
        do { try FileManager.default.moveItem(at: p, to: target) } catch { return .error(500, error.localizedDescription) }
        return .encode(["project": name])
    }

    @MainActor private func move(_ s: URL, to name: String?) -> PhoneResponse {
        guard let p = project(name) else { return .error(404, "No such project") }
        if let e = busy(s) { return .error(409, e) }
        let id = s.lastPathComponent
        guard s.deletingLastPathComponent().standardizedFileURL != p else { return .encode(phoneSession(s)) }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: p.path)) ?? [])
        if let lib = appModel?.library { lib.moveSessions([Store.dir(s)], to: Store.dir(p)) } else {
            var target = p.appending(path: id)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) { target = p.appending(path: "\(id)-\(n)"); n += 1 }
            try? FileManager.default.moveItem(at: s, to: target)
        }
        // Library adds -2 when the name is taken there: the new folder is the one that was not there.
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: p.path)) ?? [])
        guard let landed = after.subtracting(before).first else { return .error(500, "Could not move it") }
        return .encode(phoneSession(p.appending(path: landed).standardizedFileURL))
    }

    /// Why a session cannot change its folder now, or nil.
    @MainActor private func busy(_ s: URL) -> String? {
        if appModel?.isRecording == true, appModel?.library.current?.url.standardizedFileURL == s {
            return "Takes is recording in this session."
        }
        if appModel?.chats.existing(s)?.running == true { return "Takes is still replying in this session. Try again when it is done." }
        return nil
    }

    // MARK: Voice

    @MainActor static func voiceMix(_ s: URL, _ q: [String: String]) -> VoiceMix? {
        guard let n = q["take"].flatMap(Int.init), let meta = Store.readMeta(s) else { return nil }
        let kind = q["kind"].flatMap(TakeKind.init(rawValue:))
        guard let t = meta.takes.first(where: { $0.number == n && (kind == nil || $0.kind == kind) })
                ?? meta.takes.first(where: { $0.number == n }) else { return nil }
        let mix = VoiceMix(take: t, session: s)
        mix.reload()
        return mix
    }

    @MainActor static func voice(_ m: VoiceMix) -> PhoneVoice {
        let wav = Voice.dir(m.session).appending(path: m.key + ".wav")
        return PhoneVoice(state: m.state, on: m.on, strength: m.strength, quiet: m.quiet, summary: m.summary,
                          error: m.error, started: m.started, estimate: m.estimate,
                          file: FileManager.default.fileExists(atPath: wav.path) ? wav.path : nil)
    }

    // MARK: Script drafts

    static func version(_ v: ScriptVersion, name: String) -> PhoneVersion {
        PhoneVersion(path: v.url.path, created: v.created, author: v.author, note: v.note, draft: v.draft,
                     draftName: name, text: v.text())
    }

    /// The Script tab's draft bar, as on the Mac (DraftBar, HistorySheet, HookPicker). Nil when done.
    @MainActor static func scriptDraft(_ b: [String: String], in d: SessionDoc) -> String? {
        let slug = b["slug"] ?? ""
        let has = d.variants.contains { $0.slug == slug }
        switch b["action"] {
        case "new":
            // A copy of the draft on show, as the + does.
            let from = b["from"] ?? "main"
            let text = from == "main" ? d.script : (d.variants.first { $0.slug == from }?.text ?? d.script)
            d.newVariant(name: "Variant \(d.variants.count + 1)", text: text)
        case "save":
            guard has, let i = d.variants.firstIndex(where: { $0.slug == slug }), let text = b["text"] else { return "No such variant" }
            let v = d.variants[i]
            if let base = b["base"], v.text != base, v.text != text {
                return "It changed on the Mac while you edited. Pull to reload, then edit again."
            }
            guard v.text != text else { return nil }
            d.snapshot(draft: slug, note: "Before the phone edit")
            d.variants[i].text = text
            d.writeVariant(d.variants[i])
            d.snapshot(draft: slug, note: "Edited on the phone")
        case "promote":
            guard has else { return "No such variant" }
            d.promote(slug)
        case "delete":
            guard has else { return "No such variant" }
            d.deleteVariant(slug)
        case "rename":
            guard has else { return "No such variant" }
            guard let n = b["name"], !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "A variant needs a name" }
            d.renameVariant(slug, to: n)
        case "favorite":
            guard slug == "main" || has else { return "No such variant" }
            d.toggleFavorite(slug)
        case "restore":
            d.snapshotDirty()
            guard let v = d.versions().first(where: { $0.url.path == b["path"] }) else { return "No such version" }
            d.restore(v)
        case "hook":
            // The Script tab's hook picker: the hook opens the draft on show.
            let hooks = HookStore()
            hooks.load(d.url)
            guard let h = HookStore.read(d.url).hooks.first(where: { $0.id == b["hook"] }) else { return "No such hook" }
            let want = b["draft"] ?? "main"
            d.activeDraft = want == "main" || d.variants.contains(where: { $0.slug == want }) ? want : "main"
            hooks.choose(h, in: d)
            d.flushScript()
            if d.activeDraft != "main", let v = d.variants.first(where: { $0.slug == d.activeDraft }) { d.writeVariant(v) }
        default:
            return "Unknown action"
        }
        return nil
    }

    /// The post tab's draft bar and history, for any platform (PostStore, as the Mac's post tab).
    @MainActor static func postStoreDraft(_ b: [String: String], in s: URL, _ p: PostPlatform) -> String? {
        let store = PostStore(p)
        store.load(s)
        let slug = b["slug"] ?? ""
        let has = store.variants.contains { $0.slug == slug }
        switch b["action"] {
        case "promote":
            guard has else { return "No such variant" }
            store.promote(slug)
        case "new":
            guard store.content != nil else { return "No post yet" }
            if let from = b["from"], from != "main", store.variants.contains(where: { $0.slug == from }) { store.draft = from }
            store.newVariant()
        case "delete":
            guard has else { return "No such variant" }
            store.delete(slug)
        case "rename":
            guard has else { return "No such variant" }
            guard let n = b["name"], !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "A variant needs a name" }
            store.rename(slug, to: n)
        case "restore":
            store.close()
            guard let v = PostFile.versions(s, p).first(where: { $0.url.path == b["path"] }) else { return "No such version" }
            store.restore(v)
        case "hook":
            let hooks = HookStore(file: { PostFile.hooksURL($0, p) })
            hooks.load(s)
            guard let h = hooks.hooks.first(where: { $0.id == b["hook"] }) else { return "No such hook" }
            let draft = b["draft"] ?? "main"
            guard draft == "main" || store.variants.contains(where: { $0.slug == draft }) else { return "No such variant" }
            store.draft = draft
            store.use(h, known: hooks.hooks.map(\.text))
            hooks.markChosen(h, in: s)
        case "save":
            guard has, let text = b["text"] else { return "No such variant" }
            if let base = b["base"], store.text(of: slug) != base, store.text(of: slug) != text {
                return "It changed on the Mac while you edited. Pull to reload, then edit again."
            }
            guard store.text(of: slug) != text else { return nil }
            store.draft = slug
            store.edit(text)
            store.close()
        default:
            return "Unknown action"
        }
        store.close()
        return nil
    }
}
