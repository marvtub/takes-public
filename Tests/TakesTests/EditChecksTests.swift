import Foundation
import Testing
@testable import Takes

/// check_edit's results under the review player and on the Assets tile (2026-10-11).
@MainActor
struct EditChecksTests {
    private func session() throws -> URL {
        let s = FileManager.default.temporaryDirectory.appending(path: "editchecks-\(UUID().uuidString)/Proj/2026-10-11-a")
        try FileManager.default.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        return s
    }

    private func write(_ json: String, to s: URL) throws {
        try Data(json.utf8).write(to: s.appending(path: "checks.json"))
    }

    private let modified = Date(timeIntervalSince1970: 1_760_288_400)

    @Test func readsV2Entry() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try write(#"""
        {"edits/hook-v4.mp4": {"v": 2, "at": "2026-10-12T17:02:11Z", "mtime": 1760288400.0, "source": "take-03-camera.mov",
          "known": true, "passed": false, "results": [
            {"check": "band_balance", "label": "Thin voice", "pass": false, "value": -14.2,
             "say": "The voice sounds thin. It lost its low tones.", "fix": "x"},
            {"check": "regression", "comment": "c12", "label": "Fix undone", "pass": false, "value": 0.41, "at": [22.3],
             "say": "A fix you approved changed at 0:22.", "fix": "y"},
            {"check": "picture_drift", "pass": null, "skip": "Pass source."},
            {"rule": "sound-3", "text": "Loudness -14 LUFS.", "pass": true, "value": -14.3, "want": "-14 ± 1 LUFS"},
            {"check": "streams", "pass": true, "value": "-inf"}]}}
        """#, to: s)
        let st = EditChecks.read(s, file: "edits/hook-v4.mp4", modified: modified)
        guard case .problems(let p) = st else { Issue.record("not problems: \(st)"); return }
        #expect(p.map(\.title) == ["Thin voice", "Fix undone"])
        #expect(p[1].at == [22.3])
        #expect(EditChecks.problems(st) == 2)
    }

    @Test func oldEntryIsUnchecked() {
        let old: [String: Any] = ["at": "2026-10-01T00:00:00Z", "results": [["rule": "cut-1", "pass": false]]]
        #expect(EditChecks.state(old, modified: modified) == .unchecked)
    }

    @Test func newerFileIsStale() {
        let e: [String: Any] = ["v": 2, "mtime": modified.timeIntervalSince1970, "results": [["check": "streams", "pass": true]]]
        #expect(EditChecks.state(e, modified: modified.addingTimeInterval(0.5)) == .passed(skipped: []))
        #expect(EditChecks.state(e, modified: modified.addingTimeInterval(30)) == .stale)
    }

    @Test func missingFileIsUnchecked() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(EditChecks.read(s, file: "edits/a-v1.mp4", modified: modified) == .unchecked)
        try write("{not json", to: s)
        #expect(EditChecks.read(s, file: "edits/a-v1.mp4", modified: modified) == .unchecked)
    }

    @Test func skippedChecksDoNotShowAsProblems() {
        let e: [String: Any] = ["v": 2, "mtime": modified.timeIntervalSince1970, "results": [
            ["check": "streams", "pass": true], ["check": "echo", "pass": NSNull(), "skip": "Music under the voice."],
            ["check": "words", "pass": NSNull(), "error": "ffmpeg: failed"]]]
        #expect(EditChecks.state(e, modified: modified) == .passed(skipped: ["Music under the voice.", "ffmpeg: failed"]))
        // Only skipped checks is nothing ran.
        do {
            let e: [String: Any] = ["v": 2, "mtime": modified.timeIntervalSince1970, "results": [
                ["check": "echo", "pass": NSNull(), "skip": "No take."]]]
            #expect(EditChecks.state(e, modified: modified) == .nothingRan)
        }
        // The lines the user sees name Takes, never Claude or the user.
        let c = EditCheck(check: "echo", pass: false, label: "Echo", say: "The voice has more echo than the take.")
        for s in [EditChecks.line(.nothingRan), EditChecks.line(.stale), EditChecks.line(.unchecked), c.help] {
            #expect(!s.contains("Claude") && !s.contains("The user"))
        }
    }

    @Test func capsuleUsesLabel() {
        #expect(EditCheck(check: "av_sync", pass: false, label: "Sound late", say: "The sound is late by 0.2 s.").title == "Sound late")
        let rule = EditCheck(rule: "cut-1", pass: false, text: "Pauses under 0.4 s between every sentence of the video.")
        #expect(rule.title == "Rule: Pauses under 0.4 s between ev…")
        // Too many for the row: the rest go under "+N more".
        let many = Array(repeating: "Fix undone", count: 12)
        #expect(CheckLine.fit(many, width: 2000) == 12)
        let n = CheckLine.fit(many, width: 300)
        #expect(n > 0 && n < 12)
    }

    @Test func checksJSONIsNotAnAsset() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let edit = s.appending(path: "edits/hook-v1.mp4")
        try Data("x".utf8).write(to: edit)
        let mtime = (try edit.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate!.timeIntervalSince1970
        try write(#"{"edits/hook-v1.mp4": {"v": 2, "mtime": \#(mtime), "results": [{"check": "echo", "pass": false, "label": "Echo"}, {"check": "words", "pass": false, "label": "Cut word"}]}}"#, to: s)
        try FileManager.default.createDirectory(at: s.appending(path: ".checks-cache"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: s.appending(path: ".checks-cache/take-01-camera.mov.1-1.json"))
        let store = AssetStore()
        store.scan(SessionDoc(url: s))
        #expect(store.assets.map(\.rel) == ["edits/hook-v1.mp4"])
        #expect(store.assets.first?.problems == 2)
    }
}
