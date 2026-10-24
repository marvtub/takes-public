import Foundation

/// Install attribution (2026-10-20). When someone downloads Takes from a gettakes.app link that
/// named its source (a post with ?ref=hn, another site), the site makes a random 10-character code
/// for that download (gettakes-site functions/lib/ref.js) and puts it in one of two places:
/// - the DMG's file name, `Takes-<code>.dmg` (a browser download), or
/// - `install-ref` in Application Support/Takes, which install.sh writes (the curl command).
/// The first update check of a first install sends the code once (`Updater.checkURL`); the site
/// swaps it for the source. Nothing else goes with it: not the file names of other disk images,
/// not a path, no ID. The code says nothing about the person; it links one download to one install.
enum InstallRef {
    /// install.sh writes the code here; the check that sends it deletes it.
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Takes/install-ref")
    }

    /// The site's alphabet: lowercase letters and digits without 0, 1, l and o.
    static func isCode(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { "abcdefghijkmnpqrstuvwxyz23456789".contains($0) }
    }

    /// The code in a disk image's file name: "Takes-k3x9mp2qra.dmg", or "Takes-k3x9mp2qra (1).dmg"
    /// when the browser had one with that name already.
    static func code(imagePath: String) -> String? {
        let name = (imagePath as NSString).lastPathComponent
        guard name.hasPrefix("Takes-"), name.hasSuffix(".dmg") else { return nil }
        var core = String(name.dropFirst(6).dropLast(4))
        if let r = core.range(of: #" \(\d+\)$"#, options: .regularExpression) { core.removeSubrange(r) }
        return isCode(core) ? core : nil
    }

    /// The code from `hdiutil info -plist`: the first mounted image named like a Takes download.
    /// People open Takes the first time while its disk image is still mounted, most of the time.
    static func code(hdiutilInfo data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        return images.lazy.compactMap { ($0["image-path"] as? String).flatMap(code(imagePath:)) }.first
    }

    /// The code from install.sh's file, else from a mounted Takes disk image; nil when neither has one.
    static func find(file: URL = InstallRef.file, hdiutil: () -> Data? = InstallRef.hdiutilInfo) -> String? {
        if let s = try? String(contentsOf: file, encoding: .utf8) {
            let code = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if isCode(code) { return code }
        }
        return hdiutil().flatMap(code(hdiutilInfo:))
    }

    static func hdiutilInfo() -> Data? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
