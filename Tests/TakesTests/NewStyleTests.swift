import Foundation
import SwiftUI
import Testing
@testable import Takes

extension Snap {
    /// The New style sheet the first time: the drop area, the field, ideas and what happens next.
    @Test(.enabled(if: snapDir != nil)) func newStyleSheet() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        app.library.setRoot(root)
        UserDefaults.standard.removeObject(forKey: "styleSheetSeen")
        let view = NewStyleSheet(example: .constant(""), busy: false,
                                 steps: StylesBoard.steps, make: {}, cancel: {}).environment(app)
        shoot("new-style-sheet", view, size: CGSize(width: 500, height: 560))
    }
}

@MainActor
struct StyleProgressTests {
    /// The Making card: step 1 before the folder, 2 with it, 3 once a motion part is kept.
    @Test func styleProgress() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "styleprog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = StyleLib.style("Old", root: root)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(5)
        #expect(StylesBoard.progress(root: root, since: since).name == nil)
        #expect(StylesBoard.progress(root: root, since: since).step == 1)
        let fresh = StyleLib.style("Fresh", root: root)
        try FileManager.default.createDirectory(at: fresh.appending(path: "assets/Motion"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: since.addingTimeInterval(1)], ofItemAtPath: fresh.path)
        try Data("{}".utf8).write(to: fresh.appending(path: "tokens.json"))
        #expect(StylesBoard.progress(root: root, since: since).name == "Fresh")
        #expect(StylesBoard.progress(root: root, since: since).step == 2)
        try Data().write(to: fresh.appending(path: "assets/Motion/title-v1.mp4"))
        #expect(StylesBoard.progress(root: root, since: since).step == 3)
    }
}
