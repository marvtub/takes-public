import AppKit
import AVFoundation
import Foundation

// On disk, everything is plain folders so Claude (or Finder) can read and write it:
//
//   <root>/<Project>/<yyyy-MM-dd-slug>/
//       script.md                 the script (the source of truth; Claude can drop one here)
//       session.json              title + list of takes
//       SESSION.md                human/Claude-readable summary, regenerated on every change
//       take-01-camera.mov        or take-01-<name>-camera.mov once the take is named
//       take-01-screen.mov
//       stills/ edits/ assets/    frames, edited videos, dropped files (see Assets.swift)
//
// The MCP server (mcp/takes_mcp.py) writes the same format. Keep the two in sync.

enum TakeKind: String, Codable { case camera, screen }

struct Take: Codable, Identifiable, Hashable {
    var number: Int
    var kind: TakeKind
    var file: String
    var startedAt: Date
    var duration: Double?
    var keeper: Bool = false
    var name: String?
    var script: String?  // variant read in this take; nil = main script
    var hook: String?    // the hook (from hooks.json) that opened the script in this take
    var shot: String?    // the storyboard shot (its id) this take films
    var id: String { file }
}

struct SessionMeta: Codable, Equatable {
    var title: String
    var createdAt: Date
    var named: Bool = false  // false until AI or a human gave it a real title
    var takes: [Take] = []
    var favorite: String?  // favorite script draft: "main" or a variant slug
    var order: [Int]?  // take numbers in the order the user dragged them; nil = newest first
    var published: [Post]?  // where the video is live (Publish.swift); nil = not published
    var music: SongPick?  // the song picked for the video (Sounds.swift)
    var sfx: [EffectCue]?  // sound effects placed on a video at a second (Sounds.swift)
    var style: String?  // the style this video uses (StyleLibrary.swift); nil = its project's
    var archived: Bool?  // out of the way: in the closed group at the bottom (phone swipe, sidebar menu)
}

struct Project: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct SessionSummary: Identifiable, Hashable {
    let url: URL
    let title: String
    let createdAt: Date
    let takeCount: Int
    var posts: [Post] = []  // where it is published; empty = not published
    var published: Bool { !posts.isEmpty }
    var archived = false
    /// Published or archived: in the closed group at the bottom of its project.
    var done: Bool { published || archived }
    var id: URL { url }
}

enum Store {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func readMeta(_ session: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: session.appending(path: "session.json")) else { return nil }
        return try? decoder.decode(SessionMeta.self, from: data)
    }

    /// One spelling per folder. Directory listings end in "/", appending(path:) does not, and URL ==
    /// treats the two as different, which dropped a new session from the selection.
    static func dir(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path(percentEncoded: false), directoryHint: .isDirectory)
    }

    // MARK: Manual order
    // Projects and sessions keep their dragged order in a hidden `.order.json` (folder names) inside
    // the parent folder. Folders missing from the file keep the default sort.

    static func readOrder(_ dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: dir.appending(path: ".order.json")) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func writeOrder(_ names: [String], in dir: URL) {
        try? JSONEncoder().encode(names).write(to: dir.appending(path: ".order.json"))
    }

    /// Saved order first; items not in it go before (`newFirst`) or after, in their default order.
    static func arrange<T>(_ items: [T], saved: [String], name: (T) -> String, newFirst: Bool) -> [T] {
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = items.filter { rank[name($0)] != nil }.sorted { rank[name($0)]! < rank[name($1)]! }
        let fresh = items.filter { rank[name($0)] == nil }
        return newFirst ? fresh + known : known + fresh
    }

    /// Moves `item` to the slot of `target`.
    static func move<T: Equatable>(_ list: inout [T], _ item: T, to target: T) {
        guard let i = list.firstIndex(of: item), let j = list.firstIndex(of: target), i != j else { return }
        list.move(fromOffsets: IndexSet(integer: i), toOffset: j > i ? j + 1 : j)
    }

    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// The session that is open in the detail pane.
@MainActor
@Observable
final class SessionDoc {
    private(set) var url: URL
    var meta: SessionMeta { didSet { onMeta?(meta) } }
    /// Called after each change of `meta` (the sound effects follow it).
    @ObservationIgnored var onMeta: ((SessionMeta) -> Void)?
    var script: String {
        didSet {
            if script != oldValue && !loadingFromDisk {
                lastEdit = Date(); dirtyDrafts.insert("main"); scheduleScriptSave()
            }
        }
    }
    var variants: [Variant] = []
    var activeDraft = "main"
    var historyCount = 0
    @ObservationIgnored var onScriptSettled: (() -> Void)?
    @ObservationIgnored var variantSaveTask: Task<Void, Never>?
    @ObservationIgnored var lastSnapshotAt: [String: Date] = [:]
    @ObservationIgnored var dirtyDrafts: Set<String> = []
    /// Text of the newest snapshot per draft, so a snapshot does not re-read all of history/.
    @ObservationIgnored var lastSnapshotText: [String: String] = [:]
    /// File names and dates in variants/ and history/ at the last read. Unchanged → skip the rescan.
    @ObservationIgnored var variantsStamp: [String: Date]?
    @ObservationIgnored var historyStamp: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var lastEdit = Date.distantPast
    @ObservationIgnored private var metaStamp: Date?
    @ObservationIgnored private var scriptStamp: Date?
    @ObservationIgnored private var loadingFromDisk = false

    init(url: URL) {
        let url = Store.dir(url)
        self.url = url
        if let m = Store.readMeta(url) {
            meta = m
        } else {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            meta = SessionMeta(title: Self.titleFromFolder(url.lastPathComponent), createdAt: created, named: true)
        }
        script = (try? String(contentsOf: url.appending(path: "script.md"), encoding: .utf8)) ?? ""
        metaStamp = Store.modified(url.appending(path: "session.json"))
        scriptStamp = Store.modified(url.appending(path: "script.md"))
        // Reads the variants once (it read them twice on every session switch).
        reloadVariantsFromDisk()
    }

    var projectName: String { url.deletingLastPathComponent().lastPathComponent }
    var nextTakeNumber: Int { (meta.takes.map(\.number).max() ?? 0) + 1 }

    var takeGroups: [(number: Int, takes: [Take])] {
        Dictionary(grouping: meta.takes, by: \.number)
            .map { ($0.key, $0.value.sorted { $0.kind.rawValue < $1.kind.rawValue }) }
            .sorted { $0.0 > $1.0 }
            .reorderedBy(meta.order)
    }

    /// Drag a take group to the slot of another.
    func moveTake(_ number: Int, to target: Int) {
        var numbers = takeGroups.map(\.number)
        Store.move(&numbers, number, to: target)
        meta.order = numbers
        save()
    }

    func fileURL(_ take: Take) -> URL { url.appending(path: take.file) }

    func save() {
        try? Store.encoder.encode(meta).write(to: url.appending(path: "session.json"))
        try? manifest().write(to: url.appending(path: "SESSION.md"), atomically: true, encoding: .utf8)
        metaStamp = Store.modified(url.appending(path: "session.json"))
    }

    func flushScript() {
        saveTask?.cancel()
        try? script.write(to: url.appending(path: "script.md"), atomically: true, encoding: .utf8)
        scriptStamp = Store.modified(url.appending(path: "script.md"))
    }

    /// Pick up edits made outside the app (Claude via MCP, or an editor). Returns false if the folder is gone.
    func reloadFromDiskIfChanged() -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let ms = Store.modified(url.appending(path: "session.json"))
        if ms != metaStamp, let m = Store.readMeta(url) {
            // The same content again (Claude's MCP writes it often) redraws nothing.
            if m != meta { meta = m }
            metaStamp = ms
        }
        let ss = Store.modified(url.appending(path: "script.md"))
        if ss != scriptStamp, Date().timeIntervalSince(lastEdit) > 5, saveTask == nil || saveTask!.isCancelled,
           let s = try? String(contentsOf: url.appending(path: "script.md"), encoding: .utf8) {
            loadingFromDisk = true
            script = s
            loadingFromDisk = false
            scriptStamp = ss
        }
        reloadVariantsFromDisk()
        return true
    }

    private func scheduleScriptSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.flushScript()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.saveTask = nil
            self.autoSnapshotIfDue("main")
            self.onScriptSettled?()
        }
    }

    func addTakes(_ takes: [Take]) {
        meta.takes.append(contentsOf: takes)
        save()
    }

    /// A take just recorded for a storyboard shot: named after the shot ("Hook 1: I do my
    /// bookkeeping", file take-03-hook-1-i-do-my-bookkeeping-camera.mov), then Gemini finds its
    /// best cut. Nothing to organise by hand.
    func fileShotTake(_ number: Int) {
        guard let id = meta.takes.first(where: { $0.number == number })?.shot,
              let name = Storyboard.read(url)?.takeName(for: id) else { return }
        renameTake(number, to: name)
        TakeCut.start(url, take: number)
    }

    /// Files take `number` under a storyboard shot, or under none.
    func link(take number: Int, to shot: String?) {
        for i in meta.takes.indices where meta.takes[i].number == number { meta.takes[i].shot = shot }
        save()
    }

    func toggleKeeper(_ number: Int) {
        let on = !(meta.takes.first { $0.number == number }?.keeper ?? false)
        for i in meta.takes.indices where meta.takes[i].number == number { meta.takes[i].keeper = on }
        save()
    }

    func trashTake(_ number: Int) {
        for t in meta.takes where t.number == number {
            try? FileManager.default.trashItem(at: fileURL(t), resultingItemURL: nil)
        }
        meta.takes.removeAll { $0.number == number }
        save()
    }

    /// Names a take and renames its files to take-NN-<slug>-<kind>.mov. Empty name resets it.
    func renameTake(_ number: Int, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Library.slug(clean)
        for i in meta.takes.indices where meta.takes[i].number == number {
            let t = meta.takes[i]
            let ext = URL(fileURLWithPath: t.file).pathExtension
            let newFile = Self.takeFile(number: number, slug: slug, kind: t.kind, ext: ext.isEmpty ? "mov" : ext.lowercased())
            if newFile != t.file,
               (try? FileManager.default.moveItem(at: fileURL(t), to: url.appending(path: newFile))) != nil {
                meta.takes[i].file = newFile
            }
            meta.takes[i].name = clean.isEmpty ? nil : clean
        }
        save()
    }

    /// Keeps the name while you type. The files get it later, from `renameTake`.
    func nameTake(_ number: Int, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        for i in meta.takes.indices where meta.takes[i].number == number && (meta.takes[i].name ?? "") != clean {
            meta.takes[i].name = clean.isEmpty ? nil : clean
            changed = true
        }
        if changed { save() }
    }

    static func takeFile(number: Int, slug: String, kind: TakeKind, ext: String = "mov") -> String {
        let nn = String(format: "%02d", number)
        return slug.isEmpty ? "take-\(nn)-\(kind.rawValue).\(ext)" : "take-\(nn)-\(slug)-\(kind.rawValue).\(ext)"
    }

    /// Renames the folder to `<date>-<slug>`. Never call while recording.
    func rename(to title: String, named: Bool = true) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        flushScript()
        meta.title = clean
        meta.named = named
        let date = Self.dayFormatter.string(from: meta.createdAt)
        let parent = url.deletingLastPathComponent()
        var target = Store.dir(parent.appending(path: "\(date)-\(Library.slug(clean))"))
        var n = 2
        while target != url && FileManager.default.fileExists(atPath: target.path) {
            target = Store.dir(parent.appending(path: "\(date)-\(Library.slug(clean))-\(n)")); n += 1
        }
        if target != url, (try? FileManager.default.moveItem(at: url, to: target)) != nil {
            let old = url.lastPathComponent
            let order = Store.readOrder(parent)
            if order.contains(old) {
                Store.writeOrder(order.map { $0 == old ? target.lastPathComponent : $0 }, in: parent)
            }
            url = target
        }
        save()
    }

    private func manifest() -> String {
        var s = "# \(meta.title)\n\n"
        s += "Project: \(projectName)  \nCreated: \(Self.dayFormatter.string(from: meta.createdAt))  \n"
        s += "Folder: `\(url.path)`\n"
        if let posts = meta.published, !posts.isEmpty {
            s += "Published: " + posts.map { p in
                "\(p.label) (\(Self.dayFormatter.string(from: p.at)))" + (p.url.map { " \($0)" } ?? "")
            }.joined(separator: ", ") + "\n"
        }
        if let m = meta.music {
            s += "Music: `_library/audio/\(m.file)` from \(Self.clock(m.start)) at \(Int((m.volume * 100).rounded()))%\n"
        }
        s += "\n"
        s += "## Takes\n\n"
        if meta.takes.isEmpty {
            s += "_No takes yet._\n"
        } else {
            s += "Camera files carry the mic audio. Screen files carry the mic too, for syncing by waveform. "
            s += "`screen offset` is how many seconds after the camera file the screen file starts.\n\n"
            s += "| Take | Name | Keeper | Camera | Screen | Length | Screen offset |\n|---|---|---|---|---|---|---|\n"
            for g in takeGroups.reversed() {
                let cam = g.takes.first { $0.kind == .camera }
                let scr = g.takes.first { $0.kind == .screen }
                let len = (cam ?? scr)?.duration.map(Self.clock) ?? "?"
                var offset = "–"
                if let c = cam, let sc = scr {
                    offset = String(format: "%+.2fs", sc.startedAt.timeIntervalSince(c.startedAt))
                }
                let name = g.takes.first?.name ?? ""
                s += "| \(g.number) | \(name) | \(g.takes.first?.keeper == true ? "★" : "") | \(cam.map { "`\($0.file)`" } ?? "–") | \(scr.map { "`\($0.file)`" } ?? "–") | \(len) | \(offset) |\n"
            }
        }
        s += "\n## Script\n\nSee `script.md`.\n"
        return s
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func titleFromFolder(_ name: String) -> String {
        var n = name
        if n.count > 11, dayFormatter.date(from: String(n.prefix(10))) != nil { n = String(n.dropFirst(11)) }
        return n.replacingOccurrences(of: "-", with: " ")
    }
}

@MainActor
@Observable
final class Library {
    private(set) var root: URL { didSet { onRoot?(root) } }
    /// Called when the library moves to another folder (the file watch follows it).
    @ObservationIgnored var onRoot: ((URL) -> Void)?
    var projects: [Project] = []
    /// The sessions of the selected project: the one the open session is in.
    var sessions: [SessionSummary] = []
    /// The sessions of every project, for the sidebar's sections (2026-10-02).
    var grouped: [URL: [SessionSummary]] = [:]
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            UserDefaults.standard.set(selectedProject?.lastPathComponent, forKey: "project")
            loadSessions()
            if !keepSelection { selectedSessions = sessions.first.map { [$0.url] } ?? [] }
        }
    }
    /// Set while `select(_:)` changes the project: the session it picks opens, not the first one.
    @ObservationIgnored private var keepSelection = false
    /// One selected → it opens in the detail pane. Several → the detail pane shows bulk actions.
    var selectedSessions: Set<URL> = [] {
        didSet {
            let clean = Set(selectedSessions.map(Store.dir))
            if clean != selectedSessions { selectedSessions = clean; return }
            if selectedSessions != oldValue { Perf.mark("session"); openSelected() }
        }
    }
    private(set) var current: SessionDoc?
    @ObservationIgnored var onOpen: ((SessionDoc) -> Void)?
    @ObservationIgnored var isRecording = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "root")
        root = saved.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        if let last = UserDefaults.standard.string(forKey: "project"),
           let p = projects.first(where: { $0.name == last }) {
            selectedProject = p.url
        } else {
            selectedProject = projects.first?.url
        }
    }

    func setRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "root")
        root = url
        selectedProject = nil
        reload()
        selectedProject = projects.first?.url
    }

    /// Rescan disk. Claude may have added projects, sessions, or scripts via the MCP server.
    /// True if a change in `paths` (folders, from FSEvents) can change the projects, the sessions
    /// or the open session's script, variants and meta. Not: `_library`, hidden folders, or the
    /// asset folders inside a session (edits, stills, storyboard, …).
    nonisolated static func matters(_ paths: [String], root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let base = r.hasSuffix("/") ? r : r + "/"
        return paths.isEmpty || paths.contains { p in
            let q = URL(fileURLWithPath: p).standardizedFileURL.path
            guard q.hasPrefix(base) else { return q == r }
            let parts = q.dropFirst(base.count).split(separator: "/")
            guard let first = parts.first else { return true }
            if first.hasPrefix("_") || first.hasPrefix(".") { return false }
            if parts.count <= 2 { return true }  // the root, a project, a session folder
            return parts[2] == "variants" || parts[2] == "history"
        }
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let fresh = dirs.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Project.init)
        let arranged = Store.arrange(fresh, saved: Store.readOrder(root), name: \.name, newFirst: false)
        if arranged != projects { projects = arranged }
        if let p = selectedProject, !projects.contains(where: { $0.url == p }) {
            selectedProject = projects.first?.url
        }
        loadSessions()
        let live = Set(sessions.map(\.url))
        if !selectedSessions.isSubset(of: live) { selectedSessions = selectedSessions.intersection(live) }
        if let doc = current, !isRecording, !doc.reloadFromDiskIfChanged() {
            // Gone: most often Claude renamed it (update_session moves the folder). Stay on it.
            let renamed = sessions.first { $0.createdAt == doc.meta.createdAt && $0.title == doc.meta.title }
                ?? sessions.first { $0.createdAt == doc.meta.createdAt }
            selectedSessions = (renamed ?? sessions.first).map { [$0.url] } ?? []
        }
    }

    @ObservationIgnored private var summaries: [URL: (stamp: Date, summary: SessionSummary)] = [:]

    func loadSessions() {
        var all: [URL: [SessionSummary]] = [:]
        for p in projects { all[p.url] = list(p.url) }
        if all != grouped { grouped = all }
        let mine = selectedProject.flatMap { all[$0] } ?? []
        if mine != sessions { sessions = mine }
    }

    /// One project's sessions, newest first, in the user's dragged order; published ones last.
    private func list(_ p: URL) -> [SessionSummary] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: p, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let fresh = dirs.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") }.map(Store.dir).map { url in
            // Each reload read and decoded every session.json of the project. Read only the ones
            // whose date changed since the last time (2026-10-01).
            let stamp = Store.modified(url.appending(path: "session.json"))
            if let stamp, let hit = summaries[url], hit.stamp == stamp { return hit.summary }
            if let m = Store.readMeta(url) {
                let s = SessionSummary(url: url, title: m.title, createdAt: m.createdAt,
                                       takeCount: Set(m.takes.map(\.number)).count,
                                       posts: m.published ?? [], archived: m.archived == true)
                if let stamp { summaries[url] = (stamp, s) }
                return s
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return SessionSummary(url: url, title: SessionDoc.titleFromFolder(url.lastPathComponent),
                                  createdAt: created, takeCount: 0)
        }
        .sorted { $0.createdAt > $1.createdAt }
        // Published and archived sessions go below the others, in their own group of the sidebar.
        let saved = Store.arrange(fresh, saved: Store.readOrder(p), name: \.url.lastPathComponent, newFirst: true)
        return saved.filter { !$0.done } + saved.filter(\.done)
    }

    /// The project folder a session is in, as `projects` holds it.
    func project(of session: URL) -> URL? {
        let dir = session.deletingLastPathComponent().standardizedFileURL.path
        return projects.first { $0.url.standardizedFileURL.path == dir }?.url
    }

    /// Opens a session of any project: its project becomes the selected one.
    func select(_ session: URL) {
        if let p = project(of: session), p != selectedProject {
            keepSelection = true
            selectedProject = p
            keepSelection = false
        }
        selectedSessions = [Store.dir(session)]
    }

    func moveProject(_ url: URL, to target: URL) {
        guard let a = projects.first(where: { $0.url == url }),
              let b = projects.first(where: { $0.url == target }) else { return }
        Store.move(&projects, a, to: b)
        Store.writeOrder(projects.map(\.name), in: root)
    }

    func moveSession(_ url: URL, to target: URL) {
        guard let p = selectedProject,
              let a = sessions.first(where: { $0.url == url }),
              let b = sessions.first(where: { $0.url == target }) else { return }
        Store.move(&sessions, a, to: b)
        Store.writeOrder(sessions.map(\.url.lastPathComponent), in: p)
    }

    private func openSelected() {
        guard selectedSessions.count == 1, let url = selectedSessions.first else {
            current?.close()
            current = nil
            return
        }
        if current?.url == url { return }
        current?.close()
        let doc = SessionDoc(url: url)
        current = doc
        onOpen?(doc)
    }

    @discardableResult
    func createProject(_ name: String) -> URL? {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let url = root.appending(path: clean)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        reload()
        // The list's own URL (a folder URL, with the slash): `url` never equals it, so the new
        // project showed no sessions until the next rescan (2026-10-06, a new user's first video).
        let made = projects.first { $0.name == clean }?.url ?? url
        selectedProject = made
        return made
    }

    /// New session in the selected project, or in `project` (creates an "Inbox" project if there
    /// is none). No dialog.
    @discardableResult
    func createSession(in project: URL? = nil) -> SessionDoc? {
        if let project, project != selectedProject {
            keepSelection = true
            selectedProject = project
            keepSelection = false
        }
        if selectedProject == nil { createProject("Inbox") }
        guard let p = selectedProject else { return nil }
        let now = Date()
        let date = SessionDoc.dayFormatter.string(from: now)
        var url = p.appending(path: "\(date)-untitled")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = p.appending(path: "\(date)-untitled-\(n)"); n += 1
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let doc = SessionDoc(url: url)
        doc.meta = SessionMeta(title: "Untitled", createdAt: now, named: false)
        doc.save()
        loadSessions()
        current?.close()
        current = doc
        selectedSessions = [url]
        onOpen?(doc)
        return doc
    }

    /// Call after `current` renamed its folder, so the list and selection follow.
    func currentDidRename() {
        loadSessions()
        if let doc = current { selectedSessions = [doc.url] }
    }

    // MARK: Bulk actions

    func trashSessions(_ urls: Set<URL>) {
        if let c = current, urls.contains(c.url) { current = nil }
        for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        loadSessions()
        selectedSessions = sessions.first.map { [$0.url] } ?? []
    }

    func setArchived(_ urls: Set<URL>, _ on: Bool) {
        for u in urls {
            let doc = current?.url == u ? current! : SessionDoc(url: u)
            doc.meta.archived = on ? true : nil
            doc.save()
        }
        loadSessions()
    }

    func moveSessions(_ urls: Set<URL>, to project: URL) {
        if let c = current, urls.contains(c.url) { c.close(); current = nil }
        for u in urls where u.deletingLastPathComponent() != project {
            var target = project.appending(path: u.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = project.appending(path: "\(u.lastPathComponent)-\(n)"); n += 1
            }
            try? FileManager.default.moveItem(at: u, to: target)
        }
        loadSessions()
        selectedSessions = []
    }

    /// Moves every take that is not starred to the Trash, in each session.
    @discardableResult
    func trashNonKeepers(_ urls: Set<URL>) -> Int {
        var count = 0
        for u in urls {
            let doc = current?.url == u ? current! : SessionDoc(url: u)
            let losers = Set(doc.meta.takes.filter { !$0.keeper }.map(\.number))
            for n in losers { doc.trashTake(n) }
            count += losers.count
        }
        loadSessions()
        return count
    }

    /// Renames a project folder. Nil when the name is empty or taken.
    @discardableResult
    func renameProject(_ url: URL, to name: String) -> URL? {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("."), !clean.hasPrefix("_"), !isRecording else { return nil }
        guard clean != url.lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appending(path: clean)
        // Only a change of case may point at the same folder.
        guard !FileManager.default.fileExists(atPath: target.path)
                || clean.lowercased() == url.lastPathComponent.lowercased() else { return nil }
        let open = current.flatMap { c in c.url.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL
            ? c.url.lastPathComponent : nil }
        if open != nil { current?.close(); current = nil }
        do { try FileManager.default.moveItem(at: url, to: target) } catch { return nil }
        let order = Store.readOrder(root)
        if !order.isEmpty { Store.writeOrder(order.map { $0 == url.lastPathComponent ? clean : $0 }, in: root) }
        let wasSelected = selectedProject == url
        // The old folder is gone: reload must not open the first session of another project.
        keepSelection = wasSelected
        reload()
        keepSelection = false
        let moved = projects.first { $0.name == clean }?.url ?? target
        if let open { select(moved.appending(path: open)) } else if wasSelected { selectedProject = moved }
        return moved
    }

    func trashProject(_ url: URL) {
        if let c = current, c.url.deletingLastPathComponent() == url { current = nil }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
        if selectedProject == url { selectedProject = projects.first?.url }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func reveal(_ urls: Set<URL>) { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }

    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        return String(parts.joined(separator: "-").prefix(60))
    }
}

extension Array where Element == (number: Int, takes: [Take]) {
    /// Numbers in `order` keep that order. New numbers (not in it) go first, newest first.
    func reorderedBy(_ order: [Int]?) -> Self {
        guard let order else { return self }
        return Store.arrange(self, saved: order.map(String.init), name: { String($0.number) }, newFirst: true)
    }
}
