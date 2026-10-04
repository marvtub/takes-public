import Foundation
import Testing
@testable import Takes

struct AgentSetupTests {
    @Test func findsTheRegisteredScript() {
        let out = """
        takes:
          Scope: User config
          Type: stdio
          Command: /usr/bin/python3
          Args: /Applications/Takes.app/Contents/Resources/takes_mcp.py
        """
        #expect(AgentSetup.registeredScripts(in: out) == ["/Applications/Takes.app/Contents/Resources/takes_mcp.py"])
    }

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
        try? fm.removeItem(at: tmp)
    }
}
