import Foundation

// The Takes chat on each agent (2026-10-12). The chat (Chat.swift) keeps the conversation, the queue,
// steers and the panel; the adapter knows its CLI: the arguments for one message, and how its output
// lines become messages and steps (ChatParser). A new chat agent is one ChatAdapter here.

/// One message of a Takes chat, as the agent's CLI needs it.
struct ChatTurn {
    /// The instructions: which session or board, how to answer.
    var context: String
    var model: String
    /// Takes' id for the conversation. Claude Code takes it as its own session id.
    var conversation: String
    /// The agent's own id for the conversation, when it makes one (Codex's thread).
    var thread: String?
    /// The conversation exists: this message goes on in it.
    var started: Bool
    /// "bypassPermissions" (full access) or "acceptEdits" (ClaudeChat.access).
    var access: String
    /// A chat without a session: its board.
    var board: String?
    /// Claude Code: the file with the only MCP servers to load (ChatMCP). Nil loads every server.
    var mcpConfig: String? = nil
    /// Claude Code: the process stays open and reads message after message (ChatWarm).
    var warm = false
}

protocol ChatAdapter: AgentAdapter {
    func chatArguments(_ t: ChatTurn) -> [String]
    /// One output line, already read as JSON, into the parser.
    func consume(_ type: String, _ o: [String: Any], into p: inout ChatParser)
    /// Has Claude in Chrome: the chat gets the browser rules.
    var browser: Bool { get }
    /// Takes `/compact` as a message.
    var compacts: Bool { get }
    /// stderr says the conversation is gone (deleted, or made in another folder): start a new one.
    func lost(_ stderr: String) -> Bool
    /// A turn that ends cleanly with no text is a failure. Claude Code: no (a /compact turn has none).
    var answersEveryTurn: Bool { get }
}

// MARK: Claude Code

/// `claude -p --output-format stream-json`, resuming Takes' conversation id.
extension ClaudeAdapter: ChatAdapter {
    var browser: Bool { true }
    var compacts: Bool { true }
    var answersEveryTurn: Bool { false }

    func chatArguments(_ t: ChatTurn) -> [String] {
        // Print mode loads Claude in Chrome only with --chrome (the terminal enables it by itself).
        ["-p", "--chrome", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--permission-mode", t.access, "--model", t.model, "--append-system-prompt", t.context]
            + (t.mcpConfig.map { ["--strict-mcp-config", "--mcp-config", $0] } ?? [])
            + (t.warm ? ["--input-format", "stream-json"] : [])
            + (t.started ? ["--resume", t.conversation] : ["--session-id", t.conversation])
    }

    func lost(_ stderr: String) -> Bool { stderr.contains("No conversation found") }

    func consume(_ type: String, _ o: [String: Any], into p: inout ChatParser) {
        switch type {
        case "system":
            switch o["subtype"] as? String {
            case "init": p.started = true
            case "compact_boundary":
                // /compact, or Claude Code compacting by itself when the context is full.
                let m = o["compact_metadata"] as? [String: Any] ?? [:]
                let before = m["pre_tokens"] as? Int, after = m["post_tokens"] as? Int
                var line = "Compacted the conversation"
                if let before, let after { line += " · \(ChatContext.short(before)) → \(ChatContext.short(after)) tokens" }
                p.messages.append(ChatMessage(role: .tool, text: line))
                if let after { p.setUsed(after) }
                p.compacted = true
            default: break
            }
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_start",
               let b = e["content_block"] as? [String: Any], b["type"] as? String == "text" {
                p.messages.append(ChatMessage(role: .claude, text: "", done: false))
            } else if e["type"] as? String == "content_block_delta",
                      let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                      let t = d["text"] as? String {
                if let i = p.messages.indices.last, p.messages[i].role == .claude, !p.messages[i].done {
                    p.messages[i].text += t
                } else {
                    p.messages.append(ChatMessage(role: .claude, text: t, done: false))
                }
            }
        case "assistant":
            // Each call's usage is the whole context it read: what is in the window now.
            if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                p.setUsed(keys.reduce(0) { $0 + (u[$1] as? Int ?? 0) })
            }
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content {
                switch b["type"] as? String {
                case "text":
                    let t = b["text"] as? String ?? ""
                    if let i = p.messages.indices.last, p.messages[i].role == .claude, !p.messages[i].done {
                        p.messages[i].text = t
                        p.messages[i].done = true
                    } else if !t.isEmpty {
                        p.messages.append(ChatMessage(role: .claude, text: t))
                    }
                case "tool_use":
                    let id = b["id"] as? String
                    let line = ChatParser.describe(b["name"] as? String ?? "Tool", b["input"] as? [String: Any] ?? [:])
                    p.messages.append(ChatMessage(role: .tool, text: line, toolID: id, done: false))
                default: break
                }
            }
        case "user":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String, let i = p.messages.lastIndex(where: { $0.toolID == id }) {
                    p.messages[i].done = true
                    if b["is_error"] as? Bool == true { p.messages[i].failed = true }
                }
            }
        case "result":
            p.finished = true
            p.closeOpen()
            // The window size comes only here. Subagents may run on smaller models: take the largest.
            let windows = (o["modelUsage"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["contextWindow"] as? Int }
            if let w = windows.max(), w > 0 { p.context = ChatContext(used: p.context?.used ?? 0, window: w) }
            // The turn's tokens, subagents included: modelUsage holds every model's total.
            let models = (o["modelUsage"] as? [String: [String: Any]] ?? [:]).values
            if !models.isEmpty {
                for m in models {
                    let out = m["outputTokens"] as? Int ?? 0
                    p.spent += out + ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].reduce(0) { $0 + (m[$1] as? Int ?? 0) }
                    p.spentOut += out
                }
            } else if let u = o["usage"] as? [String: Any] {
                let out = u["output_tokens"] as? Int ?? 0
                p.spent += out + ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                p.spentOut += out
            }
            if o["is_error"] as? Bool == true || (o["subtype"] as? String).map({ $0 != "success" }) == true {
                let r = o["result"] as? String ?? ""
                p.messages.append(ChatMessage(role: .error, text: r.isEmpty ? "The chat stopped with an error." : r))
            }
        default: break
        }
    }
}

// MARK: Codex

/// `codex exec --json` for a new thread, or `codex exec resume <thread>` (2026-10-11). The ask
/// comes on stdin ("-"). Full access maps to Codex's danger-full-access sandbox, edit-only to
/// workspace-write; it never asks (there is no one to answer). Codex hands its MCP servers only
/// a few variables, so the takes server gets the chat's own through -c, when Codex has it.
extension CodexAdapter: ChatAdapter {
    var browser: Bool { false }
    var compacts: Bool { false }
    var answersEveryTurn: Bool { true }
    func lost(_ stderr: String) -> Bool { false }

    func chatArguments(_ t: ChatTurn) -> [String] {
        Self.chatArguments(context: t.context, model: t.model, thread: t.started ? t.thread : nil, chat: t.conversation,
                           board: t.board, access: t.access, takesInCodex: Self.hasTakes)
    }

    static func chatArguments(context: String, model: String, thread: String?, chat: String, board: String?,
                              access: String, takesInCodex: Bool) -> [String] {
        var a = ["exec"]
        if thread != nil { a.append("resume") }
        a += ["--json", "--skip-git-repo-check", "-m", model,
              "-c", "sandbox_mode=\"\(access == "acceptEdits" ? "workspace-write" : "danger-full-access")\"",
              "-c", "approval_policy=\"never\"",
              "-c", "developer_instructions=" + toml(context)]
        if takesInCodex {
            a += ["-c", "mcp_servers.takes.env.TAKES_CHAT=\"1\"", "-c", "mcp_servers.takes.env.TAKES_CHAT_ID=" + toml(chat)]
            if let board { a += ["-c", "mcp_servers.takes.env.TAKES_BOARD=" + toml(board)] }
        }
        if let thread { a.append(thread) }
        a.append("-")
        return a
    }

    /// A TOML basic string, as `codex -c key=value` reads it.
    static func toml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Codex has the takes server in its config (AgentSetup adds it). Without it, -c on its env
    /// would make a server with no command, and Codex would not start.
    static var hasTakes: Bool {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        let text = (try? String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[mcp_servers.takes") }
    }

    /// thread.started, item.started / item.completed (agent_message, mcp_tool_call, command_execution,
    /// file_change, web_search), turn.completed, turn.failed. Its "error" items are warnings (a model
    /// without metadata, hook trust): the panel skips them.
    func consume(_ type: String, _ o: [String: Any], into p: inout ChatParser) {
        switch type {
        case "thread.started":
            p.started = true
            p.thread = o["thread_id"] as? String
        case "item.started", "item.completed":
            guard let item = o["item"] as? [String: Any], let kind = item["type"] as? String else { return }
            let id = item["id"] as? String
            let done = type == "item.completed"
            if kind == "agent_message" {
                let t = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if done && !t.isEmpty { p.messages.append(ChatMessage(role: .claude, text: t)) }
                return
            }
            guard let line = Self.describe(kind, item) else { return }
            if let i = p.messages.lastIndex(where: { $0.toolID == id && id != nil && $0.role == .tool }) {
                if done { p.messages[i].done = true }
                if done, item["status"] as? String == "failed" { p.messages[i].failed = true }
            } else {
                p.messages.append(ChatMessage(role: .tool, text: line, toolID: id, done: done))
            }
        case "turn.completed":
            p.finished = true
            p.closeOpen()
            if let u = o["usage"] as? [String: Any] {
                let used = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                p.context = ChatContext(used: used, window: 272_000)
                p.spent += used
                p.spentOut += u["output_tokens"] as? Int ?? 0
            }
        case "turn.failed":
            p.finished = true
            p.closeOpen()
            let raw = (o["error"] as? [String: Any])?["message"] as? String ?? ""
            p.messages.append(ChatMessage(role: .error, text: Self.error(raw)))
        default: break
        }
    }

    /// Codex wraps the server's error as JSON in the message: show its inner message.
    static func error(_ raw: String) -> String {
        if let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           let m = ((o["error"] as? [String: Any])?["message"] as? String) ?? (o["message"] as? String), !m.isEmpty {
            return m
        }
        return raw.isEmpty ? "The chat stopped with an error." : raw
    }

    /// The line a Codex step shows, in the same words as Claude's ("Bash · …", "get_session").
    static func describe(_ kind: String, _ item: [String: Any]) -> String? {
        switch kind {
        case "mcp_tool_call":
            return ChatParser.describe(item["tool"] as? String ?? "Tool", item["arguments"] as? [String: Any] ?? [:])
        case "command_execution":
            var c = item["command"] as? String ?? ""
            // "/bin/zsh -lc 'ffmpeg …'": only the command.
            if let r = c.range(of: "sh -lc '"), c.hasSuffix("'"), r.upperBound < c.endIndex {
                c = String(c[r.upperBound..<c.index(before: c.endIndex)])
            }
            return ChatParser.describe("Bash", ["command": c])
        case "file_change":
            let files = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return ChatParser.describe("Edit", files.first.map { ["file_path": $0] } ?? [:])
        case "web_search":
            return ChatParser.describe("WebSearch", ["query": item["query"] as? String ?? ""])
        default:
            return nil
        }
    }
}

// MARK: pi

/// `pi -p --mode json --session-id <conversation>` (2026-10-12, pi 0.84). Like Claude Code, pi takes
/// Takes' conversation id as its own and makes the session on the first message. The takes tools
/// come through pi-mcp-adapter (takes_mcp.py --setup adds the server to ~/.pi/agent/mcp.json), which
/// hands its servers pi's environment: TAKES_CHAT_ID reaches the takes server that way. pi has no
/// permission modes: edit-only leaves out bash. `/compact` does not work in print mode; pi compacts
/// by itself. The model is the one set in pi, unless the chat names one.
extension PiAdapter: ChatAdapter {
    var browser: Bool { false }
    var compacts: Bool { false }
    var answersEveryTurn: Bool { true }
    func lost(_ stderr: String) -> Bool { false }

    func chatArguments(_ t: ChatTurn) -> [String] {
        var a = ["-p", "--mode", "json", "--session-id", t.conversation, "--append-system-prompt", t.context]
        if !t.model.isEmpty { a += ["--model", t.model] }
        if t.access == "acceptEdits" { a += ["--exclude-tools", "bash"] }
        return a
    }

    /// session, agent_start, message_update (text_start / text_delta / text_end), message_end (the
    /// whole assistant message, with usage and stopReason), tool_execution_start / _end,
    /// compaction_end, agent_end. Thinking and tool-call deltas stay out of the panel.
    func consume(_ type: String, _ o: [String: Any], into p: inout ChatParser) {
        switch type {
        case "session":
            p.started = true
        case "message_update":
            guard let e = o["assistantMessageEvent"] as? [String: Any] else { return }
            let open = p.messages.indices.last.flatMap { p.messages[$0].role == .claude && !p.messages[$0].done ? $0 : nil }
            switch e["type"] as? String {
            case "text_start":
                if open == nil { p.messages.append(ChatMessage(role: .claude, text: "", done: false)) }
            case "text_delta":
                let t = e["delta"] as? String ?? ""
                if let i = open { p.messages[i].text += t } else { p.messages.append(ChatMessage(role: .claude, text: t, done: false)) }
            case "text_end":
                let t = e["content"] as? String ?? ""
                if let i = open {
                    p.messages[i].text = t
                    p.messages[i].done = true
                } else if !t.isEmpty {
                    p.messages.append(ChatMessage(role: .claude, text: t))
                }
            default: break
            }
        case "message_end":
            guard let m = o["message"] as? [String: Any], m["role"] as? String == "assistant" else { return }
            if let u = m["usage"] as? [String: Any] {
                let used = ["input", "cacheRead", "cacheWrite", "output"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                p.setUsed(used)
                p.spent += used
                p.spentOut += u["output"] as? Int ?? 0
            }
            // The text came with text_end; a message with none (a provider that does not stream) shows here.
            let text = (m["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = p.messages.indices.last, p.messages[i].role == .claude, !p.messages[i].done {
                if !text.isEmpty { p.messages[i].text = text }
                p.messages[i].done = true
            } else if !text.isEmpty, p.messages.last(where: { $0.role != .tool })?.text != text {
                p.messages.append(ChatMessage(role: .claude, text: text))
            }
            if m["stopReason"] as? String == "error" {
                let e = (m["errorMessage"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                p.messages.append(ChatMessage(role: .error, text: e.isEmpty ? "The chat stopped with an error." : e))
            }
        case "tool_execution_start":
            let id = o["toolCallId"] as? String
            let line = Self.describe(o["toolName"] as? String ?? "tool", o["args"] as? [String: Any] ?? [:])
            p.messages.append(ChatMessage(role: .tool, text: line, toolID: id, done: false))
        case "tool_execution_end":
            if let id = o["toolCallId"] as? String, let i = p.messages.lastIndex(where: { $0.toolID == id }) {
                p.messages[i].done = true
                if o["isError"] as? Bool == true { p.messages[i].failed = true }
            }
        case "compaction_end":
            let r = o["result"] as? [String: Any] ?? [:]
            let before = r["tokensBefore"] as? Int, after = r["estimatedTokensAfter"] as? Int
            var line = "Compacted the conversation"
            if let before, let after { line += " · \(ChatContext.short(before)) → \(ChatContext.short(after)) tokens" }
            p.messages.append(ChatMessage(role: .tool, text: line))
            if let after { p.setUsed(after) }
            p.compacted = true
        case "agent_end":
            p.finished = true
            p.closeOpen()
        default: break
        }
    }

    /// pi's tools in the words Claude's steps use: "Read script.md", "Bash · ffmpeg …". The takes tools
    /// come through pi-mcp-adapter's proxy tool (`mcp`, `mcp__takes`): its `tool` names the real one
    /// ("takes_get_session"). Seen on this Mac: search with mcp, then call with mcp__takes.
    static func describe(_ name: String, _ args: [String: Any]) -> String {
        let names = ["read": "Read", "bash": "Bash", "edit": "Edit", "write": "Write", "grep": "Grep", "find": "Glob", "ls": "LS"]
        // "mcp", or "mcp__takes" once pi knows the server.
        if name == "mcp" || name.hasPrefix("mcp__") {
            if let tool = args["tool"] as? String {
                let short = tool.hasPrefix("takes_") ? String(tool.dropFirst(6)) : tool
                return ChatParser.describe(short, args["args"] as? [String: Any] ?? [:])
            }
            if let q = args["search"] as? String { return "Find tools · \(q)" }
            return "mcp"
        }
        return ChatParser.describe(names[name] ?? name, args)
    }
}
