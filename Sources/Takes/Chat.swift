import AppKit
import Network
import SwiftUI

// Claude in the app (2026-09-30). One Claude Code conversation per session, run by the real
// `claude` CLI on this Mac in print mode: `claude -p --output-format stream-json`. Each message
// starts the CLI once and resumes the same conversation id, so it is the same Claude as in the
// terminal: same login, skills, MCP servers and settings. It runs in the user's working folder
// (your notes repo, where the video skills live) and is told which session folder it belongs to.
//
// The conversation id and what the panel shows are kept in <session>/.claude-chat.json. "New
// conversation" moves it to <session>/.claude-chats/, where the history menu finds it again; a past
// conversation resumes the same Claude Code conversation id. The Performance board keeps its chat
// the same way in Application Support/Takes. All of it survives a quit.

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, claude, tool, error }
    var id = UUID()
    var role: Role
    var text: String
    /// Tool calls: the tool's id, so its result can mark it done.
    var toolID: String?
    var done = true
    /// When it was sent or came in. Optional: messages from before 2026-10-03 have none.
    var at: Date? = Date()

    init(role: Role, text: String, toolID: String? = nil, done: Bool = true) {
        self.role = role; self.text = text; self.toolID = toolID; self.done = done
    }

    /// A time in another date format reads as none: it must never lose the whole chat.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        toolID = try c.decodeIfPresent(String.self, forKey: .toolID)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? true
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
    }
}

struct ChatLog: Codable {
    var conversation: String
    /// False until the CLI made the conversation; then later messages resume it.
    var started = false
    var messages: [ChatMessage] = []
    /// When the last message came. Optional: logs from before 2026-10 have none.
    var updated: Date?
    /// How full Claude's context was after the last reply. Optional: added 2026-10-01.
    var context: ChatContext?
    /// Messages sent while Claude worked that have not gone out yet. Kept on disk, so a quit or a
    /// crash does not lose them: the chat sends them when it loads (2026-10-03).
    var pending: [String]?
}

/// Tokens in Claude's context window, from the usage the CLI reports with each reply.
struct ChatContext: Codable, Hashable {
    var used: Int
    var window: Int
    var fraction: Double { window > 0 ? Double(used) / Double(window) : 0 }
    /// The panel shows the meter from here on.
    static let showAt = 0.2

    /// "68k".
    static func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// A conversation in the history menu.
struct PastChat: Identifiable, Hashable {
    let file: URL
    let title: String
    let date: Date?
    let count: Int
    var id: URL { file }
}

/// Cuts Claude's output into lines, off the main thread. A tool result with a picture is one line
/// of up to 1.4 MB (a Read of a still); the chat only needs which tools finished, so such a line
/// becomes a small one with just their ids. One per process; the pipe calls it on one thread at a time.
final class StreamLines: @unchecked Sendable {
    private var buffer = Data()
    private var scanned = 0
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var out: [String] = []
            var start = buffer.startIndex
            var i = buffer.startIndex + scanned
            while let nl = buffer[i...].firstIndex(of: 0x0A) {
                out.append(Self.shrink(String(decoding: buffer[start..<nl], as: UTF8.self)))
                start = nl + 1
                i = start
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            scanned = buffer.count
            return out
        }
    }

    static func shrink(_ line: String) -> String {
        guard line.utf8.count > 64_000, line.hasPrefix(#"{"type":"user""#) else { return line }
        func ids(_ key: String) -> [String] {
            let pattern = "\"\(key)\":\"([^\"]+)\""
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
                Range($0.range(at: 1), in: line).map { String(line[$0]) }
            }
        }
        let parent = ids("parent_tool_use_id").first
        let blocks = ids("tool_use_id").map { ["type": "tool_result", "tool_use_id": $0] }
        var o: [String: Any] = ["type": "user", "message": ["content": blocks]]
        if let parent { o["parent_tool_use_id"] = parent }
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return line }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Turns the CLI's stream-json lines into chat messages. Pure, so tests can feed it lines.
struct ChatParser {
    var messages: [ChatMessage]
    var started = false
    var finished = false
    var context: ChatContext?

    init(_ messages: [ChatMessage], context: ChatContext? = nil) {
        self.messages = messages
        self.context = context
    }

    mutating func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = o["type"] as? String else { return }
        // A subagent's own steps: the panel shows only the call that started it.
        if let parent = o["parent_tool_use_id"] as? String, !parent.isEmpty { return }
        switch type {
        case "system":
            switch o["subtype"] as? String {
            case "init": started = true
            case "compact_boundary":
                // /compact, or Claude Code compacting by itself when the context is full.
                let m = o["compact_metadata"] as? [String: Any] ?? [:]
                let before = m["pre_tokens"] as? Int, after = m["post_tokens"] as? Int
                var line = "Compacted the conversation"
                if let before, let after { line += " · \(ChatContext.short(before)) → \(ChatContext.short(after)) tokens" }
                messages.append(ChatMessage(role: .tool, text: line))
                if let after { setUsed(after) }
            default: break
            }
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_start",
               let b = e["content_block"] as? [String: Any], b["type"] as? String == "text" {
                messages.append(ChatMessage(role: .claude, text: "", done: false))
            } else if e["type"] as? String == "content_block_delta",
                      let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                      let t = d["text"] as? String {
                if let i = messages.indices.last, messages[i].role == .claude, !messages[i].done {
                    messages[i].text += t
                } else {
                    messages.append(ChatMessage(role: .claude, text: t, done: false))
                }
            }
        case "assistant":
            // Each call's usage is the whole context it read: what is in the window now.
            if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                setUsed(keys.reduce(0) { $0 + (u[$1] as? Int ?? 0) })
            }
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content {
                switch b["type"] as? String {
                case "text":
                    let t = b["text"] as? String ?? ""
                    if let i = messages.indices.last, messages[i].role == .claude, !messages[i].done {
                        messages[i].text = t
                        messages[i].done = true
                    } else if !t.isEmpty {
                        messages.append(ChatMessage(role: .claude, text: t))
                    }
                case "tool_use":
                    let id = b["id"] as? String
                    let line = Self.describe(b["name"] as? String ?? "Tool", b["input"] as? [String: Any] ?? [:])
                    messages.append(ChatMessage(role: .tool, text: line, toolID: id, done: false))
                default: break
                }
            }
        case "user":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String, let i = messages.lastIndex(where: { $0.toolID == id }) {
                    messages[i].done = true
                }
            }
        case "result":
            finished = true
            closeOpen()
            // The window size comes only here. Subagents may run on smaller models: take the largest.
            let windows = (o["modelUsage"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["contextWindow"] as? Int }
            if let w = windows.max(), w > 0 { context = ChatContext(used: context?.used ?? 0, window: w) }
            if o["is_error"] as? Bool == true || (o["subtype"] as? String).map({ $0 != "success" }) == true {
                let r = o["result"] as? String ?? ""
                messages.append(ChatMessage(role: .error, text: r.isEmpty ? "The chat stopped with an error." : r))
            }
        default: break
        }
    }

    private mutating func setUsed(_ n: Int) {
        context = ChatContext(used: n, window: context?.window ?? 200_000)
    }

    /// Ends every step still marked as running.
    mutating func closeOpen() {
        for i in messages.indices where !messages[i].done { messages[i].done = true }
    }

    /// "Read script.md", "Bash · ffmpeg -i …", "get_comments".
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        let short = name.hasPrefix("mcp__") ? String(name.split(separator: "__").last ?? Substring(name)) : name
        let file = (input["file_path"] as? String ?? input["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let detail: String? = {
            switch name {
            case "Bash": return (input["description"] as? String) ?? (input["command"] as? String)
            case "Grep", "Glob": return input["pattern"] as? String
            case "Skill": return input["skill"] as? String
            case "Agent", "Task": return input["description"] as? String
            case "WebSearch": return input["query"] as? String
            default: return file
            }
        }()
        guard let detail, !detail.isEmpty else { return short.replacingOccurrences(of: "_", with: " ") }
        let one = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(short) · \(one.count > 80 ? String(one.prefix(80)) + "…" : one)"
    }
}

/// What the panel draws: a message, or a run of tool calls in a row. Runs of three or more fold up.
enum ChatItem: Identifiable, Hashable {
    case message(ChatMessage)
    case tools([ChatMessage])

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .tools(let t): return t[0].id
        }
    }

    static let foldAt = 3

    static func group(_ messages: [ChatMessage]) -> [ChatItem] {
        var items: [ChatItem] = []
        var run: [ChatMessage] = []
        func flush() {
            if run.count >= foldAt { items.append(.tools(run)) } else { items += run.map(ChatItem.message) }
            run = []
        }
        for m in messages {
            if m.role == .tool { run.append(m) } else { flush(); items.append(.message(m)) }
        }
        flush()
        return items
    }

    /// One line for a finished run: "6 steps · computer, javascript tool".
    static func summary(_ tools: [ChatMessage]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for t in tools {
            let name = t.text.components(separatedBy: " · ").first ?? t.text
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let names = order.enumerated().sorted { (counts[$0.1]!, -$0.0) > (counts[$1.1]!, -$1.0) }.map(\.1)
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(tools.count) steps · \(shown)"
    }
}

@MainActor
@Observable
final class ClaudeChat {
    /// The session folder; nil for the Performance board's chat.
    private(set) var session: URL?
    /// The open conversation, and the folder of past ones.
    private(set) var file: URL
    private(set) var archive: URL
    private(set) var messages: [ChatMessage] = [] { didSet { settle() } }
    private(set) var running = false { didSet { settle() } }
    /// What the mascot does, and whether there is a conversation. Stored, and set only when they
    /// change: a view that shows just these does not redraw for each streamed word (2026-10-02).
    private(set) var mood: LiveMascot.Mood = .idle
    private(set) var hasMessages = false
    private(set) var context: ChatContext?
    /// A reply came while the panel was shut.
    var unread = false
    @ObservationIgnored private var log: ChatLog
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var parser: ChatParser?
    @ObservationIgnored private var stderr = Data()

    nonisolated static func file(_ session: URL) -> URL { session.appending(path: ".claude-chat.json") }
    nonisolated static var boardFolder: URL { URL.applicationSupportDirectory.appending(path: "Takes") }

    /// Which board a chat without a session belongs to: "board" (Performance) or "comments".
    let boardName: String

    init(session: URL?, board: String = "board") {
        self.session = session
        boardName = board
        let file = session.map(Self.file) ?? Self.boardFolder.appending(path: "\(board)-chat.json")
        self.file = file
        archive = session?.appending(path: ".claude-chats") ?? Self.boardFolder.appending(path: "\(board)-chats")
        let log = Self.load(file) ?? ChatLog(conversation: UUID().uuidString.lowercased())
        self.log = log
        messages = log.messages
        context = log.context
        queued = log.pending ?? []
        settle()
        // Messages that waited when Takes quit or crashed go out now, in the same conversation.
        if !queued.isEmpty { Task { @MainActor [weak self] in self?.sendPending() } }
    }

    /// Sends what is queued, if nothing runs.
    func sendPending() {
        // Only the app (or a test with a fake claude): a test run must never start the real one.
        guard Bundle.main.bundleURL.pathExtension == "app" || Self.claudeOverride != nil else { return }
        guard !running, !queued.isEmpty, let claude = Self.claudePath else { return }
        let title = session.flatMap { Store.readMeta($0)?.title } ?? session?.lastPathComponent ?? boardName
        runQueued(claude: claude, title: title, onStage: nil, cutOff: true)
    }

    private func settle() {
        let m = currentMood
        if m != mood { mood = m }
        if hasMessages == messages.isEmpty { hasMessages = !messages.isEmpty }
    }

    private static func load(_ url: URL) -> ChatLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ChatLog.self, from: data)
    }

    /// `create`: make the folder if it is missing. Never for a session folder: a renamed session
    /// would come back as an empty copy under its old name (2026-10-01).
    private static func write(_ log: ChatLog, to url: URL, create: Bool) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        if create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let data = try? enc.encode(log) { try? data.write(to: url, options: .atomic) }
    }

    /// Claude (or Finder) renamed the session or moved it to another project: its folder took the
    /// chat file along. Find that folder by the conversation id and use it from now on.
    @discardableResult
    func follow() -> Bool {
        guard let old = session, !FileManager.default.fileExists(atPath: old.path) else { return false }
        guard let found = Self.find(log.conversation, under: old.deletingLastPathComponent().deletingLastPathComponent()) else { return false }
        session = found
        file = Self.file(found)
        archive = found.appending(path: ".claude-chats")
        return true
    }

    static func find(_ conversation: String, under root: URL) -> URL? {
        let fm = FileManager.default
        for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for s in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where load(Self.file(s))?.conversation == conversation {
                return s.standardizedFileURL
            }
        }
        return nil
    }

    /// Where the CLI runs: the folder chosen in the menu, else your notes repo, else the session.
    static var folder: URL {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: "claudeFolder"), fm.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        let life = fm.homeDirectoryForCurrentUser.appending(path: "Documents/Takes Notes")
        return fm.fileExists(atPath: life.path) ? life : fm.homeDirectoryForCurrentUser
    }

    /// Every chat runs in the user's own Chrome next to the others (scouts, the poster, stats
    /// readers). 2026-10-03: agents opened a new tab for each post they read and left them open,
    /// so each one now gets exactly one tab, navigates it, and closes it at the end. The last tab
    /// stays (blank): closing it drops the tab group, and the next new tab then opens a window.
    nonisolated static let browserRules = """
        Browser rules, always: only the Claude in Chrome tools. One tab is yours: call \
        tabs_create_mcp once, at your first browser step, write down the tabId it returns and pass \
        it on every browser call. To read the next page or post, navigate that same tab: never \
        open a second tab. Other chats work in the same Chrome: never pick a tab from \
        tabs_context_mcp, never use or close a tab you did not create. If a call says your tab is \
        gone, create one new tab and use only that one. Never activate or raise a window, never \
        switch the visible tab, never bring Chrome to the front, never use the system clipboard. \
        On a login wall, a CAPTCHA or a rate-limit message, stop and say so. When the task is \
        done, close your tab, unless tabs_context_mcp shows it is the last tab in the group: then \
        navigate it to about:blank and leave it open (an empty group makes the next new tab open \
        a window).
        """
    /// "bypassPermissions" (full access, like his terminal) or "acceptEdits".
    static var access: String { UserDefaults.standard.string(forKey: "claudeAccess") ?? "bypassPermissions" }

    /// The login shell's PATH, so Claude finds ffmpeg, python and the rest. Read once.
    static let shellPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" : s
    }()

    static let commentsAsk = "I left comments in Takes, some maybe on older versions. Read them with get_comments, "
        + "fix them in the newest version, and reply to each one (resolve=true when it is fixed)."

    /// Marks the open comments added after a typed message (2026-10-03): The user often means one
    /// of them, and Claude did not know they were there. Since 2026-10-04 every typed message in a
    /// session gets them, not only one with "@comments": he wrote about v19 and Claude never saw
    /// his open comment on v17. The chat shows the message without it.
    nonisolated static let commentsMark = "\n\n[@comments: open comments in Takes on this session"

    /// "@comments" typed in the box is taken out of the message: the comments go with every message.
    nonisolated static let commentsToken = "@comments"
    private nonisolated static let commentsTokenPattern = #"(?<!\S)@comments(?!\w)"#

    nonisolated static func mentionsComments(_ text: String) -> Bool {
        text.range(of: commentsTokenPattern, options: .regularExpression) != nil
    }

    /// The message without "@comments", as the chat shows it.
    nonisolated static func withoutCommentsToken(_ text: String) -> String {
        text.replacingOccurrences(of: commentsTokenPattern + #"[ \t]?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message, then a short list of the open comments. Get_comments has the frames.
    nonisolated static func withComments(_ text: String, _ comments: [Comment]) -> String {
        let open = comments.filter(\.open)
        guard !open.isEmpty else { return text }
        let lines = open.prefix(20).map { c -> String in
            let where_ = c.shot.map { "shot \($0)" } ?? "\(c.file) @ \(c.timeLabel)"
            let said = c.text.count > 300 ? String(c.text.prefix(300)) + "…" : c.text
            return "- \(c.id) · \(where_) · \(said.replacingOccurrences(of: "\n", with: " "))"
        }
        let more = open.count > 20 ? "\n- and \(open.count - 20) more" : ""
        return text + commentsMark + ", some on older versions of a file. I may mean one of them; get_comments "
            + "has the frames and replies. When your work fixes one, reply_comment with resolve=true.]\n"
            + lines.joined(separator: "\n") + more
    }

    /// A message the user sent while Claude was working. The run stops, and the conversation goes
    /// on with this message (2026-10-02: he wants to steer a run he watches, not wait it out).
    private var steer: String?
    /// Claude is stopping to read a message the user sent while it worked.
    var steering: Bool { steer != nil }

    /// Messages the user sent while Claude worked, sent together when the run ends (2026-10-02:
    /// like the terminal, Return queues; ⌘Return steers). Saved with the log (2026-10-03).
    /// Files dragged or pasted in, sent with the next message (ChatAttach). Not saved.
    var attachments: [URL] = []

    var queued: [String] = [] {
        didSet {
            let p = queued.isEmpty ? nil : queued
            if log.pending != p { log.pending = p; save() }
        }
    }

    /// Tests point this at a fake claude.
    nonisolated(unsafe) static var claudeOverride: String?
    static var claudePath: String? { claudeOverride ?? Namer.claudePath }

    /// Counts runs. A run's late callbacks (output, its end) are dropped once a newer run or a
    /// reset took over (2026-10-03).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pipes: [Pipe] = []
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// When the watchdog first saw the process gone while the chat still said it runs.
    @ObservationIgnored private var deadSince: Date?
    /// The user pressed Stop: the run ends without going on to the queue.
    @ObservationIgnored private var stopped = false

    /// Keeps the Mac from sleeping by itself while Claude works. Closing the lid still sleeps it.
    @ObservationIgnored private var awake: NSObjectProtocol?
    /// A run that lost its connection (the lid closed, the Wi-Fi dropped) goes on by itself once
    /// the Mac is online again (2026-10-03). At most 3 times in a row, then the user decides.
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var resumes = 0
    /// Waiting to go on after a lost connection.
    private(set) var reconnecting = false
    static let goOnDropped = "The connection dropped while you worked (the Mac slept or went offline). Go on where you stopped. Check what you already did before you repeat a step: a subagent that was cut off can be started again."

    /// An error that a lost connection or a busy server causes, not one a retry cannot fix.
    nonisolated static func isConnectionError(_ text: String) -> Bool {
        let t = text.lowercased()
        let never = ["rate limit", "usage limit", "credit", "401", "403", "login", "authenticat", "invalid api key", "prompt is too long"]
        if never.contains(where: t.contains) { return false }
        let drops = ["connection", "network", "econnreset", "econnrefused", "etimedout", "enotfound", "eai_again",
                     "fetch failed", "socket", "timed out", "timeout", "offline", "overloaded", "api error: 5", "529", "503", "502"]
        return drops.contains(where: t.contains)
    }
    /// Claude is compacting: a steer would kill it, so every message queues.
    var compacting: Bool { running && lastAsk.map { Self.isCompact($0.text) } == true }

    nonisolated static func isCompact(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "/compact" || t.hasPrefix("/compact ") || t.hasPrefix("/compact\n")
    }

    /// `now`: stop the run and go on with this message (steer). Otherwise it waits its turn.
    /// `origin`: where on his phone the user sent it from (Phone.origin); nil from the Mac.
    func send(_ text: String, title: String, onStage: URL?, now: Bool = false, origin: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // The newest message decides: a steer or queued message from the Mac clears the phone's note.
        self.origin = origin
        if text != Self.goOnDropped { cancelResume(); resumes = 0 }
        // A run whose process is gone cannot take a message: settle it first (2026-10-03: a steer
        // into a dead run waited forever, and the chat said "working" for good).
        heal(force: true)
        // /compact must be the whole message: as a steer it would become "I interrupted you.
        // /compact", which Claude reads as text and nothing compacts (2026-10-03).
        if running && (!now || compacting || Self.isCompact(text)) {
            queued.append(text)
            return
        }
        if running {
            append(ChatMessage(role: .user, text: text))
            steer = (steer ?? "I interrupted you.") + "\n" + text
            end(process)
            return
        }
        guard let claude = Self.claudePath else {
            append(ChatMessage(role: .error, text: "Can't find the claude command. Install Claude Code, then try again."))
            return
        }
        if Self.isCompact(text) && !log.started {
            append(ChatMessage(role: .error, text: "Nothing to compact yet."))
            return
        }
        append(ChatMessage(role: .user, text: text))
        run(text, claude: claude, title: title, onStage: onStage, recap: nil)
    }

    /// Claude Code deletes old conversations (after 30 days by default), and one made in another
    /// folder cannot be resumed here. Then start a new one and hand it what the panel shows.
    private var lastAsk: (text: String, title: String, onStage: URL?)?
    /// Where the newest message came from when the user sent it from his phone, told to Claude with
    /// each run: else it takes him to be at this panel and misreads "this" (2026-10-03).
    private var origin: String?

    private func run(_ text: String, claude: String, title: String, onStage: URL?, recap: String?) {
        follow()
        lastAsk = (text, title, onStage)
        unread = false
        stopped = false
        deadSince = nil
        generation += 1
        let gen = generation
        running = true
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Takes is working")
        }
        parser = ChatParser(messages, context: context)
        stderr = Data()

        var context: String
        if let session {
            context = """
            The user is talking to you from the chat panel inside his Takes app. This conversation \
            belongs to one Takes session: "\(title)", folder \(session.path). "This video" and \
            "this session" mean that folder. Use the takes MCP tools and the video skills as you \
            would from the terminal. He reads your replies in a narrow panel: keep them short, \
            no tables, no headings. He often works in another session while you run: show a \
            finished result only with open_in_app, and never open files or apps on his screen \
            (hyperframes preview needs --no-open). When you show thumbnails, \
            put each image path on its own line: its card has a "Use as cover" button. If \
            posts/linkedin.md has a cover: field, start every new edit with that image for \
            0.1 s (see the takes-video-edit skill) and set cover_video to the new file. When he \
            brainstorms a video idea or asks for a storyboard, use the takes-storyboard skill: script \
            first, then set_storyboard (it shows on the Storyboard tab). A blog post or article \
            is posts/article.md (set_post platform=article: markdown with his blog's components, \
            shown as your blog shows it); the LinkedIn and X articles and the video come from it.
            """
            if let onStage {
                context += " Right now he has \(CommentStore.path(of: onStage, in: session)) open in the player."
            } else if UserDefaults.standard.string(forKey: "rightTab") == "post",
                      let p = PostPlatform(rawValue: UserDefaults.standard.string(forKey: "postPlatform") ?? "") {
                // Which post he looks at, so "make it shorter" lands on the right one (2026-10-04).
                context += " Right now he has the Post tab open on the \(p.name) side (\(p.rel))."
            }
        } else if boardName.hasPrefix("comments") {
            context = CopilotAsk.context
        } else if boardName == "styles" {
            context = """
            The user is talking to you from the Styles board inside his Takes app. It shows his named \
            styles (~/Movies/Takes/_library/styles/) side by side: each style's preview.mp4, its \
            guide, tokens and parts, with your notes. Use the takes MCP tools: get_library, \
            create_style, save_to_library, get_comments and reply_comment with library \
            'style:<Name>'. A change to a part is a new version, never an overwrite. He often works \
            elsewhere while you run: never open files or apps on his screen \
            (hyperframes preview needs --no-open). He reads your replies in a narrow panel: keep them short, no tables, no headings.
            """
        } else {
            context = """
            The user is talking to you from the Performance board inside his Takes app. The board \
            shows his LinkedIn and X numbers from ~/Movies/Takes/_library/social.json and \
            redraws by itself when that file changes. To update it, follow the "Social data" \
            runbook in your notes repo tracking/README.md: run python3 tracking/scripts/refresh_social.py \
            from your notes repo, and when a source is OLD get the export from his \
            signed-in Chrome. Each NEED line is a post still missing numbers: read it on its page \
            as the runbook says, one post after the other in your one tab. Done means no OLD and \
            no NEED line. He reads your replies in \
            a narrow panel: keep them short, no tables, no headings.
            """
        }
        if !boardName.hasPrefix("comments") || session != nil { context += "\n\n" + Self.browserRules }
        context += "\n\n" + ChatRefs.howTo
        if let note = Releaser.agentNote { context += "\n\n" + note }
        if let origin { context += "\n\n" + origin }
        if let recap {
            context += "\n\nThe earlier conversation in this panel could not be resumed. What it showed:\n" + recap
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        // Print mode loads Claude in Chrome only with --chrome (the terminal enables it by itself).
        p.arguments = ["-p", "--chrome", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--permission-mode", Self.access, "--append-system-prompt", context]
            + (log.started ? ["--resume", log.conversation] : ["--session-id", log.conversation])
        p.currentDirectoryURL = Self.folder
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = Self.shellPath
        p.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        // Lines are cut and big tool results shrunk here, on the pipe's thread; the main thread
        // only parses what the chat shows (2026-10-03).
        let lines = StreamLines()
        self.lines = lines
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let got = lines.feed(d)
            DispatchQueue.main.async { if self?.generation == gen { self?.take(got) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { if self?.generation == gen { self?.stderr.append(d) } }
        }
        p.terminationHandler = { [weak self] proc in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            // What is left, without waiting for the end of the pipe: a tool's child that outlives
            // Claude keeps the pipe open, and waiting for it kept the chat "working" (2026-10-03).
            let rest = lines.feed(Self.drain(output.fileHandleForReading))
            let status = proc.terminationStatus, reason = proc.terminationReason
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if !rest.isEmpty { self.take(rest) }
                self.finish(status: status, killed: reason == .uncaughtSignal)
            }
        }
        do { try p.run() } catch {
            running = false
            letSleep()
            append(ChatMessage(role: .error, text: "Couldn't start the chat: \(error.localizedDescription)"))
            return
        }
        process = p
        pipes = [output, errors]
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
        // Checks every 2 s that the process still lives; one that is gone settles the chat.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.generation == gen, self.running else { return }
                self.heal()
            }
        }
    }

    func stop() {
        steer = nil; queued = []; cancelResume(); stopped = true
        end(process)
        heal(force: true)
    }

    /// SIGTERM; a process that still runs 5 s later gets SIGKILL, and so does what it started.
    private func end(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            guard p.isRunning, p.processIdentifier == pid else { return }
            for child in Self.descendants(pid) { kill(child, SIGKILL) }
            kill(pid, SIGKILL)
        }
    }

    /// Every process below `pid`, children first.
    nonisolated static func descendants(_ pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let kids = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        return kids.flatMap { descendants($0) + [$0] }
    }

    /// Reads what a pipe holds now and stops at the first empty read, never waiting for its end.
    nonisolated static func drain(_ h: FileHandle) -> Data {
        let fd = h.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return out
    }

    /// The chat says it runs but its process is gone and its end never came (2026-10-03: a chat
    /// showed "Claude quit (code 15)." and "Claude is working" for good). Settles it as an end.
    /// The watchdog waits 2 s for the normal end first; `force` (a new message, the phone asking)
    /// does not wait.
    @discardableResult
    func heal(force: Bool = false) -> Bool {
        guard running else { deadSince = nil; return false }
        if let p = process, p.isRunning { deadSince = nil; return false }
        if !force {
            guard let since = deadSince else { deadSince = Date(); return false }
            guard -since.timeIntervalSinceNow >= 2 else { return false }
        }
        let p = process
        p?.terminationHandler = nil
        pipes.forEach { $0.fileHandleForReading.readabilityHandler = nil }
        // An end already on its way to the main queue must not finish a second time.
        generation += 1
        if let out = pipes.first {
            let rest = Self.drain(out.fileHandleForReading)
            if !rest.isEmpty, let lines { take(lines.feed(rest)) }
        }
        let gone = p.map { !$0.isRunning } ?? true
        finish(status: gone ? p?.terminationStatus ?? -1 : -1,
               killed: gone && p?.terminationReason == .uncaughtSignal)
        return true
    }

    /// Lets go of the running process: its output and its end no longer reach this chat.
    private func detach() -> Process? {
        let p = process
        process = nil
        p?.terminationHandler = nil
        pipes.forEach { $0.fileHandleForReading.readabilityHandler = nil }
        pipes = []
        watchdog?.cancel()
        watchdog = nil
        generation += 1
        return p
    }

    private func letSleep() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    private func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
        reconnecting = false
    }

    /// Waits until the Mac is online, then sends the go-on message into the same conversation.
    private func resumeWhenOnline(title: String, onStage: URL?) {
        resumes += 1
        reconnecting = true
        let wait = [10, 30, 60][min(resumes, 3) - 1]
        resumeTask = Task { [weak self] in
            await Online.wait()
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, !self.running, let claude = Self.claudePath else { return }
            self.reconnecting = false
            self.resumeTask = nil
            self.append(ChatMessage(role: .user, text: Self.goOnDropped))
            self.run(Self.goOnDropped, claude: claude, title: title, onStage: onStage, recap: nil)
        }
    }

    /// The app quits: the terminationHandler will not get to run, so save now. The CLI keeps what
    /// it did so far, and the next message resumes the conversation from there.
    func quit() {
        guard running, let process = detach() else { return }
        // A steer that did not go out yet waits in the queue, which is saved: it goes next launch.
        if let steer { queued.append(steer.replacingOccurrences(of: "I interrupted you.\n", with: "")) }
        steer = nil
        process.terminate()
        if var parser {
            parser.closeOpen()
            if parser.started { log.started = true }
            messages = parser.messages
        }
        parser = nil
        running = false
        letSleep()
        cancelResume()
        messages.append(ChatMessage(role: .error, text: Self.cutOff))
        save()
    }

    static let cutOff = "Takes quit while the chat was working."
    static let goOn = "Takes quit while you were working. Go on where you stopped."
    /// The last reply was cut off by a quit.
    var wasCutOff: Bool { !running && messages.last?.role == .error && messages.last?.text == Self.cutOff }

    /// A new conversation. The old one goes to the history (and stays in Claude Code's).
    func reset() {
        // The old run must not finish into the new conversation (2026-10-03: the phone's "Run now"
        // resets and sends at once; the old run's end then put the old messages back and dropped
        // the new ask from the queue).
        steer = nil; queued = []; cancelResume()
        if let p = detach() {
            end(p)
            if var parser {
                parser.closeOpen()
                if parser.started { log.started = true }
                messages = parser.messages
            }
            parser = nil
            running = false
            letSleep()
        }
        shelve()
        log = ChatLog(conversation: UUID().uuidString.lowercased())
        messages = []
        context = nil
        save()
    }

    /// Past conversations, newest first.
    func past() -> [PastChat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> PastChat? in
            guard let log = Self.load(url), !log.messages.isEmpty else { return nil }
            let first = log.messages.first { $0.role == .user }?.text ?? "Conversation"
            let line = first.split(separator: "\n").first.map(String.init) ?? first
            return PastChat(file: url, title: line, date: log.updated, count: log.messages.filter { $0.role == .user }.count)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Opens a past conversation. The open one goes to the history first.
    func resume(_ past: PastChat) {
        guard !running, let saved = Self.load(past.file) else { return }
        shelve()
        try? FileManager.default.removeItem(at: past.file)
        log = saved
        messages = saved.messages
        context = saved.context
        unread = false
        save()
    }

    func forget(_ past: PastChat) { try? FileManager.default.removeItem(at: past.file) }

    /// Keeps the open conversation in the history, if it has anything in it.
    private func shelve() {
        guard !messages.isEmpty else { return }
        log.messages = messages
        log.context = context
        if session != nil { follow() }
        Self.write(log, to: archive.appending(path: "\(log.conversation).json"), create: true)
    }

    private func take(_ lines: [String]) {
        for line in lines { parser?.consume(line) }
        if parser?.started == true && !log.started { log.started = true }
        publish()
    }

    // A reply streams in a few words per line. Showing each one made the panel regroup and compare
    // every message per word, in each chat that streams. Show the parser's state at most 10 times
    // a second instead (2026-10-01). finish() shows the final state at once.
    /// The current process's line cutter (the watchdog drains through it too).
    @ObservationIgnored private var lines: StreamLines?
    @ObservationIgnored private var lastShown = Date.distantPast
    @ObservationIgnored private var showDue = false

    private func publish() {
        let wait = 0.1 - Date().timeIntervalSince(lastShown)
        guard wait <= 0 else {
            if !showDue {
                showDue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.showDue = false
                    self?.publish()
                }
            }
            return
        }
        guard let parser else { return }
        lastShown = Date()
        if parser.messages != messages { messages = parser.messages }
        if parser.context != context { context = parser.context }
    }

    private func finish(status: Int32, killed: Bool) {
        guard running else { return }
        watchdog?.cancel()
        watchdog = nil
        deadSince = nil
        pipes = []
        var parser = self.parser ?? ChatParser(messages, context: context)
        let why = String(decoding: stderr, as: UTF8.self)
        if !killed, why.contains("No conversation found"), log.started, let ask = lastAsk, let claude = Self.claudePath {
            // Drop the failed reply; keep the question.
            if let q = messages.lastIndex(where: { $0.role == .user }) { messages = Array(messages[...q]) }
            log = ChatLog(conversation: UUID().uuidString.lowercased(), messages: messages)
            let recap = Self.recap(messages.dropLast())
            self.parser = nil
            process = nil
            run(ask.text, claude: claude, title: ask.title, onStage: ask.onStage, recap: recap)
            return
        }
        parser.closeOpen()
        // SIGTERM ends the CLI either by the signal itself or by its handler (exit 143).
        let signal: Int32? = killed ? status : (status > 128 && status <= 128 + 31 ? status - 128 : nil)
        if steer != nil {
            // The run stopped to read the user's message: no error line (2026-10-03: a steer showed
            // "Claude quit (code 15).").
        } else if stopped {
            parser.messages.append(ChatMessage(role: .error, text: "Stopped."))
        } else if !parser.finished, let signal, signal == SIGTERM || signal == SIGKILL || signal == SIGINT || signal == SIGHUP {
            parser.messages.append(ChatMessage(role: .error, text: "The chat was stopped from outside Takes (signal \(signal))."))
        } else if !parser.finished && status != 0 {
            let why = why.trimmingCharacters(in: .whitespacesAndNewlines)
            parser.messages.append(ChatMessage(role: .error, text: why.isEmpty ? "The chat quit (code \(status))." : String(why.suffix(400))))
        }
        // The run ended on a lost connection: go on by itself once the Mac is back online.
        // Only a conversation that exists can go on.
        let last = parser.messages.last
        let dropped = !killed && steer == nil && last?.role == .error && (log.started || parser.started)
            && Self.isConnectionError((last?.text ?? "") + " " + why)
        // A resume that fails before the conversation exists would fail again: start over next time.
        if parser.started { log.started = true }
        messages = parser.messages
        context = parser.context
        self.parser = nil
        process = nil
        running = false
        letSleep()
        unread = true
        save()
        if dropped, resumes < 3, let ask = lastAsk {
            resumeWhenOnline(title: ask.title, onStage: ask.onStage)
        } else if let steer, let ask = lastAsk, let claude = Self.claudePath {
            self.steer = nil
            run(steer, claude: claude, title: ask.title, onStage: ask.onStage, recap: nil)
        } else if !stopped, !queued.isEmpty, let ask = lastAsk, let claude = Self.claudePath {
            // Also after a kill from outside: what the user sent while it ran goes on in the same
            // conversation, with no tap from him (2026-10-03).
            runQueued(claude: claude, title: ask.title, onStage: ask.onStage, cutOff: !parser.finished)
        }
    }

    /// Sends the queue as one message. /compact goes alone, the rest waits for it.
    private func runQueued(claude: String, title: String, onStage: URL?, cutOff: Bool) {
        guard !queued.isEmpty else { return }
        let next: String
        if Self.isCompact(queued[0]) {
            next = queued.removeFirst()
        } else {
            let n = queued.firstIndex(where: Self.isCompact) ?? queued.count
            next = queued[..<n].joined(separator: "\n\n")
            queued.removeFirst(n)
        }
        // A message the panel shows already (a steer saved at a quit) is not shown twice.
        if messages.last(where: { $0.role == .user })?.text != next { append(ChatMessage(role: .user, text: next)) }
        // Claude hears that its last run did not finish; the panel shows only the user's words.
        let ask = cutOff && !Self.isCompact(next) ? Self.cutOffNote + next : next
        run(ask, claude: claude, title: title, onStage: onStage, recap: nil)
    }

    static let cutOffNote = "(Your last run was cut off before it finished. Check what you already did before you repeat a step.)\n\n"

    /// The last messages as plain lines, for a new conversation to pick up from.
    static func recap(_ messages: some Collection<ChatMessage>) -> String {
        messages.suffix(30).compactMap { m in
            switch m.role {
            case .user: return "The user: \(m.text)"
            case .claude: return "You: \(m.text)"
            case .tool: return "  (\(m.text))"
            case .error: return nil
            }
        }.joined(separator: "\n")
    }

    private func append(_ m: ChatMessage) {
        messages.append(m)
        if parser != nil { parser?.messages.append(m) }
        save()
    }

    private func save() {
        if log.messages != messages { log.updated = Date() }
        log.messages = messages
        log.context = context
        if session != nil {
            follow()
            guard let now = session, FileManager.default.fileExists(atPath: now.path) else { return }
            Self.write(log, to: file, create: false)
        } else {
            Self.write(log, to: file, create: true)
        }
    }
}

/// One chat per session folder, kept while the app runs so a reply goes on when you switch.
@MainActor
@Observable
final class ChatHub {
    /// Open or shut, as at the last quit.
    var open = UserDefaults.standard.bool(forKey: "chatOpen") {
        didSet { UserDefaults.standard.set(open, forKey: "chatOpen") }
    }
    /// Half screen: the chat takes the right side of the window instead of floating.
    var docked = UserDefaults.standard.bool(forKey: "chatDocked") {
        didSet { UserDefaults.standard.set(docked, forKey: "chatDocked") }
    }
    private var chats: [URL: ClaudeChat] = [:]
    /// The Performance board's chat. Not tied to a session.
    let board = ClaudeChat(session: nil)
    /// The Comments board's chats: one finds posts, one posts approved comments. Two chats, so
    /// both can run at once (2026-10-02).
    let comments = ClaudeChat(session: nil, board: "comments")
    let commentsPost = ClaudeChat(session: nil, board: "comments-post")
    /// The Styles board's chat: new styles, previews, fixes to parts.
    let styles = ClaudeChat(session: nil, board: "styles")
    /// Which of the two the Comments panel shows: "find" or "post".
    var commentsLane = "find"
    var commentsChat: ClaudeChat { commentsLane == "post" ? commentsPost : comments }

    /// The app quits: stop every running reply and save where it got to.
    func stopAll() { chats.values.forEach { $0.quit() }; board.quit(); comments.quit(); commentsPost.quit(); styles.quit() }

    /// The chat of a session, if it has one open this run. Never makes one (the sidebar asks).
    func existing(_ session: URL) -> ClaudeChat? { chats[session.standardizedFileURL] }

    /// Every session chat opened this run (the phone server watches them).
    var all: [ClaudeChat] { Array(chats.values) }

    func chat(_ session: URL) -> ClaudeChat {
        let key = session.standardizedFileURL
        if let c = chats[key] { return c }
        // A renamed or moved session: its chat (maybe still replying) goes on under the new folder.
        for (old, c) in chats where c.follow() || (c.session != old) {
            chats[old] = nil
            if let now = c.session { chats[now] = c }
        }
        if let c = chats[key] { return c }
        let c = ClaudeChat(session: key)
        chats[key] = c
        return c
    }
}

// MARK: - The panel

/// The round button at the bottom right, and the panel it opens.
struct ChatCorner: View {
    @Environment(AppModel.self) var app
    var hub: ChatHub
    var doc: SessionDoc

    var body: some View {
        ChatCornerBody(hub: hub, target: ChatTarget(hub: hub, doc: doc))
            .id(doc.url)
    }
}

/// The Performance board's round button and panel.
struct BoardChatCorner: View {
    var hub: ChatHub
    var comments = false
    var styles = false
    var body: some View {
        ChatCornerBody(hub: hub, target: comments ? ChatTarget.comments(hub)
                                       : styles ? ChatTarget(chat: hub.styles, title: "Styles", session: nil)
                                                  : ChatTarget(chat: hub.board, title: "Performance", session: nil))
            .id(comments ? hub.commentsLane : styles ? "styles" : "board")
    }
}

/// Which conversation a panel shows: a session's, or the board's (`session` nil).
struct ChatTarget {
    let chat: ClaudeChat
    let title: String
    let session: URL?

    init(chat: ClaudeChat, title: String, session: URL?) {
        self.chat = chat; self.title = title; self.session = session
    }

    @MainActor init(hub: ChatHub, doc: SessionDoc) {
        self.init(chat: hub.chat(doc.url), title: doc.meta.title, session: doc.url)
    }

    /// The Comments chat the panel shows now: finding or posting.
    @MainActor static func comments(_ hub: ChatHub) -> ChatTarget {
        ChatTarget(chat: hub.commentsChat, title: hub.commentsLane == "post" ? "Comments · posting" : "Comments · finding", session: nil)
    }
}

/// Where the half-screen chat goes. `replace`: it takes the place of the content (the right
/// pane next to the player); else it sits beside the content as a column.
struct ChatSlot<Content: View>: View {
    var hub: ChatHub
    let target: ChatTarget?
    var replace = false
    var active = true
    @ViewBuilder var content: Content

    init(hub: ChatHub, target: ChatTarget?, replace: Bool = false, active: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.hub = hub; self.target = target; self.replace = replace; self.active = active
        self.content = content()
    }

    init(hub: ChatHub, doc: SessionDoc?, replace: Bool = false, active: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(hub: hub, target: doc.map { ChatTarget(hub: hub, doc: $0) }, replace: replace,
                  active: active, content: content)
    }

    // One layout in every state, so the content (and a video playing in it) is never rebuilt
    // when the chat opens, docks or floats (2026-09-30).
    var body: some View {
        let show = hub.open && hub.docked && active
        GeometryReader { g in
            HStack(spacing: 0) {
                // The content takes its new width at once; only the chat slides. Squeezed frame
                // by frame, a grid of tiles or a video reflows on every step (2026-10-02).
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transaction(value: show) { $0.animation = nil }
                    .overlay {
                        if show && replace, let target {
                            DockedChat(hub: hub, target: target)
                                .transition(.opacity.combined(with: .offset(x: 16)))
                        }
                    }
                if show && !replace, let target {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    DockedChat(hub: hub, target: target)
                        .frame(width: max(360, g.size.width * 0.42))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(Theme.spring, value: show)
    }
}

private struct DockedChat: View {
    var hub: ChatHub
    let target: ChatTarget
    var body: some View {
        ChatPanel(hub: hub, chat: target.chat, target: target, docked: true)
            .id(target.session?.path ?? target.chat.boardName)
            .onAppear { target.chat.unread = false }
    }
}

private struct ChatCornerBody: View {
    @Environment(AppModel.self) var app
    var hub: ChatHub
    var chat: ClaudeChat
    let target: ChatTarget
    @State private var hover = false

    init(hub: ChatHub, target: ChatTarget) {
        self.hub = hub; self.chat = target.chat; self.target = target
    }
    @State private var openComments = 0

    var body: some View {
        let _ = Perf.body("ChatCornerBody")
        VStack(alignment: .trailing, spacing: 12) {
            if hub.open && !hub.docked {
                ChatPanel(hub: hub, chat: chat, target: target)
                    .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                if openComments > 0 && !chat.running && !hub.open { handOff }
                button
            }
        }
        .opacity(hub.open && hub.docked ? 0 : 1)
        .allowsHitTesting(!(hub.open && hub.docked))
        .animation(Theme.spring, value: hub.open)
        .animation(Theme.spring, value: hub.docked)
        .animation(Theme.spring, value: hover)
        .animation(Theme.spring, value: openComments > 0 && !chat.running)
        .animation(Theme.motion, value: chat.unread)
        .onChange(of: hub.open) { _, open in if open { chat.unread = false } }
        .onAppear(perform: countComments)
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
            if let session = target.session, FileWatch.touches(n, session) { countComments() }
        }
    }

    /// One click hands the open comments to Claude, without opening the chat.
    private var handOff: some View {
        Button {
            chat.send(ClaudeChat.commentsAsk, title: target.title, onStage: app.preview)
        } label: {
            Label("Let Takes fix \(openComments) comment\(openComments == 1 ? "" : "s")", systemImage: "text.bubble.fill")
                .font(Theme.sans(12.5, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 34)
                .background(Theme.accent, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
        .buttonStyle(PressStyle())
        .help("Takes reads your open comments, fixes them and replies to each one")
        .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
    }

    private func countComments() {
        openComments = target.session.map { CommentStore.read($0).comments.filter(\.open).count } ?? 0
    }

    private var button: some View {
        Button { hub.open.toggle() } label: {
            ZStack {
                Rectangle().fill(hub.open ? Theme.ink : Theme.accent)
                if hub.open {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.paper)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    // Like the app icon (2026-10-03): the mascot sits on the bottom of the
                    // circle and the edge cuts its body, so it does not float in blue.
                    LiveMascot(mood: chat.mood, size: 44).offset(y: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 46, height: 46)
            // One clip for fill and mascot: two soft circle edges on top of each other left a
            // thin blue ring around the white (2026-10-03).
            .clipShape(Circle())
            .overlay(alignment: .topTrailing) {
                if chat.unread && !hub.open {
                    Circle().fill(Theme.accent).frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Theme.paper, lineWidth: 2))
                        .offset(x: 1, y: -1)
                        .transition(.scale)
                }
            }
            .scaleEffect(hover ? 1.06 : 1)
            .shadow(color: .black.opacity(0.18), radius: hover ? 12 : 8, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(hub.open ? "Close the chat (⇧⌘L)" : "Talk to Takes about this session (⇧⌘L)")
    }
}

/// A thin ring that turns while Claude works (a layer animation: Motion.swift).
private struct Spinner: View {
    var color: Color = Theme.muted
    var body: some View { LayerSpinner(color: color, alpha: 0.9) }
}

private struct ChatPanel: View {
    @Environment(AppModel.self) var app
    var hub: ChatHub
    var chat: ClaudeChat
    let target: ChatTarget
    var docked = false
    @State private var openComments = 0
    @State private var tools = false
    /// Hides the tools 2.5 s after the pointer leaves them, unless it comes back first.
    @State private var hideTools: Task<Void, Never>?
    @State private var showHistory = false
    @AppStorage("claudeAccess") private var access = "bypassPermissions"
    @AppStorage("scriptBeside") private var scriptBeside = false
    @AppStorage("rightTab") private var rightTab = "script"
    @State private var dropping = false

    var body: some View {
        let _ = Perf.body("ChatPanel")
        VStack(spacing: 0) {
            header
            Rule()
            messages
            // Its own view: a typed letter or a dictated word redraws the box, not the panel and
            // its transcript (ChatPanel built 60 times in 10 s while the user dictated; 2026-10-03).
            ChatComposer(chat: chat, target: target, openComments: openComments)
        }
        .frame(width: docked ? nil : 390, height: docked ? nil : 560)
        .frame(maxWidth: docked ? .infinity : nil, maxHeight: docked ? .infinity : nil)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: docked ? 0 : 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border, lineWidth: 0.5).opacity(docked ? 0 : 1))
        .overlay { if dropping { DropHint() } }
        .onDrop(of: ChatAttach.types, isTargeted: $dropping) { ChatAttach.take($0, into: chat) }
        .shadow(color: .black.opacity(docked ? 0 : 0.16), radius: 28, y: 14)
        .onAppear { countComments() }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
            if let session = target.session, FileWatch.touches(n, session) { countComments() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LiveMascot(mood: chat.mood, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Takes").font(Theme.display(20))
                if chat.boardName.hasPrefix("comments") {
                    LaneSwitch(hub: hub, find: hub.comments, post: hub.commentsPost)
                } else {
                    Text(target.title).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer()
            // Always there once the chat has a conversation (2026-10-03: hidden under 20%, the
            // Comments chat had no way to see or compact its context).
            if chat.hasMessages { meter(chat.context).transition(.opacity) }
            // One "…" (2026-10-02): the tools slide out to its left on hover or a click, and stay
            // 2.5 s after the pointer leaves (2026-10-03), so reaching for one does not lose them.
            HStack(spacing: 10) {
            if tools {
                HStack(spacing: 10) {
                if chat.hasMessages {
                    Button { chat.reset() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Clear: start a new conversation")
                    .transition(.opacity)
                }
                Menu {
                    Button("New conversation") { chat.reset() }.disabled(!chat.hasMessages)
                    Button("Past conversations…") { showHistory = true }
                    Button("Compact the conversation") { send("/compact") }.disabled(!chat.hasMessages || chat.compacting)
                    Divider()
                    Picker("Access", selection: $access) {
                        Text("Full access, like the terminal").tag("bypassPermissions")
                        Text("Edit files only").tag("acceptEdits")
                    }
                    Divider()
                    Button("Runs in \(ClaudeChat.folder.lastPathComponent)") {
                        NSWorkspace.shared.open(ClaudeChat.folder)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12.5, weight: .medium)).frame(width: 26, height: 26)
                }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
                .help("Conversations and access")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    ChatHistory(chat: chat) { showHistory = false }
                }
                if target.session != nil {
                    // Script on the left, chat on the right: for working on the script, not recording.
                    let on = docked && scriptBeside && rightTab == "script"
                    Button {
                        if on { scriptBeside = false } else { scriptBeside = true; rightTab = "script"; hub.docked = true }
                    } label: {
                        Image(systemName: "doc.text").font(.system(size: 13, weight: on ? .bold : .medium))
                            .foregroundStyle(on ? Theme.accent : Theme.ink)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(on ? "Show the camera again" : "Script beside the chat: each takes half the screen")
                }
                Button { hub.docked.toggle() } label: {
                    Image(systemName: docked ? "rectangle.inset.bottomright.filled" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
                }
                .buttonStyle(IconButtonStyle())
                .help(docked ? "Float the chat in the corner" : "Half screen")
                if docked {
                    Button { hub.open = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Close the chat (⇧⌘L)")
                }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.85, anchor: .trailing)),
                    removal: .move(edge: .trailing).combined(with: .opacity)))
            }
            Button { withAnimation(Theme.spring) { tools.toggle() } } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(tools ? 90 : 0))
                    .foregroundStyle(tools ? Theme.accent : Theme.ink)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IconButtonStyle())
            .help(tools ? "Hide the tools" : "New chat, history, script beside, layout, close")
            }
            .onHover(perform: hoverTools)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .animation(Theme.motion, value: chat.running)
        .animation(Theme.motion, value: chat.context)
    }

    private func hoverTools(_ inside: Bool) {
        hideTools?.cancel()
        if inside {
            if !tools { withAnimation(Theme.spring) { tools = true } }
            return
        }
        hideTools = Task { @MainActor in
            // Not while the settings menu or past conversations are open: they hang off a tool.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                if Task.isCancelled { return }
                if !showHistory && RunLoop.main.currentMode != .eventTracking { break }
            }
            withAnimation(Theme.spring) { tools = false }
        }
    }

    /// How full Claude's context is. A click compacts it (after the run, when Claude works).
    private func meter(_ c: ChatContext?) -> some View {
        let f = c?.fraction ?? 0
        let tint = f >= 0.7 ? Theme.accentInk : Theme.muted
        let size = c.map { "\(ChatContext.short($0.used)) of \(ChatContext.short($0.window)) tokens" }
        return Button { send("/compact") } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2)
                    Circle().trim(from: 0, to: min(f, 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                if chat.compacting {
                    Text("Compacting").font(Theme.sans(11, .medium))
                } else {
                    Text(c == nil ? "–" : "\(Int((f * 100).rounded()))%").font(Theme.sans(11, .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle())
        .help(chat.compacting ? "Compacting the conversation"
              : size.map { "Context \(Int((f * 100).rounded()))% full: \($0). Click to compact it\(chat.running ? " when Takes is done" : "")." }
              ?? "The context size shows after the next reply. Click to compact the conversation.")
        .disabled(chat.compacting)
    }

    /// A plain VStack, not a LazyVStack. On 2026-10-01 Takes froze at 100% CPU as a reply with a
    /// file card came in: the sample showed SwiftUI stuck in one update, laying out this lazy
    /// stack (it builds and drops rows while it lays them out) again and again. A chat is short
    /// enough to lay out in full. It stays at the bottom by itself as the reply streams in,
    /// without an animated scroll per word.
    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !chat.hasMessages { empty }
                ChatRows(chat: chat)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, ChatReply.links(app))
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            if chat.boardName == "comments-post" {
                Text("Posting your comments.").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("Post now on the Approved tab runs here, while the Finding chat can look for new posts. Type while it works to steer it.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            } else if chat.boardName == "comments" {
                Text("Your comment copilot.").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("Run now and Post approved run here, so you see each step. Type while it works to steer it.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    suggestion(CopilotAsk.find(5), "Find 5 posts to comment on")
                    suggestion("What did my last decisions teach you? Suggest new lines for lessons.md.", "What did you learn?")
                }
            } else if chat.boardName == "styles" {
                Text("Your styles.").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("Takes makes new styles, renders their previews and fixes the parts you comment on.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    suggestion("I left comments on my styles. Read them with get_comments for each style library, fix each part as a new version, and reply to each one.", "Fix my comments")
                    suggestion("Render preview.mp4 and preview.png for every style that has none, from the shared sample clip.", "Render missing previews")
                }
            } else if target.session == nil {
                Text("Ask Takes about your numbers.").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("It can refresh this board for you. Past chats are under the clock.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    suggestion("Update the Performance dashboard with the latest LinkedIn and X numbers.", "Update the dashboard")
                    suggestion("Which of my posts did best in the last two weeks, and why?", "What worked lately?")
                }
            } else {
                Text("Ask Takes about this video.").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("It runs Claude Code, like your terminal, and it knows this session.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    if openComments > 0 { suggestion(commentsAsk, commentsLabel) }
                    suggestion("Make the next edit of this video.", "Make the next edit")
                    suggestion("Write three new hooks for this video and add them with set_hooks.", "Write three hooks")
                }
            }
        }
        .padding(.top, 60)
    }

    private var commentsLabel: String { "Fix my \(openComments) open comment\(openComments == 1 ? "" : "s")" }
    private var commentsAsk: String { ClaudeChat.commentsAsk }

    private func suggestion(_ ask: String, _ label: String) -> some View {
        Button { send(ask) } label: {
            HStack(spacing: 8) {
                Text(label).font(Theme.sans(12.5, .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func send(_ text: String) {
        chat.send(text, title: target.title, onStage: target.session == nil ? nil : app.preview)
    }

    private func countComments() {
        openComments = target.session.map { CommentStore.read($0).comments.filter(\.open).count } ?? 0
    }
}

/// The message box under a chat, with its draft and voice note.
private struct ChatComposer: View {
    @Environment(AppModel.self) var app
    var chat: ClaudeChat
    let target: ChatTarget
    let openComments: Int
    @State private var draft = ""
    @StateObject private var dictation = Dictation()
    /// What was in the box when the voice note started: the words go after it.
    @State private var spokenAfter = ""
    @FocusState private var focused: Bool

    var body: some View {
        let _ = Perf.body("ChatComposer")
        composer
            // On the next turn: while the panel animates in, the box is not in the window yet and
            // AppKit gave focus to the first field it found, the session title (2026-10-02).
            .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chat.wasCutOff {
                Button { send(ClaudeChat.goOn) } label: {
                    Label("Continue where Takes stopped", systemImage: "arrow.clockwise")
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            if chat.reconnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("The connection dropped. Takes goes on when the Mac is online.")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    Button("Stop") { chat.stop() }.buttonStyle(.link).font(Theme.sans(11.5, .medium))
                }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            if openComments > 0 && !chat.running && chat.hasMessages, let session = target.session {
                OpenCommentsChip(session: session, count: openComments) { send($0) }
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            ForEach(Array(chat.queued.enumerated()), id: \.offset) { i, q in
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    Text(CopilotAsk.shown(q)).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { if i < chat.queued.count { chat.queued.remove(at: i) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain).help("Take it out of the queue")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
                .help("Queued: sent when Takes is done")
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            if !chat.attachments.isEmpty {
                AttachedFiles(chat: chat)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.compacting ? "Queue a message: it goes after compacting"
                          : chat.running ? "Queue a message (⌘Return: Takes stops and reads it now)" : "Message Takes",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(13))
                    .lineLimit(1...6)
                    .overlay(alignment: .topLeading) { CommandToken(draft: draft) }
                    .focused($focused)
                    .onSubmit { submit() }
                    // Escape cancels dictation, else stops Claude's reply (as in Claude Code).
                    .onKeyPress(.escape) {
                        if dictation.active { dictation.cancel(); return .handled }
                        guard chat.running else { return .ignored }
                        chat.stop()
                        return .handled
                    }
                    // ⌘Return while Claude works: steer now instead of queueing.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), chat.running, canSend else { return .ignored }
                        send(draft, now: true)
                        return .handled
                    }
                    // ⌘V with an image or files on the clipboard: they go with the message.
                    .onKeyPress("v", phases: .down) { press in
                        guard press.modifiers == .command else { return .ignored }
                        return ChatAttach.paste(into: chat) ? .handled : .ignored
                    }
                    // Shift-Return: a new line at the cursor (Return sends).
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift),
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    .padding(.vertical, 7)
                if dictation.active {
                    VoiceNote(dictation: dictation, done: { Task { await dictation.stop() } },
                              cancel: { dictation.cancel() })
                        .padding(.bottom, 1)
                } else {
                    Button { startDictation() } label: {
                        Image(systemName: "mic").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(app.isRecording)
                    .help(app.isRecording ? "Not while recording a take" : "Voice note: talk, and the words come into the box")
                    .transition(.opacity)
                }
                Button {
                    if stopping { stop() } else { submit() }
                } label: {
                    ZStack {
                        Circle().fill(canSend || chat.running ? Theme.ink : Theme.border)
                        if stopping {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.paper).frame(width: 9, height: 9)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.paper)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(!canSend && !chat.running && !dictation.active)
                .help(stopping ? "Stop the reply" : chat.running ? "Queue: sent when Takes is done (Return). ⌘Return steers now." : "Send (Return)")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Theme.muted.opacity(0.5) : Theme.border, lineWidth: 0.5))
        }
        .padding(12)
        .animation(Theme.motion, value: focused)
        .animation(Theme.motion, value: chat.running)
        .animation(Theme.spring, value: dictation.active)
        .animation(Theme.motion, value: chat.attachments)
        .onChange(of: dictation.text) { _, words in draft = spokenAfter + words }
        .onChange(of: dictation.problem) { _, why in if let why { app.show(toast: why) } }
        .onDisappear { dictation.cancel() }
    }

    private func startDictation() {
        let kept = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        spokenAfter = kept.isEmpty ? "" : kept + " "
        focused = true
        Task { await dictation.start() }
    }

    /// Return or the send button. During a voice note: wait for the last words, then send.
    private func submit() {
        guard dictation.active else { send(draft); return }
        Task {
            await dictation.stop()
            if canSend { send(draft) }
        }
    }

    /// "@comments" alone is not a message: the "Fix my comments" button is for that.
    private var canSend: Bool { !ClaudeChat.withoutCommentsToken(draft).isEmpty || !chat.attachments.isEmpty }
    /// While Claude works, the button stops it; with text in the box it steers instead.
    private var stopping: Bool { chat.running && !canSend }

    private func send(_ text: String, now: Bool = false) {
        var out = text
        // Only what the user typed: not the buttons' own asks, and /compact must stay the whole message.
        let typed = text == draft
        if typed, !chat.attachments.isEmpty {
            out = ChatAttach.message(ClaudeChat.mentionsComments(text) ? ClaudeChat.withoutCommentsToken(text) : text,
                                     files: chat.attachments)
            chat.attachments = []
        }
        if typed {
            if out == text, ClaudeChat.mentionsComments(text) { out = ClaudeChat.withoutCommentsToken(text) }
            if openComments > 0, let session = target.session, !ClaudeChat.isCompact(out) {
                out = ClaudeChat.withComments(out, CommentStore.read(session).comments)
            }
        }
        chat.send(out, title: target.title, onStage: target.session == nil ? nil : app.preview, now: now)
        if typed { draft = "" }
    }

    /// Stop also stops the queue: its messages come back into the box.
    private func stop() {
        if !chat.queued.isEmpty {
            draft = (chat.queued + [draft]).filter { !$0.isEmpty }.joined(separator: "\n\n")
            chat.queued = []
        }
        chat.stop()
    }

}

/// "@comments" at the start of the box looks like a command, not a word: a tinted chip drawn
/// exactly over the typed text (2026-10-04). A TextField cannot style part of its text, so the
/// chip covers it; clicks go through to the field, so the word still deletes like text.
struct CommandToken: View {
    let draft: String

    var body: some View {
        let token = ClaudeChat.commentsToken
        if draft.hasPrefix(token), draft.dropFirst(token.count).first.map(\.isWhitespace) ?? true {
            // Same font and weight as the field: the chip's word sits on the typed one.
            Text(token).font(Theme.sans(13)).foregroundStyle(Theme.accentInk)
                .fixedSize()
                .padding(.leading, 4).padding(.trailing, 2.5)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.canvas)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accentSoft)
                }
                .offset(x: -4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The conversation itself. Its own view: a streamed word redraws only this, not the box you
/// type in, and a typed letter does not group and diff every message again (2026-10-02).
/// A long chat shows its newest part only: 700 messages took 170 ms to lay out, each time the
/// panel opened or a tab switch moved it (2026-10-02).
struct ChatRows: View {
    var chat: ClaudeChat
    static let page = 40
    @State private var limit = ChatRows.page

    var body: some View {
        let _ = Perf.body("ChatRows")
        let all = ChatItem.group(chat.messages)
        let items = all.suffix(limit)
        VStack(alignment: .leading, spacing: 10) {
            if all.count > items.count {
                Button { limit += Self.page * 3 } label: {
                    Label("Show earlier messages", systemImage: "arrow.up")
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.hover, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                Group {
                    switch item {
                    case .message(let m): ChatBubble(message: m).equatable()
                    case .tools(let t):
                        ToolRun(tools: t, active: chat.running && item.id == items.last?.id)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if chat.running, chat.messages.last.map({ $0.role != .claude || $0.done }) ?? true {
                Working(mood: chat.mood).transition(.opacity)
            }
        }
        .animation(Theme.motion, value: chat.messages.count)
    }
}

/// The Comments panel's two chats: finding posts and posting. Each can run while the other does.
private struct LaneSwitch: View {
    var hub: ChatHub
    var find: ClaudeChat
    var post: ClaudeChat

    var body: some View {
        HStack(spacing: 4) {
            lane("find", "Finding", find)
            lane("post", "Posting", post)
        }
    }

    private func lane(_ id: String, _ title: String, _ chat: ClaudeChat) -> some View {
        Button { hub.commentsLane = id } label: {
            HStack(spacing: 4) {
                if chat.running { ProgressView().controlSize(.mini) }
                Text(title).font(Theme.sans(11.5, hub.commentsLane == id ? .semibold : .regular))
            }
            .foregroundStyle(hub.commentsLane == id ? Theme.ink : Theme.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(hub.commentsLane == id ? Theme.canvas : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(id == "find" ? "The chat that finds posts and drafts comments" : "The chat that posts your approved comments")
    }
}

/// The history popover: past conversations, newest first. A click reopens one.
private struct ChatHistory: View {
    var chat: ClaudeChat
    let close: () -> Void
    @State private var items: [PastChat] = []
    @State private var hover: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Past conversations").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if items.isEmpty {
                Text("None yet. \"New conversation\" keeps the old one here.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { row($0) }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 320)
        .onAppear { items = chat.past() }
    }

    private func row(_ p: PastChat) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail(p)).font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            if hover == p.file {
                Button {
                    chat.forget(p)
                    withAnimation(Theme.motion) { items.removeAll { $0.file == p.file } }
                } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22)
                }
                .buttonStyle(IconButtonStyle())
                .help("Delete this conversation")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover == p.file ? Theme.canvas : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 ? p.file : (hover == p.file ? nil : hover) }
        .onTapGesture { chat.resume(p); close() }
        .disabled(chat.running)
    }

    private func detail(_ p: PastChat) -> String {
        let n = "\(p.count) message\(p.count == 1 ? "" : "s")"
        guard let d = p.date else { return n }
        return "\(d.formatted(.relative(presentation: .named))) · \(n)"
    }
}

/// Equatable: while a reply streams in, only the message that changed is drawn again, not every
/// message above it (2026-10-02).
private struct ChatBubble: View, Equatable {
    let message: ChatMessage

    var body: some View {
        content.help(message.at.map(Self.when) ?? "")
    }

    /// "Today, 10:29 PM", "Yesterday, 5:35 PM", "Oct 1, 2026 at 5:35 PM".
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
    static func when(_ d: Date) -> String { format.string(from: d) }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user:
            // Files sent with the message (ChatAttach) show as cards under its text.
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(ChatRefs.pieces(CopilotAsk.shown(message.text)).enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let t):
                        HStack {
                            Spacer(minLength: 48)
                            Text(t).font(Theme.sans(13)).foregroundStyle(Theme.paper)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14))
                        }
                    case .file(let url):
                        FileRefCard(url: url).frame(maxWidth: 220)
                    case .post(let url):
                        PostRefCard(url: url).frame(maxWidth: 260)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude:
            ChatReply(text: message.text)
        case .tool:
            ToolLine(text: message.text, done: message.done)
        case .error:
            Text(message.text).font(Theme.sans(12.5)).foregroundStyle(Theme.accentInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One tool call: a spinner while it runs, a tick when done.
private struct ToolLine: View {
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Spinner().transition(.opacity)
                }
            }
            .frame(width: 12, height: 12)
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.tail)
        }
        .animation(Theme.motion, value: done)
    }
}

/// Three or more tool calls in a row. While they run, only the newest shows under a count of the
/// earlier ones; once done, one line. A click opens the full list.
private struct ToolRun: View {
    let tools: [ChatMessage]
    /// The run Claude is still adding to.
    let active: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Theme.motion) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12, height: 12)
                    Text(label).font(Theme.mono(11)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(Theme.faint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the steps" : "Show every step")
            if open {
                ForEach(tools) { ToolLine(text: $0.text, done: $0.done) }
            } else if running, let last = tools.last {
                ToolLine(text: last.text, done: last.done).id(last.id)
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion, value: tools.count)
    }

    private var running: Bool { active || tools.contains { !$0.done } }

    private var label: String {
        if open { return "\(tools.count) steps" }
        return running ? "\(tools.count - 1) earlier steps" : ChatItem.summary(tools)
    }
}

/// The mascot and three dots while Takes thinks (layer animations: Motion.swift).
private struct Working: View {
    var mood: LiveMascot.Mood = .thinking
    var body: some View {
        HStack(spacing: 8) {
            LiveMascot(mood: mood, size: 30)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    LayerPulse(color: Theme.faint, delay: Double(i) * 0.18).frame(width: 5, height: 5)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Presses in a little.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.motion, value: configuration.isPressed)
    }
}


/// Whether the Mac has a network path. A chat that lost its connection waits for one.
enum Online {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "takes.online"))
        return m
    }()

    /// Returns at once when online; else when the network comes back.
    static func wait() async {
        while monitor.currentPath.status != .satisfied {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
