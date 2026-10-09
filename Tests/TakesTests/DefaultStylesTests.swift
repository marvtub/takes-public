import Foundation
import Testing
@testable import Takes

/// The styles Takes ships (styles/ in the repo) and how they reach the library (StyleLib.seed).
@MainActor
struct DefaultStylesTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let shipped = repo.appending(path: "styles")

    @Test func eachShippedStyleIsComplete() throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: Self.shipped.path).filter { !$0.hasPrefix(".") }
        #expect(names.contains("Magazine"))
        for n in names {
            let d = Self.shipped.appending(path: n)
            for f in ["README.md", "tokens.json", "style.json", "preview.mp4", "preview.png"] {
                #expect(fm.fileExists(atPath: d.appending(path: f).path), "\(n) has no \(f)")
            }
            let tokens = StyleLib.json(d.appending(path: "tokens.json"))
            #expect(tokens["color"] != nil, "\(n): tokens.json has no colors")
            // Fonts ship with their license.
            let fonts = (try? fm.contentsOfDirectory(atPath: d.appending(path: "fonts").path)) ?? []
            if fonts.contains(where: { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") }) {
                #expect(fonts.contains { $0.hasPrefix("OFL") }, "\(n): fonts without a license file")
            }
            // Every source part named in assets.json is there.
            for (asset, _) in StyleLib.json(d.appending(path: "assets.json")) {
                #expect(fm.fileExists(atPath: d.appending(path: asset).path), "\(n): \(asset) is missing")
            }
        }
    }

    @Test func seedCopiesOnceAndKeepsYours() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "seed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let shipped = tmp.appending(path: "shipped"), root = tmp.appending(path: "lib")
        for n in ["Magazine", "Swiss"] {
            try fm.createDirectory(at: shipped.appending(path: n), withIntermediateDirectories: true)
            try "shipped".write(to: shipped.appending(path: "\(n)/README.md"), atomically: true, encoding: .utf8)
        }
        // You already have a Magazine of your own.
        try fm.createDirectory(at: StyleLib.style("Magazine", root: root), withIntermediateDirectories: true)
        try "mine".write(to: StyleLib.style("Magazine", root: root).appending(path: "README.md"), atomically: true, encoding: .utf8)
        let defaults = try #require(UserDefaults(suiteName: "seed-\(UUID().uuidString)"))

        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults) == ["Swiss"])
        #expect(try String(contentsOf: StyleLib.style("Magazine", root: root).appending(path: "README.md"), encoding: .utf8) == "mine")
        #expect(StyleLib.styleNames(root: root) == ["Magazine", "Swiss"])

        // Deleted styles stay deleted.
        try fm.removeItem(at: StyleLib.style("Swiss", root: root))
        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults).isEmpty)
        #expect(StyleLib.styleNames(root: root) == ["Magazine"])

        // Another library folder gets them.
        let other = tmp.appending(path: "other")
        #expect(StyleLib.seed(from: shipped, root: other, defaults: defaults) == ["Magazine", "Swiss"])
    }
}
