import AppKit
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct AboutTests {
    private func withSnapshotAppearances(_ body: (String) throws -> Void) rethrows {
        let appearance = NSAppearance.current
        defer { NSAppearance.current = appearance }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            try body(name)
        }
    }

    @Test func snapshotsRestoreAppearance() throws {
        let appearance = NSAppearance.current
        defer { NSAppearance.current = appearance }
        let expected = try #require(NSAppearance(named: .aqua))
        NSAppearance.current = expected
        withSnapshotAppearances { _ in }
        #expect(NSAppearance.current === expected)
    }

    /// The note in light and dark, to look at: `TAKES_SNAPSHOT=/dir ./test.sh --filter About`.
    @Test func sheet() throws {
        let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let had = UserDefaults.standard.object(forKey: "about.stars")
        UserDefaults.standard.set(128, forKey: "about.stars")
        defer { UserDefaults.standard.set(had, forKey: "about.stars") }
        try withSnapshotAppearances { name in
            let v = SupportNote().frame(width: 384).padding(28).background(Theme.paper)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            if let dir {
                let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: dir).appending(path: "about-\(name).png"))
            }
        }
    }
}
