import Foundation

// A Claude Code chat keeps its process open between messages (2026-10-14, speed audit item 4).
// Each message started `claude -p` again: 2.85 s before the agent did anything (median of 474
// turns). With `--input-format stream-json` one process takes message after message: the second
// one starts in about 0.3 s. Only Claude Code can do this; Codex and pi start per message.
//
// The measures the user picked: a process with no message for 10 minutes ends, at most 3 wait at
// once (the oldest ends first), and anything unusual falls back to a new process. Stop and a steer
// end the process as before: the next message starts a new one. A process also ends when what it
// was started with changes (model, access, the chat's instructions, MCP servers, CLAUDE.md,
// settings, skills): the key below. `defaults write de.marvinaziz.takes chatWarm -bool NO` turns
// it off.

/// A Claude Code process that waits for this chat's next message.
struct WarmClaude {
    let process: Process
    let input: FileHandle
    let output: Pipe
    let errors: Pipe
    let lines: StreamLines
    /// What it was started with (Warm.key). Another key needs a new process.
    let key: String
    /// Ends it after Warm.idle without a message.
    var timer: Task<Void, Never>?
}

enum Warm {
    static let setting = "chatWarm"
    static var on: Bool { UserDefaults.standard.object(forKey: setting) as? Bool ?? true }
    /// Tests: only a fake named claude-warm gets it (the other fakes read one ask, to its end).
    nonisolated(unsafe) static var idle: Duration = .seconds(600)
    nonisolated(unsafe) static var most = 3
    /// After the last background task ended, how long to wait for the turn it starts.
    nonisolated(unsafe) static var quiet: Duration = .seconds(60)

    /// One message as a stream-json input line.
    static func line(_ text: String) -> Data {
        let o: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// Writes all of `data`. False when the process is gone: no SIGPIPE, which would end Takes.
    static func write(_ data: Data, to h: FileHandle) -> Bool {
        let fd = h.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return true }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// Claude Code's own folder (CLAUDE_CONFIG_DIR, else ~/.claude).
    static var configDir: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// What a process was started with. Claude Code reads its instructions, settings and skills
    /// only at the start, so a change to one of these files needs a new process.
    static func key(exe: String, args: [String], env: [String: String], mcp: String?, folder: URL) -> String {
        let files = [configDir.appending(path: "CLAUDE.md"), configDir.appending(path: "settings.json"),
                     configDir.appending(path: "skills"), configDir.appending(path: "agents"),
                     folder.appending(path: "CLAUDE.md"), folder.appending(path: "AGENTS.md"),
                     folder.appending(path: ".mcp.json"), folder.appending(path: ".claude/settings.json"),
                     folder.appending(path: ".claude/settings.local.json"), folder.appending(path: ".claude/skills")]
        let times = files.map { f -> String in
            let d = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date
            return "\(f.lastPathComponent)=\(d?.timeIntervalSince1970 ?? 0)"
        }
        let servers = mcp.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.map { String(decoding: $0, as: UTF8.self) } ?? "all"
        return ([exe] + args + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + [servers] + times)
            .joined(separator: "\u{1F}")
    }
}

/// The chats whose process waits, oldest first. More than Warm.most: the oldest one ends.
@MainActor
enum WarmPool {
    private struct Entry { weak var chat: ClaudeChat? }
    private static var waiting: [Entry] = []

    static func park(_ chat: ClaudeChat) {
        waiting.removeAll { $0.chat == nil || $0.chat === chat }
        waiting.append(Entry(chat: chat))
        while waiting.count > Warm.most {
            let old = waiting.removeFirst()
            old.chat?.dropWarm()
        }
    }

    static func leave(_ chat: ClaudeChat) { waiting.removeAll { $0.chat == nil || $0.chat === chat } }

    static var count: Int { waiting.filter { $0.chat != nil }.count }
}
