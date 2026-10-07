// takes-embed: finds clips, stills and words in a Takes library by meaning, on this Mac.
//
//   takes-embed serve  --models DIR --root DIR           JSON lines on stdin and stdout (the app)
//   takes-embed search --models DIR --root DIR [--limit N] [--kind video,image,speech,script] QUERY
//                                                        one search, JSON on stdout (the MCP)
//   takes-embed index  --models DIR --root DIR           one index run, progress on stdout
//
// Serve ops: {"id":1,"op":"index"} indexes new and changed files and reports
// {"event":"progress",...}; {"id":2,"op":"search","query":"...","limit":40,"kinds":[...]};
// {"op":"stop"} ends an index run after the current file; {"op":"status"}.
//
// What it indexes (EmbeddingGemma 2 puts all of it in one vector space):
//   video   one frame every 8 s of each take, b-roll clip, upload and the newest version of each edit
//   image   stills, thumbnails, uploads
//   speech  ~30-word pieces of each <video stem>.words.json, with their times
//   script  the paragraphs of each session's script.md
// The index is <root>/_library/search/index.json. A file is indexed again only when it changes.
import AVFoundation
import Accelerate
import CoreGraphics
import EmbeddingGemma2
import Foundation
import ImageIO
import MLX

let segment = 8.0
let maxFrames = 450                   // one hour of footage per file
let videoExts: Set<String> = ["mov", "mp4", "m4v"]
let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
let skipDirs: Set<String> = ["storyboard", "history", "comments", "posts", "variants", "voice", "node_modules"]

// MARK: - Output

let outLock = NSLock()
func emit(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    outLock.lock(); FileHandle.standardOutput.write(data); outLock.unlock()
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Index file

struct Item: Codable {
    var start: Double
    var end: Double
    var kind: String
    var text: String?
    var v: String          // base64 of 768 Float16
}

struct Entry: Codable {
    var mtime: Double
    var size: Int
    var items: [Item]
}

struct IndexFile: Codable {
    var version = 1
    var model = "embeddinggemma-2-q8"
    var files: [String: Entry] = [:]
}

func pack(_ v: [Float]) -> String {
    var half = v.map { Float16($0) }
    return Data(bytes: &half, count: half.count * 2).base64EncodedString()
}

func unpack(_ s: String) -> [Float]? {
    guard let d = Data(base64Encoded: s), d.count == 768 * 2 else { return nil }
    return d.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
}

// MARK: - Library walk

struct Source {
    let rel: String
    let url: URL
    let kind: String       // video, image, words, script
    let mtime: Double
    let size: Int
}

/// The files to index, newest edit version only (an edit has many -vN copies).
func sources(root: URL) -> [Source] {
    let fm = FileManager.default
    guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var out: [Source] = []
    var edits: [String: (Int, Source)] = [:]
    let base = root.standardizedFileURL.path
    for case let url as URL in walk {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
        let parts = rel.split(separator: "/").map(String.init)
        if values?.isDirectory == true {
            let name = url.lastPathComponent
            // In _library only the b-roll counts. Elsewhere skip app folders that hold no footage.
            if parts.first == "_library" && parts.count >= 2 && parts[1] != "broll" { walk.skipDescendants() }
            if skipDirs.contains(name) || name.hasPrefix(".") { walk.skipDescendants() }
            continue
        }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        var kind: String?
        if videoExts.contains(ext) { kind = "video" }
        else if imageExts.contains(ext) { kind = "image" }
        else if name.hasSuffix(".words.json") { kind = "words" }
        else if name == "script.md" && parts.count == 3 { kind = "script" }
        guard let kind else { continue }
        let s = Source(rel: rel, url: url, kind: kind,
                       mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0, size: values?.fileSize ?? 0)
        // edits/<slug>-v3.mp4: keep the highest version of each slug.
        if kind == "video", parts.count >= 2, parts[parts.count - 2] == "edits" {
            let stem = (name as NSString).deletingPathExtension
            if let r = stem.range(of: #"-v(\d+)$"#, options: .regularExpression), let n = Int(stem[r].dropFirst(2)) {
                let key = (rel as NSString).deletingLastPathComponent + "/" + stem[..<r.lowerBound]
                if let have = edits[key], have.0 >= n { continue }
                edits[key] = (n, s)
                continue
            }
        }
        out.append(s)
    }
    let videos = out.filter { $0.kind == "video" } + edits.values.map(\.1)
    // A transcript counts only when its video does (old edit versions keep their words.json).
    let kept = Set(videos.map { ($0.rel as NSString).deletingPathExtension })
    return out.filter { $0.kind != "words" || kept.contains(String($0.rel.dropLast(".words.json".count))) } + edits.values.map(\.1)
}

/// The video a words.json belongs to, as a path relative to the root.
func videoFor(words rel: String, root: URL) -> String? {
    let stem = String(rel.dropLast(".words.json".count))
    for ext in ["mp4", "mov", "m4v"] where FileManager.default.fileExists(atPath: root.appending(path: stem + "." + ext).path) {
        return stem + "." + ext
    }
    return nil
}

/// Words with times from Whisper or Scribe JSON (same shapes as transcript_words in takes_mcp.py).
func words(_ url: URL) -> [(Double, Double, String)] {
    guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var list: [Any] = []
    if let d = json as? [String: Any] {
        list = d["words"] as? [Any] ?? []
        for seg in d["segments"] as? [[String: Any]] ?? [] {
            list += seg["words"] as? [Any] ?? [["text": seg["text"] ?? "", "start": seg["start"] ?? 0, "end": seg["end"] ?? 0]]
        }
    } else if let a = json as? [Any] {
        list = a
    }
    func num(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }
    return list.compactMap { w in
        if let a = w as? [Any], a.count >= 2, let s = num(a[1]) {
            let t = "\(a[0])".trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (s, a.count > 2 ? num(a[2]) ?? s : s, t)
        }
        if let d = w as? [String: Any], let s = num(d["start"]) {
            let t = ((d["word"] ?? d["text"]) as? String ?? "").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : (s, num(d["end"]) ?? s, t)
        }
        return nil
    }
}

// MARK: - Pixels

/// Opaque RGB8 from a CGImage: transparent parts go on white (the model refuses alpha).
func rgb(_ image: CGImage) throws -> RGBImage {
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    rgba.withUnsafeMutableBytes { p in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var out = [UInt8](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) { out[i * 3] = rgba[i * 4]; out[i * 3 + 1] = rgba[i * 4 + 1]; out[i * 3 + 2] = rgba[i * 4 + 2] }
    return try RGBImage(width: w, height: h, bytes: out)
}

/// A still, turned upright and at most 1024 px.
func loadImage(_ url: URL) throws -> RGBImage {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 1024]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        throw EmbeddingError.invalid("Cannot read image")
    }
    return try rgb(cg)
}

// MARK: - Engine

actor Engine {
    let root: URL
    let models: URL
    var encoder: TextEncoder?
    var visionOn = false
    var index = IndexFile()
    var dirty = false
    var stopRequested = false
    var indexing = false
    // The search matrix, rebuilt after the index changes.
    var matrix: [Float] = []
    var rows: [(file: String, item: Item)] = []
    var matrixStale = true

    init(root: URL, models: URL) {
        self.root = root
        self.models = models
        if let d = try? Data(contentsOf: Self.indexURL(root)), let f = try? JSONDecoder().decode(IndexFile.self, from: d) {
            index = f
        }
    }

    static func indexURL(_ root: URL) -> URL { root.appending(path: "_library/search/index.json") }

    func textEncoder() async throws -> TextEncoder {
        if let encoder { return encoder }
        let e = try await TextEncoder(directory: models.appending(path: "text-q8"))
        encoder = e
        return e
    }

    func visionEncoder() async throws -> TextEncoder {
        let e = try await textEncoder()
        if !visionOn {
            try await e.enableVision(directory: models.appending(path: "vision-q8"))
            visionOn = true
        }
        return e
    }

    func save() {
        guard dirty else { return }
        let url = Self.indexURL(root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: url, options: .atomic) }
        dirty = false
    }

    func stop() { stopRequested = true }

    func status() -> [String: Any] {
        ["files": index.files.count, "items": index.files.values.reduce(0) { $0 + $1.items.count }, "indexing": indexing]
    }

    // MARK: Index

    func runIndex(id: Any?) async {
        guard !indexing else { emit(["id": id ?? NSNull(), "ok": false, "error": "Already indexing"]); return }
        indexing = true; stopRequested = false
        defer { indexing = false }
        let all = sources(root: root)
        let live = Set(all.map { $0.kind == "words" ? (videoFor(words: $0.rel, root: root) ?? "") + "#words" : $0.rel })
        // Drop files that are gone.
        for key in index.files.keys where !live.contains(key) { index.files[key] = nil; dirty = true; matrixStale = true }
        let todo = all.filter { s in
            let key = s.kind == "words" ? (videoFor(words: s.rel, root: root) ?? "") + "#words" : s.rel
            if s.kind == "words" && key == "#words" { return false }
            guard let e = index.files[key] else { return true }
            return e.mtime != s.mtime || e.size != s.size
        }
        // Text first (fast), then stills, then video.
        let order = ["script": 0, "words": 1, "image": 2, "video": 3]
        let queue = todo.sorted { (order[$0.kind] ?? 9, $0.rel) < (order[$1.kind] ?? 9, $1.rel) }
        var done = 0, lastSave = Date()
        emit(["event": "progress", "done": 0, "total": queue.count])
        for s in queue {
            if stopRequested { break }
            do {
                let (key, items) = try await embed(s)
                index.files[key] = Entry(mtime: s.mtime, size: s.size, items: items)
                dirty = true; matrixStale = true
            } catch {
                // An unreadable file gets an empty entry, so it is not tried again until it changes.
                let key = s.kind == "words" ? (videoFor(words: s.rel, root: root) ?? s.rel) + "#words" : s.rel
                index.files[key] = Entry(mtime: s.mtime, size: s.size, items: [])
                dirty = true
            }
            done += 1
            emit(["event": "progress", "done": done, "total": queue.count, "file": s.rel])
            if Date().timeIntervalSince(lastSave) > 30 { save(); lastSave = Date() }
            Memory.clearCache()
        }
        save()
        emit(["id": id ?? NSNull(), "ok": true, "indexed": done, "stopped": stopRequested, "files": index.files.count])
    }

    func embed(_ s: Source) async throws -> (String, [Item]) {
        switch s.kind {
        case "script":
            let text = (try? String(contentsOf: s.url, encoding: .utf8)) ?? ""
            let paras = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 20 }
            let vecs = try await documents(paras)
            return (s.rel, zip(paras, vecs).map { Item(start: 0, end: 0, kind: "script", text: String($0.prefix(400)), v: pack($1)) })
        case "words":
            guard let video = videoFor(words: s.rel, root: root) else { throw EmbeddingError.invalid("No video") }
            let ws = words(s.url)
            var chunks: [(Double, Double, String)] = []
            var i = 0
            while i < ws.count {
                // A short tail joins the piece before it: a one-word piece matches anything.
                let take = ws.count - i < 40 ? ws.count - i : 30
                let part = ws[i..<(i + take)]
                chunks.append((part.first!.0, part.last!.1, part.map(\.2).joined(separator: " ")))
                i += take
            }
            let vecs = try await documents(chunks.map(\.2))
            return (video + "#words", zip(chunks, vecs).map { Item(start: $0.0, end: $0.1, kind: "speech", text: $0.2, v: pack($1)) })
        case "image":
            let e = try await visionEncoder()
            let img = try ImageProcessor.prepare(loadImage(s.url), maxSoftTokens: 280)
            return (s.rel, [Item(start: 0, end: 0, kind: "image", text: nil, v: pack(try await e.encodeImage(img)))])
        default:
            return (s.rel, try await frames(s.url))
        }
    }

    func documents(_ texts: [String]) async throws -> [[Float]] {
        let e = try await textEncoder()
        var out: [[Float]] = []
        var i = 0
        while i < texts.count {
            out += try await e.encode(Array(texts[i..<min(texts.count, i + 8)]), task: .document)
            i += 8
        }
        return out
    }

    func frames(_ url: URL) async throws -> [Item] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 896, height: 896)
        let tol = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let e = try await visionEncoder()
        var items: [Item] = []
        var start = 0.0
        while start < duration && items.count < maxFrames {
            if stopRequested { throw CancellationError() }
            let end = min(duration, start + segment)
            let mid = (start + end) / 2
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: mid, preferredTimescale: 600)) {
                let img = try ImageProcessor.prepare(rgb(cg), maxSoftTokens: 280)
                items.append(Item(start: start, end: end, kind: "video", text: nil, v: pack(try await e.encodeImage(img))))
            }
            start += segment
        }
        return items
    }

    // MARK: Search

    func rebuild() {
        guard matrixStale else { return }
        rows = []; matrix = []
        for (file, entry) in index.files {
            for item in entry.items {
                guard let v = unpack(item.v) else { continue }
                rows.append((file, item)); matrix += v
            }
        }
        matrixStale = false
    }

    func search(_ query: String, limit: Int, kinds: Set<String>?) async throws -> [[String: Any]] {
        rebuild()
        guard !rows.isEmpty else { return [] }
        let q = try await textEncoder().encode([query], task: .search)[0]
        var scores = [Float](repeating: 0, count: rows.count)
        // scores = matrix (rows x 768) * q
        vDSP_mmul(matrix, 1, q, 1, &scores, 1, vDSP_Length(rows.count), 1, 768)
        // Text-to-text scores run higher than text-to-picture scores, so rank by how far each hit
        // stands out within its own kind (z-score), not by the raw number.
        var byKind: [String: [Float]] = [:]
        for (i, r) in rows.enumerated() { byKind[r.item.kind, default: []].append(scores[i]) }
        var stats: [String: (Float, Float)] = [:]
        for (k, xs) in byKind {
            let mean = xs.reduce(0, +) / Float(xs.count)
            let sd = sqrt(xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, xs.count - 1)))
            stats[k] = (mean, max(sd, 0.01))
        }
        var best: [String: (Float, Int)] = [:]
        for (i, r) in rows.enumerated() {
            if let kinds, !kinds.contains(r.item.kind) { continue }
            let (mean, sd) = stats[r.item.kind]!
            let z = (scores[i] - mean) / sd
            let file = r.file.hasSuffix("#words") ? String(r.file.dropLast(6)) : r.file
            if best[file].map({ z > $0.0 }) ?? true { best[file] = (z, i) }
        }
        return best.sorted { $0.value.0 > $1.value.0 }.prefix(limit).map { file, hit in
            let item = rows[hit.1].item
            var out: [String: Any] = ["path": root.appending(path: file).path, "file": file, "kind": item.kind,
                                      "start": item.start, "end": item.end,
                                      "score": Double(scores[hit.1]), "rank": Double(hit.0)]
            if let t = item.text { out["text"] = t }
            return out
        }
    }
}

// MARK: - Main

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let argv = CommandLine.arguments
guard argv.count >= 2, let modelsPath = arg("--models"), let rootPath = arg("--root") else {
    fail("Usage: takes-embed serve|search|index --models DIR --root DIR [--limit N] [--kind k,k] [QUERY]")
}
Memory.cacheLimit = 64 * 1024 * 1024
let engine = Engine(root: URL(fileURLWithPath: rootPath), models: URL(fileURLWithPath: modelsPath))
guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelsPath).appending(path: "text-q8/model.safetensors").path) else {
    fail("The search model is not downloaded yet (Takes › Settings › Search).")
}

switch argv[1] {
case "search":
    let flags: Set<String> = ["--models", "--root", "--limit", "--kind"]
    var words: [String] = []
    var i = 2
    while i < argv.count { if flags.contains(argv[i]) { i += 2 } else { words.append(argv[i]); i += 1 } }
    let query = words.joined(separator: " ")
    guard !query.isEmpty else { fail("No query") }
    let kinds = arg("--kind").map { Set($0.split(separator: ",").map(String.init)) }
    let limit = Int(arg("--limit") ?? "") ?? 20
    let done = DispatchSemaphore(value: 0)
    Task {
        do { emit(["results": try await engine.search(query, limit: limit, kinds: kinds), "status": await engine.status()]) }
        catch { fail("\(error)") }
        done.signal()
    }
    done.wait()
case "index":
    let done = DispatchSemaphore(value: 0)
    Task { await engine.runIndex(id: nil); done.signal() }
    done.wait()
case "serve":
    emit(["event": "ready"])
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let id = msg["id"]
        switch msg["op"] as? String {
        case "index":
            Task { await engine.runIndex(id: id) }
        case "stop":
            Task { await engine.stop() }
        case "status":
            Task { var s = await engine.status(); s["id"] = id ?? NSNull(); emit(s) }
        case "search":
            let query = msg["query"] as? String ?? ""
            let limit = msg["limit"] as? Int ?? 40
            let kinds = (msg["kinds"] as? [String]).map(Set.init)
            Task {
                do { emit(["id": id ?? NSNull(), "results": try await engine.search(query, limit: limit, kinds: kinds)]) }
                catch { emit(["id": id ?? NSNull(), "error": "\(error)"]) }
            }
        default:
            emit(["id": id ?? NSNull(), "error": "Unknown op"])
        }
    }
    // stdin closed: Takes quit. Save what is done and stop.
    let done = DispatchSemaphore(value: 0)
    Task { await engine.stop(); await engine.save(); done.signal() }
    done.wait()
default:
    fail("Unknown command \(argv[1])")
}
