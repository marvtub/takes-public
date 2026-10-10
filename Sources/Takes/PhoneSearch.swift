import Foundation

// ⌘K on the phone (2026-10-09): the Mac's own MediaSearch, by name and by meaning, with its chips
// and its cut of the hits that stand out. Only the boards the phone has come back. The phone side
// is ios/TakesPhone/SearchView.swift. Public.

/// One hit, as the phone shows it: a named row (session, project, board) or a file at a second.
struct PhoneHit: Codable, Hashable {
    var kind: String
    var path: String
    var start: Double
    var text: String?
    var title: String?
    /// The session the file is in, or the session itself ("<project>/<session>").
    var session: String?
    /// A board the phone has: styles, performance, comments.
    var board: String?
}

struct PhoneSearch: Codable, Hashable {
    var hits: [PhoneHit]
    /// The Mac's search line: the model's state, or how far the index got.
    var status: String
}

extension PhoneServer {
    func search(_ req: PhoneRequest) async -> PhoneResponse {
        let q = (req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = req.query["filter"].flatMap(MediaSearch.Filter.init(rawValue:)) ?? .all
        let folder = req.query["project"].flatMap { self.project($0) }
        let root = libraryRoot.standardizedFileURL
        let (places, status) = await placesAndStatus(q, filter: filter, project: folder, root: root)
        guard !q.isEmpty else { return .encode(PhoneSearch(hits: [], status: status)) }
        var found: [MediaSearch.Hit] = appModel == nil ? [] : await MediaSearch.shared.search(q, limit: 400)
        if found.isEmpty { found = await MediaSearch.byName(q, root: root, limit: 400) }
        let kept = found.filter { MediaSearch.keeps($0, filter, project: folder) }
        let hits = (places + MediaSearch.relevant(kept).prefix(40)).compactMap { phoneHit($0, root: root) }
        return .encode(PhoneSearch(hits: hits, status: status))
    }

    @MainActor private func placesAndStatus(_ q: String, filter: MediaSearch.Filter, project: URL?, root: URL) -> ([MediaSearch.Hit], String) {
        let status = MediaSearch.shared.statusLine
        guard filter == .all, !q.isEmpty else { return ([], status) }
        let limit = project == nil ? 6 : 40
        let p: [MediaSearch.Hit]
        if let app = appModel { p = MediaSearch.places(q, app: app, limit: limit) } else { p = Self.places(q, root: root, limit: limit) }
        return (p.filter { MediaSearch.keeps($0, filter, project: project) }, status)
    }

    private func phoneHit(_ h: MediaSearch.Hit, root: URL) -> PhoneHit? {
        var board: String?
        if let b = h.board {
            switch b {
            case .styles: board = "styles"
            case .performance: board = "performance"
            case .comments: board = "comments"
            default: return nil  // Plugins and plugin boards stay on the Mac
            }
        }
        let path = h.path.standardizedFileURL.path
        var session: String?
        if path.hasPrefix(root.path + "/") {
            let parts = path.dropFirst(root.path.count + 1).split(separator: "/")
            if parts.count >= 2, !parts[0].hasPrefix("_") { session = parts[0] + "/" + parts[1] }
        }
        return PhoneHit(kind: h.kind, path: path, start: h.start, text: h.text, title: h.title, session: session, board: board)
    }

    /// MediaSearch.places without the app (a test server): projects and sessions on disk.
    nonisolated static func places(_ q: String, root: URL, limit: Int) -> [MediaSearch.Hit] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        let fm = FileManager.default
        var rows: [(MediaSearch.Hit, String)] = []
        for p in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        where p.hasDirectoryPath && !p.lastPathComponent.hasPrefix("_") {
            rows.append((MediaSearch.Hit(path: p, kind: "project", start: 0, title: p.lastPathComponent), p.lastPathComponent))
            for s in ((try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []) {
                guard let meta = Store.readMeta(s) else { continue }
                rows.append((MediaSearch.Hit(path: s, kind: "session", start: 0, text: p.lastPathComponent, title: meta.title), meta.title))
            }
        }
        return rows.filter { _, n in words.allSatisfy(n.lowercased().contains) }.prefix(limit).map(\.0)
    }
}
