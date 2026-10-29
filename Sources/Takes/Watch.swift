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
    // The stream starts, stops and gets its events on its own queue. FSEventStreamStart waits for
    // fseventsd, and on 14 Oct it did not answer: the main thread hung 99 s at launch inside
    // AppModel.init. Events go to the main queue after they come in (2026-10-18).
    // Its own queue per watch: one slow start must not hold up another watch.
    private let queue = DispatchQueue(label: "de.marvinaziz.takes.filewatch", qos: .utility)
    private var stream: FSEventStreamRef?  // only read or written on `queue`
    private(set) var root: URL?

    func watch(_ url: URL) {
        guard url.standardizedFileURL != root?.standardizedFileURL else { return }
        stop()
        root = url.standardizedFileURL
        let path = url.path
        queue.async { [self] in
            var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
                guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String], count > 0 else { return }
                DispatchQueue.main.async { FileWatch.collect(list) }
            }
            // File events, so a chat save can be told apart from a real change (see `folders`).
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Runs `done` once the stream has started (or failed to). Tests: a write before that is not seen.
    func started(_ done: @escaping @Sendable () -> Void) { queue.async(execute: done) }

    func stop() {
        root = nil
        queue.async { [self] in Self.end(stream); stream = nil }
    }

    private static func end(_ s: FSEventStreamRef?) {
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit { let s = stream; queue.async { Self.end(s) } }

    // A render writes its file many times a second, and each event made every pane read the disk
    // again on the main thread (assets, comments, post, hooks, the library). Changes are now
    // collected and sent at most once a second, with every folder that changed (2026-10-01).
    static let every: TimeInterval = 1
    private static var pending: Set<String> = []
    private static var pendingJobs: Set<String> = []
    private static var due = false

    /// Runs on the main queue (the stream callback sends it there).
    private static func collect(_ paths: [String]) {
        let changed = folders(paths), jobs = jobSessions(paths)
        guard !changed.isEmpty || !jobs.isEmpty else { return }
        pending.formUnion(changed)
        pendingJobs.formUnion(jobs)
        guard !due else { return }
        due = true
        DispatchQueue.main.asyncAfter(deadline: .now() + every) {
            let list = Array(pending), sessions = pendingJobs
            pending = []
            pendingJobs = []
            due = false
            if !list.isEmpty { NotificationCenter.default.post(name: .takesFilesChanged, object: list) }
            for s in sessions { NotificationCenter.default.post(name: .takesJobsChanged, object: URL(fileURLWithPath: s)) }
        }
    }

    /// The folder of a job file: <session>/.jobs or <session>/generated/.jobs, deeper for a partial.
    private static func jobsIndex(_ parts: [String]) -> Int? { parts.lastIndex(of: ".jobs") }

    /// Sessions whose job state changed: a job's .json, .told or .stop. Its log, lock and partial
    /// folder change all the time and say nothing new (Jobs.swift).
    static func jobSessions(_ paths: [String]) -> Set<String> {
        Set(paths.compactMap { p in
            let url = URL(fileURLWithPath: p)
            let parts = url.pathComponents
            guard let i = jobsIndex(parts), i == parts.count - 2 else { return nil }
            guard ["json", "told", "stop"].contains(url.pathExtension) else { return nil }
            var session = url.deletingLastPathComponent().deletingLastPathComponent()
            if session.lastPathComponent == "generated" { session = session.deletingLastPathComponent() }
            return session.path
        })
    }

    /// The folders the changed files are in, as the listeners expect. The chat's own state file
    /// is left out: every message saved it, and that made each pane of the session and the
    /// sidebar read the disk again a second later (2026-10-07).
    static func folders(_ paths: [String]) -> Set<String> {
        Set(paths.compactMap { p in
            let url = URL(fileURLWithPath: p)
            if url.lastPathComponent.hasPrefix(".claude-chat.json") { return nil }
            // A job writes its state every 2 s: that goes to .takesJobsChanged only (jobSessions).
            if jobsIndex(url.pathComponents) != nil || url.lastPathComponent.hasPrefix(".jobs") { return nil }
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

    /// A board that scans every session counts only the files its scan reads: `library` names
    /// under _library (a file or a folder), `files` in a session folder, `folders` in a session.
    /// A session or project made, renamed or removed counts too. Chat logs, renders' temp files
    /// and the like rescanned the whole library each second (2026-10-11).
    nonisolated static func matters(_ paths: [String], root: URL, library: Set<String>,
                                    files: Set<String>, folders: Set<String>) -> Bool {
        let r = root.standardizedFileURL.path
        let base = r.hasSuffix("/") ? r : r + "/"
        return paths.isEmpty || paths.contains { p in
            let q = URL(fileURLWithPath: p).standardizedFileURL.path
            guard q.hasPrefix(base) else { return false }
            let parts = q.dropFirst(base.count).split(separator: "/").map(String.init)
            guard let first = parts.first else { return true }
            if first == "_library" { return parts.count > 1 && library.contains(parts[1]) }
            if first.hasPrefix("_") || first.hasPrefix(".") { return false }
            if parts.count <= 2 { return true }
            if parts.last?.hasPrefix(".") == true { return false }
            return parts.count == 3 && files.contains(parts[2]) || folders.contains(parts[2])
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

/// Saves a `sample` of every thread to ~/Library/Logs/Takes/hang-<time>.txt, once per freeze, so
/// the next freeze names its own cause, even when nobody was watching. Stall's thread notices the
/// freeze: a second thread that woke every second to ask the same question was merged into it
/// (2026-10-11).
enum HangWatch {
    /// Seconds without an answer before a freeze counts as a hang.
    static let limit = 6

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Takes")
    }

    private static let sampling = NSLock()
    nonisolated(unsafe) private static var running = false
    nonisolated(unsafe) private static var lastStart = 0.0

    /// Starts `sample` on Takes in the background and returns the file name at once, or nil when
    /// one runs already or ran less than 2 minutes ago. 10 ms between looks, not 1 ms, so the
    /// sampler holds Takes still less often. A stuck `sample` is killed after 30 s.
    /// seconds: how long it samples (a launch: the whole first 8 s). done gets the file when it ends.
    @discardableResult
    static func sample(prefix: String = "hang", seconds: Int = 2, done: (@Sendable (URL) -> Void)? = nil) -> String? {
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
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds), "10", "-mayDie", "-file", folder.appending(path: name).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let file = folder.appending(path: name)
        p.terminationHandler = { _ in
            sampling.withLock { running = false }
            done?(file)
            // Keep the newest ten of each kind.
            let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .dropFirst(10)
            for u in old { try? fm.removeItem(at: u) }
        }
        guard (try? p.run()) != nil else { sampling.withLock { running = false }; return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds + 28)) { if p.isRunning { p.terminate() } }
        return name
    }
}
