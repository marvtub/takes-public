import Foundation
import Testing
@testable import Takes

/// Install attribution (2026-10-20): the code of a download with a source goes once, with the first
/// install's update check, and nothing else goes with it.
struct InstallRefTests {
    @Test func aCodeIsTheSitesTenCharacters() {
        #expect(InstallRef.isCode("k3x9mp2qra"))
        for bad in ["", "k3x9mp2qr", "k3x9mp2qrab", "K3X9MP2QRA", "k3x9mp2qr0", "k3x9mp2qrl", "k3x9mp2q/a"] {
            #expect(!InstallRef.isCode(bad), "\(bad)")
        }
    }

    @Test func theCodeComesOnlyFromATakesDownloadName() {
        #expect(InstallRef.code(imagePath: "/Users/x/Downloads/Takes-k3x9mp2qra.dmg") == "k3x9mp2qra")
        #expect(InstallRef.code(imagePath: "/Users/x/Downloads/Takes-k3x9mp2qra (2).dmg") == "k3x9mp2qra")
        #expect(InstallRef.code(imagePath: "/Users/x/Downloads/Takes.dmg") == nil)
        #expect(InstallRef.code(imagePath: "/Users/x/Downloads/Other-k3x9mp2qra.dmg") == nil)
        #expect(InstallRef.code(imagePath: "/Users/x/Downloads/Takes-k3x9mp2qra.zip") == nil)
    }

    @Test func hdiutilGivesTheFirstTakesImageAndNothingElse() throws {
        let plist: [String: Any] = ["images": [
            ["image-path": "/Users/x/Downloads/Private Stuff.dmg", "system-entities": [["mount-point": "/Volumes/Private"]]],
            ["image-path": "/Users/x/Downloads/Takes-k3x9mp2qra.dmg", "system-entities": [["mount-point": "/Volumes/Takes"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(InstallRef.code(hdiutilInfo: data) == "k3x9mp2qra")
        let none = try PropertyListSerialization.data(fromPropertyList: ["images": [["image-path": "/a/Takes.dmg"]]], format: .xml, options: 0)
        #expect(InstallRef.code(hdiutilInfo: none) == nil)
        #expect(InstallRef.code(hdiutilInfo: Data("not a plist".utf8)) == nil)
    }

    @Test func theInstallScriptsFileWinsOverTheDiskImage() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "installref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "install-ref")
        let image = try PropertyListSerialization.data(fromPropertyList: ["images": [["image-path": "/d/Takes-bbbbbbbbbb.dmg"]]], format: .xml, options: 0)
        #expect(InstallRef.find(file: file, hdiutil: { nil }) == nil)
        #expect(InstallRef.find(file: file, hdiutil: { image }) == "bbbbbbbbbb")
        try "aaaaaaaaaa\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(InstallRef.find(file: file, hdiutil: { image }) == "aaaaaaaaaa")
        try "../../etc\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(InstallRef.find(file: file, hdiutil: { nil }) == nil)
    }

    @Test func theCodeGoesOnlyWithAFirstInstallsCheck() throws {
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let first = query(Updater.checkURL(own: "v2026.10.20", phone: false, from: "new", ref: "k3x9mp2qra"))
        #expect(first["ref"] == "k3x9mp2qra")
        #expect(Set(first.keys) == ["v", "os", "phone", "from", "ref"])
        #expect(query(Updater.checkURL(own: "v2026.10.20", phone: false, from: "v2026.10.19", ref: "k3x9mp2qra"))["ref"] == nil)
        #expect(query(Updater.checkURL(own: "v2026.10.20", phone: false, from: nil, ref: "k3x9mp2qra"))["ref"] == nil)
        #expect(query(Updater.checkURL(own: "v2026.10.20", phone: false, from: "new", ref: "not a code"))["ref"] == nil)
    }

    /// gettakes.app writes the code into exactly this line (functions/lib/ref.js withToken).
    @Test func theInstallScriptHasTheSitesPlaceholder() throws {
        // The repo keeps it in scripts/public/; the public copy at its root (export.py).
        let roots = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        let found = roots.flatMap { [$0.appending(path: "scripts/public/install.sh"), $0.appending(path: "install.sh")] }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let script = try String(contentsOf: try #require(found), encoding: .utf8)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.filter { $0 == #"TAKES_INSTALL_TOKEN="""# }.count == 1)
        #expect(script.contains("[[ $TAKES_INSTALL_TOKEN =~ ^[a-km-np-z2-9]{10}$ ]]"))
        #expect(script.contains("install-ref"))
    }
}
