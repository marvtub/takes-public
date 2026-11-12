import AppKit
import SwiftUI

// The posting plan: every post that is ready, scheduled or posted, with its time. The post tab's
// [schedule] button sets the time. Claude reads the same plan (MCP get_post_queue), schedules LinkedIn
// posts in the user's Chrome and X posts through Typefully, then records it (set_post_status, which can
// also bring the time it used).

struct QueuedPost: Identifiable, Equatable {
    let session: URL
    var platform: PostPlatform = .linkedin
    let project: String
    let title: String
    var content: PostFile.Content
    /// A session can have a LinkedIn and an X post: both are in the plan.
    var id: String { session.path + "#" + platform.rawValue }

    var firstLine: String {
        content.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

@MainActor
final class PostQueue: ObservableObject {
    @Published private(set) var posts: [QueuedPost] = []
    private(set) var root: URL?

    /// Ready or scheduled, with no time yet.
    var unplanned: [QueuedPost] {
        posts.filter { $0.content.at == nil && [.ready, .scheduled].contains($0.content.status) }
    }
    var planned: [QueuedPost] { posts.filter { $0.content.at != nil && $0.content.status != .draft } }
    /// Posts still being written. They show under the ready ones and can be dragged in too.
    var drafts: [QueuedPost] { posts.filter { $0.content.status == .draft } }

    /// Every session with a post, across all projects. Cheap: one stat per session.
    func scan(_ root: URL) {
        self.root = root
        apply(Self.read(root))
    }

    /// The same scan off the main thread, for file changes: it reads every post file.
    func scanInBackground(_ root: URL) {
        self.root = root
        Task.detached(priority: .utility) {
            let found = Self.read(root)
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: [QueuedPost]) {
        var found = found
        Self.settle(&found)
        if found != posts { posts = found }
    }

    nonisolated static func read(_ root: URL) -> [QueuedPost] {
        let fm = FileManager.default
        var found: [QueuedPost] = []
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        where !project.lastPathComponent.hasPrefix("_") {
            for s in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                var title: String?   // read once per session, not once per post
                for p in PostPlatform.shown {
                    guard let c = PostFile.read(s, p) else { continue }
                    if title == nil { title = Self.title(s) }
                    found.append(QueuedPost(session: s, platform: p, project: project.lastPathComponent,
                                            title: title ?? s.lastPathComponent, content: c))
                }
            }
        }
        // `at` parses a date each time it is read: once per post, not twice per comparison
        // (1.6 s of a 1.8 s scan at 1,000 sessions, 2026-10-11).
        return found.map { ($0, $0.content.at ?? .distantFuture) }
            .sorted { ($0.1, $0.0.title) < ($1.1, $1.0.title) }
            .map(\.0)
    }

    /// Called every 15 s: a post whose time came goes from scheduled to posted.
    func settle() {
        var next = posts
        Self.settle(&next)
        if next != posts { posts = next }
    }

    /// A post scheduled on the platform goes out at its time, so once that passes it is posted and
    /// the session published (dated at that time; Claude adds the link and numbers later). Not one
    /// that changed since it was scheduled: the platform may still have the old time. Not one an
    /// autopost plugin sends: it marks that one posted itself, with the link, or failed.
    static func settle(_ list: inout [QueuedPost], now: Date = Date()) {
        let sends = Plugins.builtAutopost?.sends
        for i in list.indices {
            let c = list[i].content
            guard c.status == .scheduled, !c.needsUpdate, let at = c.at, at <= now, sends?(c) != true else { continue }
            let s = list[i].session, p = list[i].platform
            PostFile.update(s, p) { $0.status = .posted }
            SessionDoc(url: s).markPublished(p.name, at: at)
            list[i].content.status = .posted
        }
    }

    nonisolated static func title(_ session: URL) -> String {
        guard let data = try? Data(contentsOf: session.appending(path: "session.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["title"] as? String else { return session.lastPathComponent }
        return t
    }

    func update(_ session: URL, _ platform: PostPlatform = .linkedin, _ change: (inout PostFile.Content) -> Void) {
        PostFile.update(session, platform, change)
        if let root { scan(root) }
    }

    func update(_ post: QueuedPost, _ change: (inout PostFile.Content) -> Void) {
        update(post.session, post.platform, change)
    }

    func post(_ id: QueuedPost.ID?) -> QueuedPost? { posts.first { $0.id == id } }

    private nonisolated static let assetFolders = ["edits", "stills", "storyboard", "thumbnails", "uploads", "history", "variants", "broll"]

    /// Changes under the library that can touch a post or a title.
    nonisolated static func matters(_ paths: [String]) -> Bool {
        // FSEvents names folders: a post is in <session>/posts/, a title in the session folder.
        // Asset folders, `_library` and hidden folders cannot change either.
        paths.contains { p in
            let q = p.hasSuffix("/") ? String(p.dropLast()) : p
            if q.hasSuffix("/posts") || q.contains("/posts/") { return true }
            return !q.contains("/_") && !q.contains("/.") && !assetFolders.contains { q.contains("/" + $0) }
        }
    }
}

extension PostFile {
    /// "Thu, Oct 1, 9:00 AM PDT", in the post's own time zone.
    static func label(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "EEE, MMM d, h:mm a zzz"
        return f.string(from: date)
    }

    /// The same wall-clock time in another zone: 9:00 in LA becomes 9:00 in Berlin.
    static func moved(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        var a = Calendar(identifier: .gregorian); a.timeZone = from
        var b = Calendar(identifier: .gregorian); b.timeZone = to
        let parts = a.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return b.date(from: parts) ?? date
    }

    /// Time zones to pick from: yours first, then the usual ones.
    static func zones(with extra: TimeZone? = nil) -> [TimeZone] {
        let ids = [TimeZone.current.identifier, extra?.identifier].compactMap { $0 } + [
            "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Sao_Paulo",
            "Europe/London", "Europe/Berlin", "Europe/Istanbul", "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore",
            "Asia/Tokyo", "Australia/Sydney", "UTC"]
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap(TimeZone.init(identifier:))
    }

    static func zoneName(_ z: TimeZone) -> String {
        let city = z.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? z.identifier
        return "\(city) (\(z.abbreviation() ?? ""))"
    }
}
