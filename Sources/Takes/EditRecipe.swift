import Foundation

/// An edit's recipe (2026-10-11): `edits/<name>-vN.recipe.json` beside `edits/<name>-vN.mp4`, written once
/// by the MCP's publish_edit (same format as the edit recipes section of mcp/takes_mcp.py). It says how
/// the version was made: the cut, the voice, the picture layers, the music, the cover. The next version
/// starts from it. The app reads its `note` (the line under the edit's tile) and its `cover`, and the
/// Cover button writes the recipe of the version it makes.
enum EditRecipe {
    static let suffix = ".recipe.json"

    /// edits/x-v5.mp4 → edits/x-v5.recipe.json
    static func url(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("recipe.json")
    }

    // MARK: Export for Resolve / Premiere (2026-10-18)

    /// What "Export for Resolve / Premiere…" writes next to a version (export_edit in takes_mcp.py): the
    /// timeline for Resolve and Final Cut, the one for Premiere, and the picture cut as an EDL. Hidden on the
    /// Assets tab like the recipe; Cleanup trashes them with their video.
    static let exportSuffixes = [".fcpxml", ".premiere.xml", ".edl"]
    static let exportTitle = "Export for Resolve / Premiere…"

    /// The row on an edit tile's right-click menu (Assets tab).
    @MenuBuilder static func exportRow(_ action: @escaping () -> Void) -> [MenuItem] {
        MenuButton(exportTitle, icon: "square.and.arrow.up", action: action)
    }

    static func isExport(_ name: String) -> Bool { exportSuffixes.contains { name.hasSuffix($0) } }

    /// edits/x-v5.mp4 → edits/x-v5.fcpxml
    static func exportURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("fcpxml")
    }

    /// A version in edits/ that has its recipe: the export needs the cut list.
    static func canExport(_ video: URL, group: String) -> Bool {
        group == "edits" && FileManager.default.fileExists(atPath: url(for: video).path)
    }

    enum Exported: Hashable {
        case done(URL)
        case failed(String)
    }

    /// The server's answer as the app shows it.
    static func exported(_ json: [String: Any], session: URL) -> Exported {
        if let file = json["fcpxml"] as? String { return .done(session.appending(path: file)) }
        let why = (json["error"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return .failed(why.isEmpty ? "The export gave no answer." : why)
    }

    /// One line for the toast, and its icon.
    static func toast(_ e: Exported) -> String {
        switch e {
        case .done(let u): return "Exported \(u.lastPathComponent) for Resolve / Premiere"
        case .failed(let why): return "Takes could not export it. \(why)"
        }
    }

    static func toastIcon(_ e: Exported) -> String {
        if case .done = e { return "checkmark" }
        return "exclamationmark.triangle"
    }

    static let exportingIcon = "square.and.arrow.up"

    /// Runs `takes_mcp.py --export-edit <session> <edits/x-vN.mp4>` off the main thread. It writes the
    /// three files in a second or two (the first export of a take also writes its sound as a WAV).
    nonisolated static func export(_ video: URL, session: URL) async -> Exported {
        guard let script = Bundle.main.url(forResource: "takes_mcp", withExtension: "py") else {
            return .failed("The takes server is missing from the app.")
        }
        let rel = "edits/" + video.lastPathComponent
        let json: [String: Any] = await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/python3")
            p.arguments = [script.path, "--export-edit", session.path, rel]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Setup.localBin):" + (env["PATH"] ?? "/usr/bin:/bin")
            if let root = UserDefaults.standard.string(forKey: "root") { env["TAKES_ROOT"] = root }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return ["error": "Could not start the takes server."] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }.value
        return exported(json, session: session)
    }

    /// The recipe as JSON, nil when there is none or it does not read.
    static func read(_ video: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(for: video)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated(unsafe) private static var notes: [String: (Date, String?)] = [:]
    private static let lock = NSLock()

    /// What changed in this version, in one line ("Music softer."). Read once per file and change.
    static func note(for video: URL) -> String? {
        let file = url(for: video)
        guard let modified = Store.modified(file) else { return nil }
        lock.lock()
        let hit = notes[file.path]
        lock.unlock()
        if let hit, hit.0 == modified { return hit.1 }
        let note = (read(video)?["note"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        lock.lock()
        notes[file.path] = (modified, note)
        lock.unlock()
        return note
    }

    /// The cover the recipe baked in: the image (relative to the session) and how long it shows.
    static func cover(for video: URL) -> (image: String, seconds: Double)? {
        guard let c = read(video)?["cover"] as? [String: Any], let image = c["image"] as? String else { return nil }
        return (image, (c["seconds"] as? NSNumber)?.doubleValue ?? Cover.seconds)
    }

    /// The recipe of `out`, a version the Cover button made from `source`: the source's recipe with a
    /// new cover (nil: none), the source as parent. No recipe at the source: nothing is written, since
    /// the app does not know how the source was made.
    static func withCover(source: URL, image: String?, seconds: Double = Cover.seconds, out: URL, session: URL) {
        guard var r = read(source) else { return }
        let rel = { (u: URL) -> String in
            let real = { (x: URL) in x.standardizedFileURL.resolvingSymlinksInPath().path }
            return String(real(u).dropFirst(real(session).count + 1))
        }
        r["parent"] = rel(source)
        r["edit"] = rel(out)
        r["cover"] = image.map { ["image": $0, "seconds": seconds] as [String: Any] } ?? NSNull()
        r["by"] = "app"
        r["note"] = image.map { "New cover: thumbnail \(($0 as NSString).lastPathComponent.replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression))" } ?? "Cover removed"
        r["made"] = ISO8601DateFormatter().string(from: Date())
        for k in ["commands", "render_id", "checks", "fixed", "accepted", "src", "src_skipped"] { r.removeValue(forKey: k) }
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url(for: out), options: .atomic)
    }
}
