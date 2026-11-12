import Foundation

/// The raea engine (Render Anything Engine, github.com/shinyobjectz/raea) that the Raea pack's
/// skills run (2026-11-05). It renders React/TypeScript compositions on the GPU without a browser:
/// in the user's test, 19 s of a 1080x1920 take with captions took 4.3 s against HyperFrames' 19.7 s,
/// and it draws real 3D. It cannot render transparent layers, so it makes the whole picture.
///
/// Takes downloads the newest release from raea's own GitHub when the pack is switched on, checked
/// against its SHA-256, and never ships a copy: raea is FSL-1.1 (each user may run it; a product
/// may not bundle it). It goes where raea's own installer puts it (~/.raea, linked from
/// ~/.local/bin), so the skills and `curl raea.io/install | sh` find the same copy. A marker file
/// says Takes put it there; an install the user made stays theirs.
enum RaeaEngine {
    static let repo = "shinyobjectz/raea"
    static let marker = ".takes-engine"
    nonisolated static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".raea") }

    /// The version in an install, from share/raea/VERSION. Nil: none there.
    nonisolated static func version(in home: URL = home) -> String? {
        (try? String(contentsOf: home.appending(path: "share/raea/VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Takes installed this copy (so it may update and remove it).
    nonisolated static func ours(_ home: URL = home) -> Bool {
        FileManager.default.fileExists(atPath: home.appending(path: marker).path)
    }

    /// "v0.1.0-canary.2" from the releases list (newest first, canaries included).
    nonisolated static func tag(fromReleases data: Data) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.first?["tag_name"] as? String
    }

    /// Installs or updates the engine. Leaves a copy the user installed alone, and does nothing when
    /// the newest release is already here.
    nonisolated static func install(home: URL = home, bin: String = Setup.localBin) async throws {
        #if !arch(arm64)
        throw Setup.Failure("Raea needs a Mac with Apple Silicon.")
        #else
        let fm = FileManager.default
        if fm.fileExists(atPath: home.path), !ours(home) { return }
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1")!
        let (list, _) = try await URLSession.shared.data(from: api)
        guard let tag = tag(fromReleases: list) else { throw Setup.Failure("Could not find a raea release on GitHub.") }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if version(in: home) == v, fm.fileExists(atPath: bin + "/raea") { return }

        let asset = "raea-\(v)-macos-arm64.tar.gz"
        let url = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(asset)")!
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Setup.Failure("The raea download failed. Try again later.") }
        let (sum, _) = try await URLSession.shared.data(from: url.appendingPathExtension("sha256"))
        let want = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let (_, got) = Setup.run("/usr/bin/shasum", ["-a", "256", file.path])
        guard want.count == 64, got.hasPrefix(want) else { throw Setup.Failure("The raea download did not match its checksum.") }

        let tmp = fm.temporaryDirectory.appending(path: "takes-raea-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard Setup.run("/usr/bin/tar", ["-xzf", file.path, "-C", tmp.path]).0 else { throw Setup.Failure("Could not unpack raea.") }
        let unpacked = tmp.appending(path: "raea")
        guard fm.isExecutableFile(atPath: unpacked.appending(path: "bin/raea").path) else { throw Setup.Failure("The raea download has no engine in it.") }
        try "takes".write(to: unpacked.appending(path: marker), atomically: true, encoding: .utf8)
        _ = Setup.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked.path])
        // A release's files go together: the old install goes whole.
        if fm.fileExists(atPath: home.path) { try fm.removeItem(at: home) }
        try fm.createDirectory(at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: unpacked, to: home)
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: bin + "/raea")
        try fm.createSymbolicLink(atPath: bin + "/raea", withDestinationPath: home.appending(path: "bin/raea").path)
        #endif
    }

    /// The engine Takes installed goes to the Trash, with its link. The user's own stays.
    nonisolated static func remove(home: URL = home, bin: String = Setup.localBin) throws {
        guard ours(home) else { return }
        let fm = FileManager.default
        let link = bin + "/raea"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest.hasPrefix(home.path) { try? fm.removeItem(atPath: link) }
        try fm.trashItem(at: home, resultingItemURL: nil)
    }
}
