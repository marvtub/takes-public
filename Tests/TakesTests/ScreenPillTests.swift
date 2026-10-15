import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct ScreenPillTests {
    @Test func modesSayWhatTheyRecord() {
        #expect(Mode.camera.hasCamera && !Mode.camera.hasScreen)
        #expect(Mode.cameraScreen.hasCamera && Mode.cameraScreen.hasScreen)
        #expect(!Mode.screen.hasCamera && Mode.screen.hasScreen)
        // A saved mode from before the pill still reads.
        #expect(Mode(rawValue: "Camera + Screen") == .cameraScreen)
    }

    @Test func aPlaceOffEveryScreenIsForgotten() {
        let key = "pillOriginTest"
        UserDefaults.standard.set([-99999.0, -99999.0], forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(ScreenPill.origin(key) == nil)
    }

    /// The pill idle, with the notch open, and recording with and without the notch.
    /// Off by default: `TAKES_SNAPSHOT=/some/dir ./test.sh --filter ScreenPill`.
    @Test func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let app = AppModel()
        let mode = app.mode
        defer { app.mode = mode }
        let states: [(String, Mode, Bool, Phase)] = [
            ("idle-both", .cameraScreen, false, .idle),
            ("idle-screen-notch", .screen, true, .idle),
            ("countdown", .cameraScreen, false, .countdown(2)),
            ("recording", .cameraScreen, false, .recording(Date().addingTimeInterval(-42))),
            ("recording-notch", .cameraScreen, true, .recording(Date().addingTimeInterval(-42))),
        ]
        for (name, m, notch, phase) in states {
            app.mode = m
            app.notchOpen = notch
            app.phase = phase
            let v = ScreenPillView().environment(app).environment(\.colorScheme, .dark)
                .background(Color(red: 0.16, green: 0.17, blue: 0.19))
            let out = URL(fileURLWithPath: dir).appending(path: "pill-\(name).png")
            // ImageRenderer draws no AppKit views (the camera and mic menus), and a window capture
            // draws thin lines at a rounded shape's sides: idle needs the window, the rest do not.
            if phase == .idle {
                let host = NSHostingView(rootView: v)
                let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: ScreenPill.size.width, height: ScreenPill.size.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out)
            } else {
                let r = ImageRenderer(content: v)
                r.scale = 2
                let img = try #require(r.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try #require(img.representation(using: .png, properties: [:])).write(to: out)
            }
        }
        app.phase = .idle
        app.notchOpen = false
    }
}
