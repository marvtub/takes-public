import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The start panel as PNGs, light and dark, with and without a last session. Only with START_SHOTS_OUT (a folder).
@MainActor @Suite struct StartPanelTests {
    @Test func shots() async throws {
        guard let out = ProcessInfo.processInfo.environment["START_SHOTS_OUT"] else { return }
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: assets.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, last) in [("last", "WebMCP in two apps" as String?), ("first", nil)] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: StartPanel(last: last).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
                let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: host.frame.size),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(300))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: out).appending(path: "start-\(name)-\(dark ? "dark" : "light").png"))
                win.contentView = nil
            }
        }
    }
}
