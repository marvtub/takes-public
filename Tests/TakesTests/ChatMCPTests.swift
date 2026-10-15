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
