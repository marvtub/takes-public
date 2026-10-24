import AppKit
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct HelpTests {
    @Test func everyTabHasItsShortcut() {
        let session = HelpCenter.groups.first { $0.title == "Session" }!.items
        #expect(session.count == SessionMode.allCases.count)
        for m in SessionMode.allCases {
            #expect(session.contains(HelpCenter.Shortcut(name: m.title, keys: "⌘\(m.shortcut)")))
        }
    }

    @Test func guideFollowsTheHeaderTabs() {
        #expect(HelpCenter.steps.map(\.mode) == SessionMode.tabs)
    }

    @Test func shortcutsAreNotListedTwice() {
        let keys = HelpCenter.groups.flatMap(\.items).map(\.keys)
        #expect(Set(keys).count == keys.count)
    }

    /// Both pages in light and dark, to look at: `TAKES_SNAPSHOT=/dir ./test.sh --filter Help`.
    @Test func pages() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let app = AppModel()
        revealAtOnce = true
        defer { revealAtOnce = false }
        for page in HelpCenter.Page.allCases {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance.current = NSAppearance(named: appearance)
                HelpCenter.shared.page = page
                let v = HelpView().environment(app).foregroundStyle(Theme.ink)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let r = ImageRenderer(content: v)
                r.scale = 2
                let cg = try #require(r.cgImage)
                let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: dir).appending(path: "help-\(page.rawValue.lowercased())-\(name).png"))
            }
        }
        HelpCenter.shared.page = .guide
    }
}
