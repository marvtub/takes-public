import AppKit
import SwiftUI
import Testing
@testable import Takes

/// Pages with no shots of their own, light and dark, to look at (2026-11-07): each Settings pane but
/// Gemini (it reads the Keychain) and the Styles board on both pages.
/// Off by default: `TAKES_SNAPSHOT=/dir swift test --filter PolishShots`. The Styles board needs
/// TAKES_STYLES_SRC=<a library root>: its _library/styles and _library/effects are cloned (cp -c), never written.
@MainActor @Suite(.serialized)
struct PolishShots {
    static let looks: [(String, ColorScheme, NSAppearance.Name)] = [("light", .light, .aqua), ("dark", .dark, .darkAqua)]

    static func fonts() {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/fonts")
        for f in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }

    static func host(_ v: some View, _ size: CGSize, _ look: NSAppearance.Name, _ dir: String, _ name: String, settle: Double = 1) throws {
        let host = NSHostingView(rootView: AnyView(v.frame(width: size.width, height: size.height)))
        host.appearance = NSAppearance(named: look)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        let end = Date().addingTimeInterval(settle)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
    }

    @Test func settingsPanes() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        Self.fonts()
        let root = FileManager.default.temporaryDirectory.appending(path: "polish-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "polish-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel()
        app.library.setRoot(root)
        _ = app.library.createProject("Inbox")
        for page in SettingsView.SettingsPage.allCases where page != .gemini {
            defaults.set(page.rawValue, forKey: "settingsPage")
            for (name, scheme, look) in Self.looks {
                try Self.host(SettingsView(library: app.library).environment(app).environment(\.colorScheme, scheme).defaultAppStorage(defaults),
                              CGSize(width: 760, height: 560), look, dir, "settings-\(page.rawValue)-\(name)")
            }
        }
    }

    @Test func stylesBoard() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"],
              let src = ProcessInfo.processInfo.environment["TAKES_STYLES_SRC"] else { return }
        Self.fonts()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "polish-styles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appending(path: "_library"), withIntermediateDirectories: true)
        for part in ["styles", "effects"] {
            let from = URL(fileURLWithPath: src).appending(path: "_library/\(part)")
            guard fm.fileExists(atPath: from.path) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cp")
            p.arguments = ["-cR", from.path, root.appending(path: "_library/\(part)").path]
            try p.run(); p.waitUntilExit()
        }
        let suite = "polish-styles-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel()
        app.library.setRoot(root)
        for page in ["styles", "effects"] {
            defaults.set(page, forKey: "stylesPage")
            for (name, scheme, look) in Self.looks {
                try Self.host(StylesBoard(root: root).environment(app).environment(\.colorScheme, scheme).defaultAppStorage(defaults),
                              CGSize(width: 1200, height: 860), look, dir, "styles-\(page)-\(name)", settle: 3)
            }
        }
    }
}
