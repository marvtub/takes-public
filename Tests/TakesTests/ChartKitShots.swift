import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The chart kit, to look at (2026-10-29): `TAKES_SNAPSHOT=/dir TAKES_SOCIAL=<social.json> ./test.sh --filter ChartKitShots`.
/// Each chart in light and dark, one with the pointer on it.
@MainActor
struct ChartKitShots {
    @Test func kit() {
        #expect(Kit.ticks(3447) == [0, 1000, 2000, 3000, 4000])
        #expect(Kit.ticks(lo: 8875, hi: 8982).first! <= 8875)
        #expect(Kit.change(150, 100) == "↑ 50%")
        #expect(Kit.change(57, 100) == "↓ 43%")
        #expect(Kit.change(0, 0) == nil)
        #expect(Kit.short(1500) == "1.5k")
    }

    @Test func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"],
              let file = ProcessInfo.processInfo.environment["TAKES_SOCIAL"],
              let data = try? JSONDecoder().decode(SocialData.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let m = data.momentum
        let cur = Array(m.linkedin.suffix(30)), prior = Array(m.linkedin.suffix(60).prefix(30))
        let views: [(String, AnyView)] = [
            ("page", AnyView(SignalPage(data: data, platform: "LinkedIn") { EmptyView() })),
            ("hover", AnyView(AreaChart(dates: Array(m.dates.suffix(30)), values: cur, color: Signal.linkedin, height: 170,
                                        prior: prior, hover: 14).card(padding: 18))),
        ]
        for (name, v) in views {
            for scheme in [ColorScheme.light, .dark] {
                NSAppearance.current = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let r = ImageRenderer(content: v.frame(width: 1100).padding(24).background(Theme.canvas).environment(\.colorScheme, scheme))
                r.scale = 1.5
                let cg = try #require(r.cgImage)
                let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appending(path: "kit-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
