import Foundation
import Testing
@testable import Takes

// 2026-10-03: the iPhone app updates when the user taps Update; install.sh only stages the build.

struct PhoneUpdateTests {
    let staged = PhoneUpdate.Staged(stamp: "abc1234 Oct 3 20:00", changes: ["One", "Two"], device: "D", staged: nil)

    @Test func nothingStagedSaysNothing() {
        #expect(PhoneUpdate.status(staged: nil, installing: false, error: "old") == PhoneUpdate.Status())
    }

    @Test func installingHidesTheLastError() {
        let s = PhoneUpdate.status(staged: staged, installing: true, error: "old")
        #expect(s.installing == true && s.error == nil && s.stamp == staged.stamp)
        #expect(PhoneUpdate.status(staged: staged, installing: false, error: "no phone").error == "no phone")
    }

    @Test func readsWhatInstallShWrote() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "phone-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = PhoneUpdate(dir: dir)
        #expect(u.staged() == nil)
        try FileManager.default.createDirectory(at: u.app, withIntermediateDirectories: true)
        try Data().write(to: u.app.appending(path: "Info.plist"))
        try Data(#"{"stamp":"abc1234 Oct 3 20:00","changes":["One","Two"],"device":"D"}"#.utf8).write(to: u.manifest)
        #expect(u.staged() == staged)
        #expect(u.status().stamp == staged.stamp)
    }

    @Test func errorTailKeepsTheLastLines() {
        #expect(PhoneUpdate.tail("a\n\nb\nc\nd\ne\n") == "b\nc\nd\ne")
        #expect(PhoneUpdate.tail("  \n") == "The install failed.")
    }
}
