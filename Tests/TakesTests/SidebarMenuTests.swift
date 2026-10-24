import AppKit
import SwiftUI
import Testing
@testable import Takes

/// A right-click on a session row opens the session's menu, never its project's (2026-10-22: in a
/// scroll view every menu region claimed every point, so the project header's won, and the user
/// trashed a whole project when he meant one session).
@MainActor @Suite(.serialized) struct SidebarMenuTests {
    @Test func eachRowOpensItsOwnMenu() async throws {
        let app = AppModel()
        let root = FileManager.default.temporaryDirectory.appending(path: "takes-sidemenu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for s in ["2026-10-01-one", "2026-10-02-two", "2026-10-03-three"] {
            let url = root.appending(path: "Alpha").appending(path: s)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let doc = SessionDoc(url: url)
            doc.meta = SessionMeta(title: s, createdAt: Date(), named: true)
            doc.save()
        }
        app.library.setRoot(root)
        let size = NSSize(width: 280, height: 400)
        let h = NSHostingView(rootView: AnyView(SessionList(library: app.library, queue: app.posts).environment(app)
            .frame(width: size.width, height: size.height)))
        h.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = h
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        h.layoutSubtreeIfNeeded()
        func menu(atTop y: CGFloat) -> String? {
            let e = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 200, y: size.height - y), modifierFlags: [],
                                       timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
            return ContextMenus.shared.region(for: e)?.content?().map(\.title).first { $0.hasPrefix("Move") && $0.contains("to Trash") }
        }
        // Wait for the rows to lay out: until a row answers.
        let end = Date().addingTimeInterval(20)
        while menu(atTop: 46) == nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        // The header is at the top, the three rows under it, then empty space.
        #expect(menu(atTop: 15) == "Move project to Trash\u{2026}")
        #expect(menu(atTop: 46) == "Move session to Trash")
        #expect(menu(atTop: 112) == "Move session to Trash")
        #expect(menu(atTop: 300) == nil)
    }

    /// The confirm, to look at: `TAKES_SNAPSHOT=/dir ./test.sh --filter SidebarMenu`.
    @Test func trashConfirm() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let v = TakesConfirm(title: "Move \u{201C}Weekly Challenge\u{201D} to the Trash?",
                                 message: "Its 16 sessions go with it. You can put it back from the Trash in Finder.",
                                 confirm: "Move to Trash", danger: true, onConfirm: {}, onCancel: {})
                .menuChrome().padding(30).background(Theme.canvas)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "trash-confirm-\(name).png"))
        }
    }
}
