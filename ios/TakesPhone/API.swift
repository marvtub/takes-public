import Foundation

// The Takes app on the Mac (Sources/Takes/Phone.swift) answers over Tailscale:
// https://<mac>.<tailnet>.ts.net:8444. These types mirror its JSON.

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var project: String
    var created: Date
    var updated: Date
    var takes: Int
    var running: Bool
    var unread: Bool
    var notice: Bool
    var published: Bool
    /// Swiped away: in the closed Archived group. nil from an older Mac.
    var archived: Bool?
    /// A picture or video on the Mac for the row's thumbnail.
    var preview: String?
    /// How far it got (idea, script, board, recorded, edit, posted) and its storyboard shots. nil from an older Mac.
    var stage: String? = nil
    var shots: Int? = nil
}

struct RemoteFile: Codable, Identifiable, Hashable {
    var path: String
    var name: String
    var folder: String
    var kind: String
    var size: Int64
    var modified: Date
    var take: Int?
    var keeper: Bool?
    var duration: Double?
    /// A take filed under a storyboard shot (its id).
    var shot: String?
    /// The AI model that made it (generated/). nil from an older Mac.
    var model: String? = nil
    var id: String { path }
    var isVideo: Bool { kind == "video" }
    var isImage: Bool { kind == "image" }
    var isAudio: Bool { kind == "audio" }
    /// Only a thumbnail can be a cover.
    var canBeCover: Bool { isImage && folder == "thumbnails" }

    /// The path inside the session ("edits/hook-v2.mp4"), as comments.json names it. The Mac sends
    /// the full path on its disk, and the session id is "<project>/<session>". nil when it is not
    /// in that session.
    func rel(in sessionID: String) -> String? {
        let mark = "/" + sessionID + "/"
        guard let r = path.range(of: mark, options: .backwards) else {
            return path.hasPrefix(sessionID + "/") ? String(path.dropFirst(sessionID.count + 1)) : nil
        }
        return String(path[r.upperBound...])
    }
}

struct Message: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, claude, tool, error }
    var id: UUID
    var role: Role
    var text: String
    var toolID: String?
    var done: Bool
}

struct ContextUse: Codable, Hashable {
    var used: Int
    var window: Int
}

struct Chat: Codable, Hashable {
    var running: Bool
    var messages: [Message]
    var context: ContextUse?

    /// Claude runs a /compact: the chat says so instead of "Claude is working" (2026-10-03).
    var compacting: Bool {
        guard running, let last = messages.last(where: { $0.role == .user }) else { return false }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("/compact")
    }
    var workingLine: String { compacting ? "Compacting the conversation" : "Takes is working" }
}

struct Post: Codable, Hashable {
    var text: String
    var media: String?
    var cover: String?
    var status: String
    var firstComment: String?
    /// Other versions of the post. Nil from a Mac before 2026-10-02.
    var variants: [PostVariant]?
    /// Claude's opening options for the post.
    var hooks: [PostHook]?
}

/// One platform's post: LinkedIn, X, YouTube or Vertical. Nil list from a Mac before 2026-10-05.
struct PlatformPost: Codable, Hashable, Identifiable {
    var platform: String
    var name: String
    var text: String
    var title: String
    var media: String?
    var cover: String?
    var status: String
    var url: String?
    var limit: Int
    var id: String { platform }
}

/// A post on a side a Mac plugin adds. Nil list from a Mac
/// before 2026-10-07, and from the public Mac.
struct SidePost: Codable, Hashable, Identifiable {
    var side: String
    var name: String
    var file: String
    var title: String
    var text: String
    var link: String
    var place: String
    var flair: String
    var user: String
    var media: String
    var status: String
    var postedURL: String
    var submit: String?
    var titleLimit: Int
    var textLimit: Int?
    var id: String { file }
    var posted: Bool { status == "posted" }
}

struct PostVariant: Codable, Hashable, Identifiable {
    var slug: String
    var name: String
    var author: String
    var note: String
    var text: String
    var id: String { slug }
}

struct PostHook: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var note: String?

    /// The first paragraph of the text, where the hook goes.
    static func opening(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = t.range(of: "\n\n")?.lowerBound ?? t.endIndex
        return String(t[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The author the LinkedIn preview shows: set on the Mac (click your name on its post tab).
struct Profile: Codable, Hashable {
    var name: String
    var headline: String
    var photo: Bool
}

struct SessionDetail: Codable, Hashable {
    var session: Session
    var folder: String
    var script: String
    var files: [RemoteFile]
    var post: Post?
    var chat: Chat
    var openComments: Int
    var profile: Profile?
    /// Nil from a Mac before 2026-10-03, or when the session has no storyboard.
    var storyboard: [Shot]?
    /// Every platform with a post, LinkedIn first. Nil from a Mac before 2026-10-05.
    var posts: [PlatformPost]?
    var sides: [SidePost]?
    /// The style this video is edited in. Nil from a Mac before 2026-10-08.
    var style: SessionStyle?
}

// MARK: Styles (the Mac's Styles board)

/// The style one video uses, and the styles it can pick.
struct SessionStyle: Codable, Hashable {
    var own: String?
    var project: String?
    var names: [String]
}

struct StyleCard: Codable, Hashable, Identifiable {
    var name: String
    var description: String
    var source: String?
    var isNew: Bool
    var video: String?
    var poster: String?
    var usedBy: [String]
    var openComments: Int
    var id: String { name }
}

struct StyleList: Codable, Hashable {
    var styles: [StyleCard]
    var projects: [String]
}

struct StyleSwatch: Codable, Hashable {
    var name: String
    var value: String
    var usage: String
}

struct StyleType: Codable, Hashable {
    var name: String
    var family: String
    var size: Double
    var weight: Int
}

struct StyleVersion: Codable, Hashable {
    var path: String
    var name: String
    var version: Int?
    var kind: String
    var size: Int64
    var modified: Date
    var note: String?
    var from: String?
    var openComments: Int
}

struct StyleItem: Codable, Hashable, Identifiable {
    var name: String
    var versions: [StyleVersion]
    var id: String { name }
}

struct StyleGroup: Codable, Hashable, Identifiable {
    var name: String
    var items: [StyleItem]
    var id: String { name }
}

struct StyleDetail: Codable, Hashable {
    /// The library folder inside the Takes folder: comments use it as their session id.
    var id: String
    var name: String
    var folder: String
    var readme: String?
    var readmeComments: Int
    var hasTokens: Bool
    var tokensComments: Int
    var swatches: [StyleSwatch]
    var type: [StyleType]
    var fonts: [String]
    var groups: [StyleGroup]
    var openComments: Int
}

/// One storyboard shot: the sketch, the lines it covers, how to film it, the user's comments.
struct Shot: Codable, Identifiable, Hashable {
    var id: String
    var section: String     // hook, main, end
    var kind: String
    var say: String
    var how: String
    var seconds: Double
    var start: Double
    var image: String?
    var error: String?
    var comments: [Comment]
    /// Width over height: the storyboard's format, or the clip's own shape. Nil from an older Mac: the board reads it off the picture.
    var ratio: Double?

    var shape: CGFloat { CGFloat(ratio.flatMap { $0 > 0 ? $0 : nil } ?? 0.8) }

    static func isClip(_ path: String) -> Bool { ["mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased()) }

    /// The fold's title, as on the Mac: a motion graphic is made, not filmed.
    var howTitle: String {
        switch kind.uppercased() {
        case "MG": return "What it shows"
        case "SCREEN": return "What to record"
        default: return "How to film it"
        }
    }
}

struct Comment: Codable, Identifiable, Hashable {
    struct Reply: Codable, Hashable { var by: String; var text: String; var at: String }
    var id: String
    var file: String
    var quote: String?
    var text: String
    var status: String
    var by: String
    var at: String
    var replies: [Reply]?
    var shot: String?
    /// On a video: seconds (end missing for one moment). rect: x, y, w, h as fractions of the frame.
    var start: Double?
    var end: Double?
    var rect: [Double]?
    var open: Bool { status != "resolved" }
    var area: CGRect? {
        guard let r = rect, r.count == 4 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
    /// "0:03.2–0:06.0 · area", as the Mac shows it. nil for a comment on text.
    var place: String? {
        guard start != nil || rect != nil else { return nil }
        var parts: [String] = []
        if let start { parts.append(Comment.label(start, end)) }
        parts.append(rect == nil ? "whole frame" : "area")
        return parts.joined(separator: " · ")
    }

    static func label(_ start: Double, _ end: Double?) -> String {
        guard let end, end - start >= 0.1 else { return stamp(start) }
        return "\(stamp(start))–\(stamp(end))"
    }

    static func stamp(_ s: Double) -> String {
        String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// The performance tab: the Signal dashboard numbers and each published post's latest numbers.
struct Performance: Decodable {
    struct Social: Decodable {
        struct Hero: Decodable {
            var followers: Int; var followers_gain_8d: Int; var impr_per_day: Int
            var month: String; var prev_month: String; var mom_pct: Int
            var impr_spark: [Int]; var rate: Double; var engagements: Int; var total_impressions: Int
            /// false while the month is still running ("Oct so far").
            var month_complete: Bool?
            /// The last 14 days, for the small lines on the tiles.
            var followers_spark: [Int]?
            var new_followers_spark: [Int]?
            var peak_month: String?
            var peak_impressions: Int?
        }
        struct Momentum: Decodable { var dates: [String]; var linkedin: [Int]; var x: [Int?] }
        struct Cadence: Decodable { var posts: Int; var target: Int; var week: Int }
        struct Entry: Decodable, Identifiable {
            var title: String; var url: String; var date: String; var reach: Int; var engagements: Int; var rate: Double
            /// For the feed card: the post text, its counts, and a picture saved on the Mac (a path for /thumb).
            var text: String?; var likes: Int?; var comments: Int?; var reposts: Int?
            var media_type: String?; var poster: String?
            var id: String { url + date + title }
        }
        var generated: String
        var hero: Hero
        var momentum: Momentum?
        var cadence: Cadence?
        var recent: [Entry]?
        var top_linkedin: [Entry]?
        /// The top posts of the last 30, 60 and 90 days, keyed "30", "60", "90". Older exports lack it.
        var top_linkedin_windows: [String: [Entry]]?
        /// The last 13 weeks day by day: impressions and posts, for the activity grid. A day not
        /// measured yet is null.
        struct Heat: Decodable { var dates: [String]; var impressions: [Int?]; var li_posts: [Int?]; var x_posts: [Int?] }
        struct Point: Decodable { var date: String; var value: Int? }
        struct MonthValue: Decodable { var month: String; var value: Int }
        struct Audience: Decodable { struct Item: Decodable { var label: String; var pct: Double }; var title: String; var items: [Item] }
        /// The last day each source covers (YYYY-MM-DD).
        struct Sources: Decodable { var linkedin: String?; var followers: String?; var x: String?; var refreshed: String? }
        var heat: Heat?
        var followers: [Point]?
        var monthly_linkedin: [MonthValue]?
        var monthly_x: [MonthValue]?
        var audience: [Audience]?
        var sources: Sources?
    }
    struct Item: Decodable, Identifiable {
        var session: String; var title: String; var project: String
        var platform: String?; var url: String?; var at: Date
        var reach: Int?; var likes: Int?; var comments: Int?; var reposts: Int?; var measured: Date?
        var id: String { session + (platform ?? "") }
    }
    var posts: [Item]
    var social: Social?
    var profile: Profile?
}

/// A LinkedIn comment the copilot drafted (the Mac's _library/comments/suggestions/<id>.json).
struct Suggestion: Decodable, Identifiable, Hashable {
    struct Post: Decodable, Hashable {
        var url: String?; var author: String?; var headline: String?; var text: String?
        var posted: String?; var comments: Int?; var reactions: Int?; var photo: String?
    }
    struct Draft: Decodable, Hashable {
        var text: String; var variants: [String]?; var feedback: String?
    }
    struct Decision: Decodable, Hashable { var kind: String; var reason: String?; var note: String?; var variant: Int? }
    struct Stat: Decodable, Hashable { var at: Date; var impressions: Int?; var likes: Int?; var replies: Int? }
    struct Posted: Decodable, Hashable { var url: String?; var at: Date? }

    var id: String
    var created: Date
    /// review, redraft, approved, posted, declined
    var status: String
    var post: Post
    var angle: String?
    var drafts: [Draft]
    var final: String?
    var decision: Decision?
    var skipped: Date?
    var posted: Posted?
    var stats: [Stat]?
    var best: Bool?

    var text: String { final ?? drafts.last?.text ?? "" }
    /// The newest draft's variants, or the draft alone.
    var options: [String] { drafts.last.map { $0.variants ?? [$0.text] } ?? [] }
    var latest: Stat? { stats?.last }
}

/// The Comments tab: every suggestion, and which of the Mac's runs work now.
struct Copilot: Decodable {
    var items: [Suggestion]
    var finding: Bool
    var posting: Bool
    var redrafting: Bool
    var profile: Profile?

    var review: [Suggestion] { items.filter { $0.status == "review" && $0.skipped == nil } }
    /// A note on the Mac that waits to be sent counts too: a new draft comes back for it.
    var redraft: [Suggestion] { items.filter { $0.status == "redraft" || $0.status == "feedback" } }
    var approved: [Suggestion] { items.filter { $0.status == "approved" } }
    var posted: [Suggestion] { items.filter { $0.status == "posted" }.sorted { ($0.posted?.at ?? $0.created) > ($1.posted?.at ?? $1.created) } }
    var skipped: [Suggestion] { items.filter { $0.status == "review" && $0.skipped != nil }.sorted { $0.skipped! > $1.skipped! } }
}

/// One line of the Mac's event stream.
struct LiveEvent: Decodable {
    var type: String
    var id: String?
    var running: Bool?
    var unread: Bool?
    var count: Int?
    var tail: [Message]?
    var paths: [String]?
    /// How full Claude's context is now. From a Mac before 2026-10-03: nil.
    var context: ContextUse?
}

/// What GET /api/update says: empty when nothing waits.
struct AppUpdate: Decodable, Equatable {
    var stamp: String?
    var changes: [String]?
    var installing: Bool?
    var error: String?
    /// Why the Mac cannot renew this app's 7-day profile. nil from an older Mac.
    var renew: String?
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Made once: a formatter per date was the cost of every decode.
enum Dates {
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct API {
    var base: URL
    var token: String?
    /// Videos started on the phone offline, by their phone id: the id the Mac gave each one later.
    var renamed: [String: String] = [:]

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = Dates.plain.date(from: s) ?? Dates.fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    /// Short: screens show their saved copy first, so a sleeping Mac should fail fast, not spin
    /// for 30 s. The pair call has its own long wait (the user walks to the Mac).
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var query = query
        for k in ["id", "session"] { if let v = query[k], let real = renamed[v] { query[k] = real } }
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        // Sorted: the same picture must get the same URL, or no cache ever hits.
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }

    func request(_ path: String, _ query: [String: String] = [:], method: String = "GET", json: Any? = nil) -> URLRequest {
        var r = URLRequest(url: url(path, query))
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func send<T: Decodable>(_ r: URLRequest, as: T.Type = T.self, session: URLSession = API.session) async throws -> T {
        try Self.decoder.decode(T.self, from: try await raw(r, session: session))
    }

    func raw(_ r: URLRequest, session: URLSession = API.session) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw APIError(status: status, message: msg.isEmpty ? "The Mac answered \(status)" : msg)
        }
        return data
    }

    struct OK: Decodable {}

    func ping() async throws { _ = try await send(request("/api/ping"), as: [String: String].self) }

    func pair(name: String) async throws -> String {
        var r = request("/api/pair", method: "POST", json: ["name": name])
        r.timeoutInterval = 150
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 150
        let s = URLSession(configuration: c)
        return try await send(r, as: [String: String].self, session: s)["token"] ?? ""
    }

    func sessions() async throws -> [Session] { try await send(request("/api/sessions")) }

    /// A new build of this app staged on the Mac (ios/install.sh); a tap installs it.
    func appUpdate() async throws -> AppUpdate { try await send(request("/api/update")) }
    func installUpdate() async throws -> AppUpdate { try await send(request("/api/update/install", method: "POST")) }
    func detail(_ id: String) async throws -> SessionDetail { try await send(request("/api/session", ["id": id])) }
    func chat(_ id: String) async throws -> Chat { try await send(request("/api/chat", ["id": id])) }

    func say(_ text: String, in id: String) async throws {
        _ = try await send(request("/api/chat", ["id": id], method: "POST", json: ["text": text]), as: OK.self)
    }

    func stop(_ id: String) async throws { _ = try await send(request("/api/chat/stop", ["id": id], method: "POST"), as: OK.self) }
    func read(_ id: String) async throws { _ = try await send(request("/api/chat/read", ["id": id], method: "POST"), as: OK.self) }
    func cover(_ path: String) async throws { _ = try await send(request("/api/cover", ["path": path], method: "POST"), as: OK.self) }
    func archive(_ id: String, _ on: Bool) async throws {
        _ = try await send(request("/api/archive", ["id": id, "on": on ? "1" : "0"], method: "POST"), as: OK.self)
    }
    func keeper(_ id: String, take: Int) async throws {
        _ = try await send(request("/api/keeper", ["id": id, "take": String(take)], method: "POST"), as: OK.self)
    }

    /// Media and pictures carry the token in the URL, so AVPlayer and AsyncImage can load them.
    // Comments on the script and the post. Claude reads them on the Mac (MCP get_comments).
    func comments(_ id: String) async throws -> [Comment] { try await send(request("/api/comments", ["id": id])) }
    func comment(_ id: String, file: String, quote: String?, text: String) async throws -> Comment {
        var body = ["file": file, "text": text]
        if let quote { body["quote"] = quote }
        return try await send(request("/api/comments", ["id": id], method: "POST", json: body))
    }
    /// A comment on a video (a moment or a range) or a picture, with an area or the whole frame.
    /// file is the path inside the session.
    func comment(_ id: String, media file: String, start: Double?, end: Double?, rect: CGRect?, text: String) async throws -> Comment {
        var body: [String: Any] = ["file": file, "text": text]
        if let start { body["start"] = start }
        if let end { body["end"] = end }
        if let rect { body["rect"] = [rect.minX, rect.minY, rect.width, rect.height].map(Double.init) }
        return try await send(request("/api/comments", ["id": id], method: "POST", json: body))
    }
    /// Feedback on a storyboard shot.
    func comment(_ id: String, shot: String, text: String) async throws -> Comment {
        try await send(request("/api/comments", ["id": id], method: "POST",
                               json: ["file": "storyboard/storyboard.json", "shot": shot, "text": text]))
    }
    func reply(_ id: String, comment: String, text: String) async throws {
        _ = try await send(request("/api/comments/reply", ["id": id], method: "POST", json: ["id": comment, "text": text]), as: Comment?.self)
    }
    func resolve(_ id: String, comment: String, _ resolved: Bool) async throws {
        _ = try await send(request("/api/comments/reply", ["id": id], method: "POST",
                                   json: ["id": comment, "resolved": resolved ? "true" : "false"]), as: Comment?.self)
    }
    // New sessions.
    func projects() async throws -> [String] { try await send(request("/api/projects")) }
    func newSession(project: String, title: String, idea: String) async throws -> Session {
        try await send(request("/api/sessions", method: "POST", json: ["project": project, "title": title, "idea": idea]))
    }

    // The comment copilot. The Comments board's chats are "board:comments" (finding) and
    // "board:comments-post" (posting): chat(), say(), stop() take them like a session id.
    func copilotData() async throws -> Data { try await raw(request("/api/copilot")) }
    func decide(_ id: String, _ action: String, _ extra: [String: Any] = [:]) async throws {
        var body = extra
        body["id"] = id
        body["action"] = action
        _ = try await send(request("/api/copilot", method: "POST", json: body), as: OK.self)
    }
    func runCopilot(_ lane: String, count: Int = 5) async throws {
        _ = try await send(request("/api/copilot/run", method: "POST", json: ["lane": lane, "count": count]), as: OK.self)
    }
    func copilotPhoto(_ id: String) -> URL { url("/api/copilot/photo", ["id": id, "token": token ?? ""]) }

    /// The raw answer, so the phone can keep it and show it at once next time.
    func performanceData() async throws -> Data { try await raw(request("/api/performance")) }

    func stylesData() async throws -> Data { try await raw(request("/api/styles")) }
    /// One style by name, or a project's own looks by its library folder ("<Project>/_library").
    func style(name: String?, id: String?) async throws -> StyleDetail {
        try await send(request("/api/style", name.map { ["name": $0] } ?? ["id": id ?? ""]))
    }
    /// action: keep (it loses its New mark) or trash (to the Mac's Trash).
    func changeStyle(_ name: String, action: String) async throws {
        _ = try await send(request("/api/style", method: "POST", json: ["name": name, "action": action]), as: OK.self)
    }
    /// A video's style. nil: its project's. project: the pick becomes the project's style.
    func setStyle(_ id: String, style: String?, project: Bool = false) async throws -> SessionStyle {
        try await send(request("/api/session/style", ["id": id], method: "POST",
                               json: ["style": style ?? "", "project": project ? "1" : "0"]))
    }

    /// Saves the script or the post. `base` is the text the edit started from: if it changed on
    /// the Mac meanwhile, the Mac answers 409 and keeps its text.
    func save(_ what: String, _ id: String, text: String, base: String) async throws {
        _ = try await send(request("/api/" + what, ["id": id], method: "POST", json: ["text": text, "base": base]), as: OK.self)
    }

    /// Variants and hooks of the post: promote, hook, save. See PhoneServer.postDraft.
    func postDraft(_ id: String, _ body: [String: String]) async throws {
        _ = try await send(request("/api/post/draft", ["id": id], method: "POST", json: body), as: OK.self)
    }

    var profilePhoto: URL { url("/api/profile/photo", ["token": token ?? ""]) }

    func media(_ path: String) -> URL { url("/media", ["path": path, "token": token ?? ""]) }
    func thumb(_ path: String, width: Int = 480) -> URL { url("/thumb", ["path": path, "w": String(width), "token": token ?? ""]) }

    func upload(session: String, name: String, asTake: Bool, shot: String? = nil) -> URLRequest {
        var q = ["session": session, "name": name]
        if asTake { q["as"] = "take" }
        if let shot { q["shot"] = shot }
        var r = request("/api/upload", q, method: "PUT")
        r.timeoutInterval = 600
        return r
    }
}
