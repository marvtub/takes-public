import Foundation

/// First-launch setup for Claude Code (2026-10-04), so a downloaded Takes works without build.sh:
/// registers the `takes` MCP server (or points it again at this copy when the app moved), and
/// copies the skills the build ships in Resources/skills to ~/.claude/skills. It touches only
/// the `takes` server and the skill folders it ships. In the background, once per launch.
enum AgentSetup {
    static func run() {
        guard let claude = Namer.claudePath else { return }
        let resources = Bundle.main.bundleURL.appending(path: "Contents/Resources")
        let server = resources.appending(path: "takes_mcp.py").path
        guard FileManager.default.fileExists(atPath: server) else { return }
        Task.detached(priority: .utility) {
            ensureServer(claude: claude, server: server)
            copySkills(from: resources.appending(path: "skills"))
        }
    }

    /// Adds the server when it is missing, or when its script no longer exists.
    nonisolated static func ensureServer(claude: String, server: String) {
        let (ok, out) = shell(claude, ["mcp", "get", "takes"])
        if ok {
            let paths = registeredScripts(in: out)
            if paths.isEmpty || paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return }
            _ = shell(claude, ["mcp", "remove", "takes", "--scope", "user"])
        }
        _ = shell(claude, ["mcp", "add", "takes", "--scope", "user", "--", "/usr/bin/python3", server])
    }

    /// The takes_mcp.py paths in `claude mcp get takes` output.
    nonisolated static func registeredScripts(in text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init).filter { $0.hasSuffix("takes_mcp.py") }
    }

    /// Copies each shipped skill folder over the user's copy of the same name. Only these names.
    nonisolated static func copySkills(from dir: URL, to target: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")) {
        let fm = FileManager.default
        guard let skills = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for s in skills where fm.fileExists(atPath: s.appending(path: "SKILL.md").path) {
            let dest = target.appending(path: s.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: s, to: dest)
        }
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath
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
