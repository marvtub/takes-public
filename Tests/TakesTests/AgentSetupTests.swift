import Foundation
import Testing
@testable import Takes

struct AgentSetupTests {
    @Test func copiesOnlyShippedSkills() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: UUID().uuidString)
        let src = tmp.appending(path: "src"), dst = tmp.appending(path: "dst")
        try fm.createDirectory(at: src.appending(path: "takes-storyboard"), withIntermediateDirectories: true)
        try "new".write(to: src.appending(path: "takes-storyboard/SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dst.appending(path: "mine"), withIntermediateDirectories: true)
        try "keep".write(to: dst.appending(path: "mine/SKILL.md"), atomically: true, encoding: .utf8)
        AgentSetup.copySkills(from: src, to: dst)
        #expect(try String(contentsOf: dst.appending(path: "takes-storyboard/SKILL.md"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: dst.appending(path: "mine/SKILL.md"), encoding: .utf8) == "keep")
        #expect(SkillShelf.source(of: dst.appending(path: "takes-storyboard")) == SkillShelf.fromTakes)
        try? fm.removeItem(at: tmp)
    }

    /// A skill switched off in Plugins › Skills does not come back at the next launch.
    @Test func leavesOutSkillsSwitchedOff() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let src = tmp.appending(path: "src"), dst = tmp.appending(path: "dst")
        for n in ["takes-storyboard", "takes-image-prompt"] {
            try fm.createDirectory(at: src.appending(path: n), withIntermediateDirectories: true)
            try "x".write(to: src.appending(path: "\(n)/SKILL.md"), atomically: true, encoding: .utf8)
        }
        AgentSetup.copySkills(from: src, to: dst, skipping: ["takes-image-prompt"])
        #expect(fm.fileExists(atPath: dst.appending(path: "takes-storyboard/SKILL.md").path))
        #expect(!fm.fileExists(atPath: dst.appending(path: "takes-image-prompt").path))
    }

    /// HyperFrames downloads once: not when switched off, not when the user has it, not twice.
    @Test func fetchesHyperFramesOnlyWhenMissing() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let packs = [SkillPack.hyperframes]
        #expect(AgentSetup.packsToFetch(packs, off: [], home: home) == packs)
        #expect(AgentSetup.packsToFetch(packs, off: ["hyperframes"], home: home).isEmpty)
        try fm.createDirectory(at: home.appending(path: "hyperframes"), withIntermediateDirectories: true)
        try "x".write(to: home.appending(path: "hyperframes/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(AgentSetup.packsToFetch(packs, off: [], home: home).isEmpty)
    }
}
