import Foundation
import Testing
@testable import Takes

// A Claude Code chat loads only the user's own MCP servers (2026-10-13, ChatMCP.swift).
struct ChatMCPTests {
    let claude = Data(#"""
    {"mcpServers":{"takes":{"type":"stdio","command":"python3","args":["takes_mcp.py"]},
                   "nimo":{"type":"http","url":"https://nimo.example/mcp"}},
     "projects":{"/work":{"mcpServers":{"local":{"command":"x"}},
                          "enabledMcpjsonServers":["shared"],"disabledMcpjsonServers":["off"]},
                 "/other":{"mcpServers":{"elsewhere":{"command":"y"}}}}}
    """#.utf8)

    @Test func userLocalAndApprovedSharedServers() throws {
        let mcp = Data(#"{"mcpServers":{"shared":{"url":"a"},"off":{"url":"b"},"unasked":{"url":"c"},"nimo":{"url":"project"}}}"#.utf8)
        let s = try #require(ChatMCP.servers(claudeJSON: claude, folder: "/work", mcpJSON: mcp))
        #expect(Set(s.keys) == ["takes", "nimo", "local", "shared"], "not approved, refused and other folders stay out")
        #expect((s["nimo"] as? [String: Any])?["url"] as? String == "https://nimo.example/mcp", "The user's own entry wins")
    }

    @Test func approveAllTakesEveryShared() throws {
        let c = Data(#"{"projects":{"/w":{"enableAllProjectMcpServers":true,"disabledMcpjsonServers":["off"]}}}"#.utf8)
        let mcp = Data(#"{"mcpServers":{"a":{},"off":{}}}"#.utf8)
        #expect(Set(try #require(ChatMCP.servers(claudeJSON: c, folder: "/w", mcpJSON: mcp)).keys) == ["a"])
    }

    @Test func halfWrittenFileLoadsEverything() {
        #expect(ChatMCP.servers(claudeJSON: Data("{\"mcpServers\":".utf8), folder: "/w", mcpJSON: nil) == nil)
    }

    /// A remote server's call stops after 4 minutes (2026-11-05: nimo calls hung 436 s and 940 s). The stdio takes server
    /// keeps the default, and a time limit the user set stays.
    @Test func remoteServersGetATimeLimit() throws {
        let c = Data(#"""
        {"mcpServers":{"takes":{"type":"stdio","command":"python3"},"nimo":{"type":"http","url":"https://n.x.test/mcp"},
                       "old":{"type":"sse","url":"https://o.x.test/sse"},"slow":{"type":"http","url":"https://s.x.test","timeout":600000}}}
        """#.utf8)
        let s = try #require(ChatMCP.servers(claudeJSON: c, folder: "/w", mcpJSON: nil))
        func timeout(_ k: String) -> Int? { (s[k] as? [String: Any])?["timeout"] as? Int }
        #expect(timeout("nimo") == 240_000 && timeout("old") == 240_000)
        #expect(timeout("takes") == nil)
        #expect(timeout("slow") == 600_000)
    }

    @Test func argumentsAddTheStrictConfig() {
        var t = ChatTurn(context: "c", model: "m", conversation: "id", thread: nil, started: false, access: "acceptEdits", board: nil)
        #expect(!ClaudeAdapter().chatArguments(t).contains("--strict-mcp-config"))
        t.mcpConfig = "/tmp/chat-mcp.json"
        let a = ClaudeAdapter().chatArguments(t)
        let i = try? #require(a.firstIndex(of: "--strict-mcp-config"))
        #expect(i.map { a[$0 + 1...$0 + 2] == ["--mcp-config", "/tmp/chat-mcp.json"] } == true)
        #expect(a.contains("--chrome"), "Claude in Chrome comes from --chrome, not from the config")
    }
}
