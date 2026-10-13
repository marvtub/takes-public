import Foundation

/// First-launch setup for the agents (2026-10-04), so a downloaded Takes works without build.sh.
/// Since 2026-10-10 any MCP agent, not only Claude Code: `takes_mcp.py --setup --once` adds the
/// `takes` server to Claude Code, Codex, Cursor, Gemini CLI, opencode, pi and Claude Desktop, each
/// one found on this Mac. It adds it once per agent (Claude Code always), and again only when the
/// app moved. The skills the build ships in Resources/skills go to ~/.claude/skills (Claude Code,
/// Cursor) and ~/.agents/skills (Codex, pi, opencode, Gemini CLI). It touches only the `takes`
/// server and the skill folders it ships. In the background, once per launch.
/// Since 2026-10-13 each copied skill carries Takes' marker (so Plugins › Skills shows it as
/// Takes'), a skill the user switched off there stays off, and the HyperFrames pack is downloaded
/// once, unless the user has it already or switched it off.
enum AgentSetup {
    static func run() {
        let resources = Bundle.main.bundleURL.appending(path: "Contents/Resources")
        let server = resources.appending(path: "takes_mcp.py").path
        guard FileManager.default.fileExists(atPath: server) else { return }
        Task.detached(priority: .utility) {
            // Without the Command Line Tools, /usr/bin/python3 opens Apple's install dialog.
            guard shell("/usr/bin/xcode-select", ["-p"]).0 else { return }
            _ = shell("/usr/bin/python3", [server, "--setup", "--once"])
            let skills = resources.appending(path: "skills")
            let off = SkillShelf.off
            copySkills(from: skills, skipping: off)
            copySkills(from: skills, to: SkillShelf.agentsHome, skipping: off)
            for pack in packsToFetch(SkillPack.all, off: off) { _ = try? await SkillShelf.install(pack, also: [SkillShelf.agentsHome]) }
        }
    }

    /// The packs to download at launch: not switched off, and not on this Mac in any form.
    nonisolated static func packsToFetch(_ packs: [SkillPack], off: Set<String>, home: URL = SkillShelf.home) -> [SkillPack] {
        packs.filter { !off.contains($0.id) && SkillShelf.status(of: $0, in: home) == .missing }
    }

    /// Copies each shipped skill folder over the user's copy of the same name, with Takes' marker.
    /// Only these names, and none the user switched off.
    nonisolated static func copySkills(from dir: URL, to target: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills"), skipping off: Set<String> = []) {
        let fm = FileManager.default
        guard let skills = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for s in skills where fm.fileExists(atPath: s.appending(path: "SKILL.md").path) && !off.contains(s.lastPathComponent) {
            let dest = target.appending(path: s.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: s, to: dest)
            try? SkillShelf.fromTakes.write(to: dest.appending(path: SkillShelf.marker), atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
