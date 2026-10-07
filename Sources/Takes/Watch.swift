import CoreServices
import Foundation
import QuartzCore
import SwiftUI

// One FSEvents stream on the library root tells every pane when files change (Claude through the
// MCP server, Finder, an editor). It replaces the 2-second polls: an idle app does no disk work.

extension Notification.Name {
    /// `object` is the changed folders as [String] paths.
    static let takesFilesChanged = Notification.Name("de.marvinaziz.takes.filesChanged")
}

final class FileWatch {
    private var stream: FSEventStreamRef?
    private(set) var root: URL?

    func watch(_ url: URL) {
        guard url.standardizedFileURL != root?.standardizedFileURL else { return }
        stop()
        root = url.standardizedFileURL
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
            guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String], count > 0 else { return }
            FileWatch.collect(list)
        }
        // File events, so a chat save can be told apart from a real change (see `folders`).
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [url.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        root = nil
    }

    deinit { stop() }

    // A render writes its file many times a second, and each event made every pane read the disk
    // again on the main thread (assets, comments, post, hooks, the library). Changes are now
    // collected and sent at most once a second, with every folder that changed (2026-10-01).
    static let every: TimeInterval = 1
    private static var pending: Set<String> = []
    private static var due = false

    /// Runs on the main queue (the stream's dispatch queue).
    private static func collect(_ paths: [String]) {
        let changed = folders(paths)
        guard !changed.isEmpty else { return }
        pending.formUnion(changed)
        guard !due else { return }
        due = true
        DispatchQueue.main.asyncAfter(deadline: .now() + every) {
            let list = Array(pending)
            pending = []
            due = false
            NotificationCenter.default.post(name: .takesFilesChanged, object: list)
        }
    }

    /// The folders the changed files are in, as the listeners expect. The chat's own state file
    /// is left out: every message saved it, and that made each pane of the session and the
    /// sidebar read the disk again a second later (2026-10-07).
    static func folders(_ paths: [String]) -> Set<String> {
        Set(paths.compactMap { p in
            let url = URL(fileURLWithPath: p)
            if url.lastPathComponent.hasPrefix(".claude-chat.json") { return nil }
            return url.deletingLastPathComponent().path
        })
    }

    /// True if a change in `note` is inside `folder`.
    static func touches(_ note: Notification, _ folder: URL?) -> Bool {
        guard let folder, let paths = note.object as? [String] else { return false }
        return touches(paths, folder)
    }

    static func touches(_ paths: [String], _ folder: URL) -> Bool {
        let f = folder.standardizedFileURL.path
        return paths.contains { p in
            let q = URL(fileURLWithPath: p).standardizedFileURL.path
            return q == f || q.hasPrefix(f.hasSuffix("/") ? f : f + "/")
        }
    }
}

extension View {
    /// Runs `perform` when files inside `folder` change on disk. A tab kept mounted under another
    /// one (`paneShown` false) waits and runs it once when it shows again.
    func onFilesChanged(in folder: URL?, perform: @escaping () -> Void) -> some View {
        modifier(FilesChanged(folder: folder, perform: perform))
    }
}

private struct FilesChanged: ViewModifier {
    let folder: URL?
    let perform: () -> Void
    @Environment(\.paneShown) private var shown
    @State private var stale = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
                guard FileWatch.touches(n, folder) else { return }
                if shown { perform() } else { stale = true }
            }
            .onChange(of: shown) { _, on in
                if on && stale { stale = false; perform() }
            }
    }
}

/// Notices when the main thread stops answering (the app froze) and saves a `sample` of every
/// thread to ~/Library/Logs/Takes/hang-<time>.txt, once per freeze. The next freeze names its own
/// cause, even when nobody was watching.
enum HangWatch {
    /// Seconds in a row without an answer. Counted in ticks, so a Mac waking from sleep (a jump
    /// in the clock) is not a freeze.
    static let limit = 6
    private static let lock = NSLock()
    nonisolated(unsafe) private static var beat = 0

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Takes")
    }

    static func start() {
        let t = Thread {
            var last = -1, missed = 0, reported = false
            while true {
                Thread.sleep(forTimeInterval: 1)
                let now = lock.withLock { beat }
                missed = now == last ? missed + 1 : 0
                last = now
                DispatchQueue.main.async { lock.withLock { beat &+= 1 } }
                if missed < limit { reported = false; continue }
                if reported { continue }
                reported = true
                sample()
            }
        }
        t.qualityOfService = .utility
        t.name = "takes.hangwatch"
        t.start()
    }

    private static let sampling = NSLock()
    nonisolated(unsafe) private static var running = false
    nonisolated(unsafe) private static var lastStart = 0.0

    /// Starts `sample` on Takes in the background and returns the file name at once, or nil when
    /// one runs already or ran less than 2 minutes ago. 10 ms between looks, not 1 ms, so the
    /// sampler holds Takes still less often. A stuck `sample` is killed after 30 s.
    @discardableResult
    static func sample(prefix: String = "hang") -> String? {
        let now = CACurrentMediaTime()
        let go = sampling.withLock {
            guard !running, prefix == "hang" || now - lastStart > 120 else { return false }
            running = true; lastStart = now
            return true
        }
        guard go else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "\(prefix)-\(f.string(from: Date())).txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "10", "-mayDie", "-file", folder.appending(path: name).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            sampling.withLock { running = false }
            // Keep the newest ten of each kind.
            let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .dropFirst(10)
            for u in old { try? fm.removeItem(at: u) }
        }
        guard (try? p.run()) != nil else { sampling.withLock { running = false }; return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        return name
    }
}
