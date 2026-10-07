import AVFoundation
import AppKit
import CryptoKit
import Network
import Observation
import SwiftUI

/// Search by meaning (2026-10-06): ⌘K finds clips by what they show ("hands typing", "walking
/// outside"), stills, and the words in transcripts and scripts. EmbeddingGemma 2 runs on this Mac
/// in the takes-embed helper (embed/, inside Takes.app); nothing goes to a server.
///
/// The model (~510 MB) is not in the app. After launch Takes downloads it in the background,
/// resumes where it stopped, waits while Low Data Mode is on, and checks each file's SHA-256.
/// Until it is ready, search matches file names and transcript words.
@MainActor @Observable
final class MediaSearch {
    static let shared = MediaSearch()
    init() {}

    enum ModelState: Equatable {
        case unsupported          // a build without the helper (no Xcode Metal toolchain)
        case missing
        case waiting(String)
        case downloading(Double)
        case paused
        case ready
        case failed(String)
    }

    struct Hit: Identifiable, Equatable {
        var id: String { kind + ":" + (title ?? "") + path.path + "#\(start)" }
        var path: URL
        var kind: String          // video, image, speech, script, name; session, project, board
        var start: Double
        var text: String?
        var title: String? = nil  // session, project and board rows show this, not the file name
        var board: AppModel.Board? = nil
    }

    var model: ModelState = .missing
    var indexDone = 0
    var indexTotal = 0
    var indexing = false
    var indexedFiles = 0
    var shown = false

    // MARK: Model files

    struct ModelFile: Sendable { let path: String; let bytes: Int64; let sha: String }
    /// Pinned to one revision; each file must match its size and SHA-256.
    nonisolated static let repo = "Nurymanau/EmbeddingGemma-2-MLX-Swift"
    nonisolated static let revision = "06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd"
    nonisolated static let files: [ModelFile] = [
        .init(path: "text-q8/model.safetensors", bytes: 288118885, sha: "eb8a067456a3cff750bebadc7b985420444e673508a2da5bcf56e726e52d62c9"),
        .init(path: "text-q8/config.json", bytes: 2359, sha: "e090bf087c627155c55b481fca9d216461bdaf44d5a980e018ed3deb92fc7664"),
        .init(path: "text-q8/tokenizer.json", bytes: 32170510, sha: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
        .init(path: "text-q8/tokenizer_config.json", bytes: 1599, sha: "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874"),
        .init(path: "text-q8/config_sentence_transformers.json", bytes: 1565, sha: "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5"),
        .init(path: "text-q8/quantization.json", bytes: 16288, sha: "9de7e788a89f36a07387c9758dd187b596675bfe9e0dbf9e56c3a09f1f410965"),
        .init(path: "text-q8/manifest.json", bytes: 379, sha: "d9cdb30351293694b7343078970c72b3696eb12034ff06bff2af663fdc3c5cd8"),
        .init(path: "vision-q8/vision.safetensors", bytes: 193095171, sha: "9b18ee38272989696737fe3a0c4302dfa06f47cc37192b1b8f7583f8447da173"),
        .init(path: "vision-q8/config.json", bytes: 3453, sha: "6ece510cf4df3d5370011ea0e856486f971dbd8019f5587c6a059977d61571d4"),
        .init(path: "vision-q8/quantization.json", bytes: 11258, sha: "19c4f4d59a942f0829b4c5b6d8da12e24c5a5306434a22f0705e10ff2ced1186"),
        .init(path: "vision-q8/manifest.json", bytes: 380, sha: "db92014f981b36cde052bc4759929d343d30b22f7888c623375b50427ffa11a4"),
    ]
    nonisolated static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    nonisolated static var modelsDir: URL {
        URL.applicationSupportDirectory.appending(path: "Takes/Models/embeddinggemma-2-q8")
    }
    nonisolated static var helper: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "takes-embed").flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
    /// All files present with the right size (the SHA-256 is checked once, when each file lands).
    nonisolated static var modelPresent: Bool {
        files.allSatisfy { f in
            let size = (try? FileManager.default.attributesOfItem(atPath: modelsDir.appending(path: f.path).path)[.size] as? Int64) ?? -1
            return size == f.bytes
        }
    }

    private var pausedByUser: Bool {
        get { UserDefaults.standard.bool(forKey: "searchModelPaused") }
        set { UserDefaults.standard.set(newValue, forKey: "searchModelPaused") }
    }

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var constrained = false
    @ObservationIgnored private var online = true
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var fetcher: Fetcher?
    @ObservationIgnored private var started = false

    // MARK: Start

    /// At launch: the download (if needed) after a short wait, so it never slows the start.
    func start() {
        guard !started else { return }
        started = true
        guard Self.helper != nil else { model = .unsupported; return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            Task { @MainActor in
                let s = MediaSearch.shared
                s.constrained = path.isConstrained
                s.online = path.status == .satisfied
                s.resumeIfWaiting()
            }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
        if Self.modelPresent { model = .ready; startHelper(); return }
        if pausedByUser { model = .paused; return }
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.download()
        }
    }

    private func resumeIfWaiting() {
        if case .waiting = model { download() }
        if constrained, case .downloading = model { fetcher?.cancel(); model = .waiting("Waiting: Low Data Mode is on.") }
    }

    func download() {
        guard Self.helper != nil, downloadTask == nil, !Self.modelPresent else {
            if Self.modelPresent, model != .ready { model = .ready; startHelper() }
            return
        }
        pausedByUser = false
        if constrained { model = .waiting("Waiting: Low Data Mode is on."); return }
        if !online { model = .waiting("Waiting for the internet."); return }
        model = .downloading(progressSoFar())
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                for f in Self.files { try await fetch(f) }
                model = .ready
                startHelper()
            } catch is CancellationError {
                // pause() or Low Data Mode set the state already.
            } catch {
                model = .failed(error.localizedDescription)
            }
        }
    }

    func pause() {
        pausedByUser = true
        downloadTask?.cancel()
        fetcher?.cancel()
        model = .paused
    }

    /// Deletes the model and the index. Search goes back to file names.
    func remove() {
        pause()
        stopHelper()
        try? FileManager.default.removeItem(at: Self.modelsDir)
        if let root = root { try? FileManager.default.removeItem(at: root.appending(path: "_library/search")) }
        indexedFiles = 0
        model = .paused
    }

    private func progressSoFar() -> Double {
        var have: Int64 = 0
        for f in Self.files {
            let dest = Self.modelsDir.appending(path: f.path)
            let fm = FileManager.default
            if let s = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64 { have += s }
            else if let s = try? fm.attributesOfItem(atPath: dest.path + ".part")[.size] as? Int64 { have += s }
        }
        return Double(have) / Double(Self.totalBytes)
    }

    private func fetch(_ f: ModelFile) async throws {
        let dest = Self.modelsDir.appending(path: f.path)
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) == f.bytes { return }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = URL(fileURLWithPath: dest.path + ".part")
        let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(f.path)")!
        let before = progressSoFar() * Double(Self.totalBytes) - Double((try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0)
        let fetcher = Fetcher(url: url, to: part) { [weak self] got in
            Task { @MainActor in
                guard let self, case .downloading = self.model else { return }
                self.model = .downloading(min(1, (before + Double(got)) / Double(Self.totalBytes)))
            }
        }
        self.fetcher = fetcher
        try await withTaskCancellationHandler { try await fetcher.run() } onCancel: { fetcher.cancel() }
        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        guard size == f.bytes, try await Self.sha256(part) == f.sha else {
            try? fm.removeItem(at: part)
            throw NSError(domain: "Takes", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(f.path) did not match its checksum. Try again."])
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    nonisolated static func sha256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: Helper process

    @ObservationIgnored private var process: Process?
    /// The helper never quits on its own, so the updater skips it when it waits for child processes.
    var helperPID: Int32? { process?.processIdentifier }
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<[[String: Any]], Never>] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var helperRoot: URL?
    @ObservationIgnored private var timer: Timer?

    /// The library folder. Like Library.init: with no saved choice it is ~/Movies/Takes. Before
    /// (2026-10-06) only a saved choice counted, so on the default folder the helper never started
    /// and ⌘K found nothing.
    private var root: URL? {
        UserDefaults.standard.string(forKey: "root").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
    }

    func startHelper() {
        guard process == nil, let helper = Self.helper, let root else { return }
        let p = Process()
        p.executableURL = helper
        p.arguments = ["serve", "--models", Self.modelsDir.path, "--root", root.path]
        p.qualityOfService = .utility
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            Task { @MainActor in MediaSearch.shared.received(data) }
        }
        p.terminationHandler = { _ in
            Task { @MainActor in
                let s = MediaSearch.shared
                s.process = nil; s.input = nil; s.indexing = false
                for (_, c) in s.waiting { c.resume(returning: []) }
                s.waiting = [:]
            }
        }
        guard (try? p.run()) != nil else { return }
        process = p
        input = inp.fileHandleForWriting
        helperRoot = root
        send(["op": "index", "id": 0])
        // New takes and edits: look again every ten minutes. Unchanged files are skipped.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in MediaSearch.shared.reindex() }
        }
    }

    func stopHelper() {
        timer?.invalidate(); timer = nil
        try? input?.close()   // the helper saves and quits when its input closes
        process = nil; input = nil; indexing = false
    }

    func reindex() {
        if let r = root, r != helperRoot { stopHelper(); startHelper(); return }
        guard process != nil, !indexing else { return }
        send(["op": "index", "id": 0])
    }

    private func send(_ msg: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A)
        try? input?.write(contentsOf: d)
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if msg["event"] as? String == "progress" {
                indexing = true
                indexDone = msg["done"] as? Int ?? 0
                indexTotal = msg["total"] as? Int ?? 0
            } else if let id = msg["id"] as? Int, let c = waiting.removeValue(forKey: id) {
                c.resume(returning: msg["results"] as? [[String: Any]] ?? [])
            } else if msg["indexed"] != nil {
                indexing = false
                indexedFiles = msg["files"] as? Int ?? indexedFiles
            }
        }
    }

    // MARK: Search

    func search(_ query: String, limit: Int = 40) async -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if model == .ready, process == nil { startHelper() }
        guard model == .ready, process != nil else { return await Self.byName(q, root: root, limit: limit) }
        let id = nextID
        nextID += 1
        let rows = await withCheckedContinuation { c in
            waiting[id] = c
            send(["op": "search", "id": id, "query": q, "limit": limit])
        }
        let hits = rows.compactMap { r -> Hit? in
            guard let p = r["path"] as? String else { return nil }
            return Hit(path: URL(fileURLWithPath: p), kind: r["kind"] as? String ?? "video",
                       start: r["start"] as? Double ?? 0, text: r["text"] as? String)
        }
        return hits.isEmpty ? await Self.byName(q, root: root, limit: limit) : hits
    }

    /// Sessions, projects and boards whose name has every word of the query. Names that start
    /// with the query come first.
    static func places(_ q: String, app: AppModel, limit: Int = 6) -> [Hit] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let lib = app.library
        var rows: [(Hit, String)] = []
        var boards: [(String, AppModel.Board)] = [("Styles", .styles)]
        if Features.socialBoards { boards = [("Performance", .performance), ("Comments", .comments)] + boards }
        boards += Plugins.all.map { ($0.title, .plugin($0.id)) }
        for (t, b) in boards {
            rows.append((Hit(path: lib.root, kind: "board", start: 0, title: t, board: b), t))
        }
        for p in lib.projects {
            rows.append((Hit(path: p.url, kind: "project", start: 0, title: p.name), p.name))
            for s in lib.grouped[p.url] ?? [] {
                rows.append((Hit(path: s.url, kind: "session", start: 0, text: p.name, title: s.title), s.title))
            }
        }
        let found = rows.filter { _, name in let n = name.lowercased(); return words.allSatisfy(n.contains) }
        let lead = q.lowercased()
        return found.enumerated().sorted { a, b in
            let pa = a.element.1.lowercased().hasPrefix(lead), pb = b.element.1.lowercased().hasPrefix(lead)
            return pa != pb ? pa : a.offset < b.offset
        }.prefix(limit).map(\.element.0)
    }

    /// Before the model is ready: file names, scripts and transcripts that contain every word.
    nonisolated static func byName(_ q: String, root: URL?, limit: Int) async -> [Hit] {
        guard let root else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let words = q.lowercased().split(separator: " ").map(String.init)
            let media: Set<String> = ["mov", "mp4", "m4v", "png", "jpg", "jpeg", "heic", "webp"]
            var hits: [Hit] = []
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
            while let url = walk.nextObject() as? URL {
                if hits.count >= limit { break }
                let name = url.lastPathComponent
                if ["history", "comments", "posts", "storyboard"].contains(name) { walk.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                if media.contains(ext) {
                    let n = name.lowercased()
                    if words.allSatisfy(n.contains) {
                        hits.append(Hit(path: url, kind: ["png", "jpg", "jpeg", "heic", "webp"].contains(ext) ? "image" : "video", start: 0))
                    }
                } else if name == "script.md" || name.hasSuffix(".words.json") {
                    guard let text = try? String(contentsOf: url, encoding: .utf8).lowercased(), words.allSatisfy(text.contains) else { continue }
                    if name == "script.md" { hits.append(Hit(path: url, kind: "script", start: 0)); continue }
                    let stem = String(url.path.dropLast(".words.json".count))
                    if let v = ["mp4", "mov", "m4v"].map({ URL(fileURLWithPath: stem + "." + $0) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        hits.append(Hit(path: v, kind: "speech", start: 0))
                    }
                }
            }
            return hits
        }.value
    }

    /// One line for Settings and the search window.
    var statusLine: String {
        switch model {
        case .unsupported: return "Search by meaning is not in this build. File names still work."
        case .missing: return "The search model downloads after launch."
        case .waiting(let why): return why
        case .downloading(let p): return "Downloading the search model: \(Int(p * 100)) % of \(ByteCountFormatter.string(fromByteCount: Self.totalBytes, countStyle: .file))"
        case .paused: return "Paused. Search uses file names and transcripts."
        case .failed(let why): return "The download stopped: \(why)"
        case .ready:
            if indexing, indexTotal > 0 { return "Indexing your footage: \(indexDone) of \(indexTotal) files" }
            return indexedFiles > 0 ? "Ready. \(indexedFiles) files indexed." : "Ready."
        }
    }
}

/// One file over HTTP into `<file>.part`, continuing where an earlier try stopped.
final class Fetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    let to: URL
    let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var got: Int64 = 0
    private var session: URLSession?
    private var done: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(url: URL, to: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.to = to; self.progress = progress
    }

    func run() async throws {
        if !FileManager.default.fileExists(atPath: to.path) { FileManager.default.createFile(atPath: to.path, contents: nil) }
        let h = try FileHandle(forWritingTo: to)
        got = Int64(try h.seekToEnd())
        handle = h
        var req = URLRequest(url: url)
        if got > 0 { req.setValue("bytes=\(got)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.allowsConstrainedNetworkAccess = false
        config.networkServiceType = .background
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); done = c; lock.unlock()
            s.dataTask(with: req).resume()
        }
    }

    func cancel() { session?.invalidateAndCancel() }

    private func finish(_ error: Error?) {
        lock.lock(); let c = done; done = nil; lock.unlock()
        try? handle?.close(); handle = nil
        session?.finishTasksAndInvalidate()
        if let error { c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error) } else { c?.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, got > 0 {
            // The server sent the whole file: start the part over.
            try? handle?.truncate(atOffset: 0); got = 0
        }
        guard code == 200 || code == 206 else {
            completionHandler(.cancel)
            finish(NSError(domain: "Takes", code: code, userInfo: [NSLocalizedDescriptionKey: "Hugging Face answered \(code)."]))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        got += Int64(data.count)
        progress(got)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }
}

// MARK: - ⌘K

/// One search for all of Takes (2026-10-06): sessions, projects and boards by name, then footage
/// by meaning. Pick a hit and it opens; a clip opens at its moment.
struct SearchPalette: View {
    @Environment(AppModel.self) private var app
    private var search = MediaSearch.shared
    @State private var query = ""
    @State private var hits: [MediaSearch.Hit] = []
    @State private var selected = 0
    @State private var busy = false
    @FocusState private var focused: Bool

    init(query: String = "") { _query = State(initialValue: query) }

    var body: some View {
        if search.shown {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { close() }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Search sessions, boards and footage: \"hands typing\", \"walking outside\"", text: $query)
                            .textFieldStyle(.plain)
                            .font(Theme.sans(16))
                            .focused($focused)
                            .onSubmit { open(selected) }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 16).frame(height: 52)
                    Rule()
                    if hits.isEmpty {
                        Text(query.isEmpty ? search.statusLine : (busy ? " " : "Nothing found."))
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                                        SearchRow(hit: h, root: app.library.root, on: i == selected)
                                            .id(i)
                                            .onTapGesture { open(i) }
                                    }
                                }
                                .padding(6)
                            }
                            .frame(height: min(440, hits.reduce(12) { $0 + SearchRow.height($1) }))
                            .onChange(of: selected) { _, i in withAnimation(Theme.motion) { proxy.scrollTo(i, anchor: .center) } }
                        }
                        if search.model != .ready {
                            Text(search.statusLine).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                                .overlay(alignment: .top) { Rule() }
                        }
                    }
                }
                .frame(width: 680)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                .cardShadow(RoundedRectangle(cornerRadius: 14), fill: Theme.paper, radius: 30, y: 12)
                .padding(.top, 90)
            }
            .onAppear { focused = true }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.downArrow) { selected = min(hits.count - 1, selected + 1); return .handled }
            .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
            .task(id: query) {
                // Names show at once; footage follows.
                let places = MediaSearch.places(query, app: app)
                hits = places; selected = 0
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                busy = true
                let found = await search.search(query)
                guard !Task.isCancelled else { return }
                hits = places + found; busy = false
            }
        }
    }

    private func close() { search.shown = false }

    private func open(_ i: Int) {
        guard hits.indices.contains(i) else { return }
        let h = hits[i]
        close()
        if let b = h.board {
            app.board = b
        } else if h.kind == "session" || h.kind == "project" {
            app.follow(h.path)
        } else if h.path.path.contains("/_library/broll/") {
            // Library b-roll has no session: it plays on the stage from the B-roll tab.
            SessionMode.set(.broll)
            app.jump(to: h.path, at: h.start)
        } else {
            app.open(h.path, at: h.kind == "video" || h.kind == "speech" ? h.start : nil)
        }
    }
}

private struct SearchRow: View {
    let hit: MediaSearch.Hit
    let root: URL
    let on: Bool
    @State private var thumb: NSImage?

    static func height(_ h: MediaSearch.Hit) -> CGFloat { h.title != nil ? 40 : 68 }

    var body: some View {
        if let title = hit.title { named(title) } else { media }
    }

    /// A session, project or board: one line, no picture.
    private func named(_ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 22)
            Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(hit.kind == "session" ? hit.text ?? "" : hit.kind == "project" ? "Project" : "Board")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.hover : .clear))
        .contentShape(Rectangle())
    }

    private var media: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.hover)
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: icon).foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 88, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.path.lastPathComponent).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if (hit.kind == "video" || hit.kind == "speech"), hit.start > 0 {
                        Text(Self.time(hit.start)).font(Theme.sans(11).monospacedDigit()).foregroundStyle(Theme.accentInk)
                    }
                }
                Text(place).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                if let t = hit.text {
                    Text("“\(t)”").font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .task(id: hit.id) { thumb = await Self.thumbnail(hit) }
    }

    private var icon: String {
        switch hit.kind {
        case "image": return "photo"
        case "speech": return "text.quote"
        case "script": return "doc.text"
        case "session": return "rectangle.stack"
        case "project": return "folder"
        case "board": return "square.grid.2x2"
        default: return "film"
        }
    }

    /// "Weekly Challenge › Sign in with ChatGPT › edits" or "B-roll › Desk work".
    private var place: String {
        let rel = hit.path.deletingLastPathComponent().path.replacingOccurrences(of: root.path + "/", with: "")
        let parts = rel.split(separator: "/").map(String.init)
        if parts.first == "_library" { return (["B-roll"] + parts.dropFirst(2).map { $0.replacingOccurrences(of: #"^\d+ "#, with: "", options: .regularExpression) }).joined(separator: " › ") }
        return parts.map { $0.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}-"#, with: "", options: .regularExpression) }.joined(separator: " › ")
    }

    static func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    static func thumbnail(_ hit: MediaSearch.Hit) async -> NSImage? {
        let ext = hit.path.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "webp"].contains(ext) {
            return await Task.detached { NSImage(contentsOf: hit.path) }.value
        }
        guard ["mov", "mp4", "m4v"].contains(ext) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: hit.path))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: hit.start + (hit.kind == "video" ? 4 : 0.5), preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Settings › Search

struct SearchPage: View {
    private var search = MediaSearch.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search").font(Theme.display(26)).foregroundStyle(Theme.ink)
                    Text("Press ⌘K and describe what you look for: \"hands typing\", \"walking outside\", \"where I talk about pricing\". Takes finds clips by what they show, stills, and the words in transcripts and scripts. It runs on this Mac. Nothing leaves it.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon).font(.system(size: 15)).foregroundStyle(search.model == .ready ? Theme.accent : Theme.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                            Text(search.statusLine).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        buttons
                    }
                    if case .downloading(let p) = search.model { ProgressView(value: p).tint(Theme.accent) }
                    if search.model == .ready, search.indexing, search.indexTotal > 0 {
                        ProgressView(value: Double(search.indexDone), total: Double(search.indexTotal)).tint(Theme.accent)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                VStack(alignment: .leading, spacing: 8) {
                    Text("About the model").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("EmbeddingGemma 2 by Google DeepMind (Apache 2.0), about 510 MB. Takes downloads it once in the background, never over Low Data Mode, and checks every file. The index of your library is a few MB in _library/search.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
    }

    private var icon: String {
        switch search.model {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "pause.circle"
        }
    }

    private var title: String {
        switch search.model {
        case .ready: return "Search by meaning is on"
        case .downloading: return "Getting the search model"
        case .unsupported: return "Not in this build"
        case .failed: return "The download stopped"
        default: return "Search by meaning is off"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch search.model {
        case .downloading, .waiting: Button("Pause") { search.pause() }
        case .paused, .missing, .failed: Button("Download") { search.download() }
        case .ready:
            HStack {
                Button("Index Now") { search.reindex() }.disabled(search.indexing)
                Button("Remove") { search.remove() }
            }
        case .unsupported: EmptyView()
        }
    }
}
