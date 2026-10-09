import Foundation
import Testing
@testable import Takes

struct GeminiKeyTests {
    @Test func savingReplacesOnlyTheGeminiLine() {
        let old = "# keys\nGOOGLE_AI_API_KEY=old-google\nexport GEMINI_API_KEY=\"old\"\nOPENAI_API_KEY=o\n\n"
        #expect(GeminiKey.withKey(old, "new") == "# keys\nGOOGLE_AI_API_KEY=old-google\nOPENAI_API_KEY=o\nGEMINI_API_KEY=new\n")
        #expect(GeminiKey.withKey("", "k") == "GEMINI_API_KEY=k\n")
        #expect(GeminiKey.withKey("A=1", "k") == "A=1\nGEMINI_API_KEY=k\n")
    }

    @Test func saveWritesAPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: ".claude/.env")
        try GeminiKey.save("one", to: file)
        try GeminiKey.save("two", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "GEMINI_API_KEY=two\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func everyUseSaysWhatHappensWithoutIt() {
        #expect(GeminiKey.uses.count == 4)
        for u in GeminiKey.uses { #expect(u.without.contains("Without it")) }
        #expect(SettingsView.SettingsPage.shown.contains(.gemini))
    }
}
