import Foundation

// Which MCP servers a Takes chat on Claude Code loads (2026-10-13). Each message starts `claude -p`
// again, and it connected every server each time: the claude.ai connectors and the plugin servers
// too, 19 on the user's Mac, 289 tools. The speed audit measured the start at 2.31 s with them and
// 1.35 s without. So the chat loads only the servers the user added (user scope, the chat
// folder's own, and its approved .mcp.json) with --strict-mcp-config. Claude in Chrome stays: it
// comes from --chrome. Settings › Agents › "MCP servers in the chat" turns all of them back on.

enum ChatMCP {
    static let allKey = "chatAllMCP"

    /// The chat loads every server, as in the terminal.
    static var all: Bool { UserDefaults.standard.bool(forKey: allKey) }

    /// Claude Code's own settings file.
    static var claudeJSON: URL {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let dir = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return dir.appending(path: ".claude.json")
    }

    /// Written for each message: the servers can change between two messages.
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Takes/chat-mcp.json")
    }

    /// The --mcp-config file for one message, or nil: then the chat loads every server.
    /// Nil too when Claude Code's file can't be read (it may be half written): never a chat without takes.
    static func config(folder: URL) -> String? {
        guard !all, let claude = try? Data(contentsOf: claudeJSON) else { return nil }
        let mcp = try? Data(contentsOf: folder.appending(path: ".mcp.json"))
        guard let servers = servers(claudeJSON: claude, folder: folder.path, mcpJSON: mcp), !servers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])
        else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The entries may hold headers with keys: only the user reads this file.
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        return file.path
    }

    /// The user's own servers, as Claude Code finds them: user scope, then the folder's local
    /// scope, then the folder's .mcp.json servers the user approved. Nil when the file isn't JSON.
    static func servers(claudeJSON: Data, folder: String, mcpJSON: Data?) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: claudeJSON) as? [String: Any] else { return nil }
        var out = o["mcpServers"] as? [String: Any] ?? [:]
        let project = (o["projects"] as? [String: Any])?[folder] as? [String: Any] ?? [:]
        for (k, v) in project["mcpServers"] as? [String: Any] ?? [:] { out[k] = v }
        if let mcpJSON, let shared = (try? JSONSerialization.jsonObject(with: mcpJSON) as? [String: Any])?["mcpServers"] as? [String: Any] {
            let every = project["enableAllProjectMcpServers"] as? Bool ?? false
            let approved = Set(project["enabledMcpjsonServers"] as? [String] ?? [])
            let refused = Set(project["disabledMcpjsonServers"] as? [String] ?? [])
            for (k, v) in shared where (every || approved.contains(k)) && !refused.contains(k) && out[k] == nil {
                out[k] = v
            }
        }
        return out
    }
}
