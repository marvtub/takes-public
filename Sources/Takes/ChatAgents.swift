import AppKit
import SwiftUI

// Which agent runs the Takes chat, and on which model (2026-10-11). Before this the chat always ran
// `claude` on the model Claude Code picks by itself. Now the line under "Takes" in the chat header
// says "Claude Code · Opus" and opens a small card: the agent, its model, and a link to
// Settings › Agents, which also lists the other agents that can open the library.
//
// A conversation keeps the agent it started on: a Claude Code conversation cannot go on in Codex.
// Picking the other agent starts a new conversation; the old one stays in Past conversations.
// The model is one setting per agent and counts from the next message.

enum ChatAgent: String, Codable, CaseIterable, Identifiable {
    case claude, codex, pi
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "pi"
        }
    }

    /// The agent new conversations start on.
    static var current: ChatAgent {
        get { ChatAgent(rawValue: UserDefaults.standard.string(forKey: "chatAgent") ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chatAgent") }
    }

    var models: [ChatModel] {
        switch self {
        case .claude: return ChatModel.claude
        case .codex: return CodexModels.list
        case .pi: return PiModels.list
        }
    }

    /// The model picked for this agent, or its first one.
    var model: ChatModel {
        let saved = UserDefaults.standard.string(forKey: modelKey)
        return models.first { $0.id == saved } ?? models[0]
    }

    var modelKey: String { "chatModel.\(rawValue)" }

    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .pi: return .pi
        }
    }

    /// Its CLI's arguments and output for the chat (Agents/ChatAdapters.swift).
    var adapter: any ChatAdapter {
        switch self {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .pi: return PiAdapter()
        }
    }

    /// Whose plan it runs on, until the sign-in check says more.
    var plan: String {
        switch self {
        case .claude: return "Uses your Claude plan"
        case .codex: return "Uses your ChatGPT plan"
        case .pi: return "Uses the model set in pi"
        }
    }

    /// The CLI on this Mac, or nil.
    @MainActor var path: String? { Agents.path(kind) }
}

struct ChatModel: Hashable, Identifiable, Codable {
    /// What the CLI takes after --model / -m.
    let id: String
    let name: String
    let hint: String

    /// Claude Code's own names: each one is always its newest model.
    static let claude = [
        ChatModel(id: "opus", name: "Opus", hint: "Best for edits and storyboards. Uses more of your plan."),
        ChatModel(id: "sonnet", name: "Sonnet", hint: "Fast and good for most asks."),
        ChatModel(id: "haiku", name: "Haiku", hint: "Quick small jobs: names, short posts."),
    ]
}

/// Codex's models come from `codex debug models` (the ones it lists, best first), read once in the
/// background and kept for the next launch. The ChatGPT plan refuses some names a config may hold
/// (gpt-6.1-sol, 2026-10-11), so the chat always passes one from this list.
enum CodexModels {
    static let fallback = [
        ChatModel(id: "gpt-6-astra", name: "GPT-6 Astra", hint: "Frontier intelligence for the most demanding work."),
        ChatModel(id: "gpt-6-sol", name: "GPT-6 Sol", hint: "Previous generation workhorse model."),
        ChatModel(id: "gpt-6-luna", name: "GPT-6 Luna", hint: "Fast and affordable model for easier tasks."),
    ]

    static var list: [ChatModel] {
        guard let d = UserDefaults.standard.data(forKey: "codexModels"),
              let saved = try? JSONDecoder().decode([ChatModel].self, from: d), !saved.isEmpty else { return fallback }
        return saved
    }

    @MainActor private static var loading = false

    /// Reads the list again, at most once per launch.
    @MainActor static func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            guard let codex = Agents.path(.codex), let out = AgentCheck.run(codex, ["debug", "models"]), let models = parse(out), !models.isEmpty,
                  let d = try? JSONEncoder().encode(models) else { return }
            await MainActor.run { UserDefaults.standard.set(d, forKey: "codexModels") }
        }
    }

    /// The first three listed models, by Codex's own order.
    nonisolated static func parse(_ json: String) -> [ChatModel]? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let all = o["models"] as? [[String: Any]] else { return nil }
        let listed = all.filter { $0["visibility"] as? String == "list" && $0["slug"] is String }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
        return listed.prefix(3).map { m in
            let slug = m["slug"] as! String
            let shown = (m["display_name"] as? String).map { $0.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "GPT 6", with: "GPT-6") } ?? slug
            return ChatModel(id: slug, name: shown, hint: m["description"] as? String ?? "")
        }
    }
}

/// pi works with many providers, and its own settings pick the model (/model in pi). The chat offers
/// that one: an empty id passes no --model.
enum PiModels {
    static var list: [ChatModel] {
        [ChatModel(id: "", name: defaultModel ?? "pi's model", hint: "The model set in pi. Change it with /model in pi.")]
    }

    /// defaultModel in pi's settings.json (PI_CODING_AGENT_DIR, else ~/.pi/agent).
    static var defaultModel: String? {
        guard let d = try? Data(contentsOf: AgentKind.piDir.appending(path: "settings.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = o["defaultModel"] as? String, !m.isEmpty else { return nil }
        return m
    }
}

/// Runs a small CLI check with the login shell's PATH. Off the main thread only.
enum AgentCheck {
    /// `errors`: read stderr too (`codex login status` prints there).
    nonisolated static func run(_ exe: String, _ args: [String], seconds: Double = 30, errors: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ClaudeChat.environment()
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = errors ? out : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// What Settings › Agents and the chat's card show: sign-in of the chat agents, and which MCP
/// agents have the takes server (takes_mcp.py --agents). Read when a page opens, and on Check again.
@MainActor
@Observable
final class AgentsStatus {
    static let shared = AgentsStatus()

    struct Library: Identifiable, Hashable {
        let name: String
        let found: Bool
        let connected: Bool
        var id: String { name }
    }

    /// nil: not checked yet.
    var signedIn: [ChatAgent: String?] = [:]
    var library: [Library] = []
    /// Whether each chat agent's CLI is on this Mac. Found off the main thread: the first PATH
    /// lookup starts a login shell, and waiting for it inside a view update crashed SwiftUI.
    private(set) var installed: [ChatAgent: Bool] = [:]

    /// Until the check says otherwise, an agent counts as there.
    func has(_ a: ChatAgent) -> Bool { installed[a] != false }
    private(set) var checking = false
    private(set) var connecting: String?

    private var server: String? {
        let p = Bundle.main.bundleURL.appending(path: "Contents/Resources/takes_mcp.py").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func checkOnce() { if library.isEmpty && signedIn.isEmpty { check() } }

    func check() {
        guard !checking else { return }
        checking = true
        CodexModels.refresh()
        let server = server
        Task.detached(priority: .userInitiated) {
            // Finding the CLIs may start a login shell: off the main thread.
            let paths = AgentKind.allCases.map(Agents.path)
            let (claude, codex, pi) = (paths[0], paths[1], paths[2])
            let claudeLine = claude.map { Self.claudeLine(AgentCheck.run($0, ["auth", "status"])) }
            let codexLine = codex.map { Self.codexLine(AgentCheck.run($0, ["login", "status"], errors: true)) }
            let piLine = pi.map { _ in AgentKind.piSignedIn() ? ChatAgent.pi.plan : "Not signed in: run pi in Terminal, then /login" }
            let rows = server.flatMap { AgentCheck.run("/usr/bin/python3", [$0, "--agents"], seconds: 90) }.map(Self.parse) ?? []
            await MainActor.run {
                let s = AgentsStatus.shared
                // pi signs in per provider (pi auth check needs one): its line says whose model it uses.
                s.signedIn = [.claude: claudeLine, .codex: codexLine, .pi: piLine]
                s.installed = [.claude: claude != nil, .codex: codex != nil, .pi: pi != nil]
                if server != nil { s.library = rows }
                s.checking = false
            }
        }
    }

    /// Adds the takes server to one agent (takes_mcp.py --setup --only NAME), then checks again.
    func connect(_ name: String) {
        guard let server, connecting == nil else { return }
        connecting = name
        Task.detached(priority: .userInitiated) {
            _ = AgentCheck.run("/usr/bin/python3", [server, "--setup", "--only", name], seconds: 60)
            await MainActor.run {
                AgentsStatus.shared.connecting = nil
                AgentsStatus.shared.check()
            }
        }
    }

    nonisolated static func parse(_ json: String) -> [Library] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            (r["name"] as? String).map { Library(name: $0, found: r["found"] as? Bool ?? false, connected: r["connected"] as? Bool ?? false) }
        }
    }

    /// `claude auth status` prints JSON with loggedIn and authMethod.
    nonisolated static func claudeLine(_ out: String?) -> String {
        // The JSON can follow a warning line, as in Setup's check (AgentKind.claudeSignedIn).
        guard let out, AgentKind.claudeSignedIn(out), let start = out.firstIndex(of: "{"),
              let o = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any]
        else { return "Not signed in: run claude in Terminal once" }
        return (o["authMethod"] as? String) == "claude.ai" ? "Signed in · uses your Claude plan" : "Signed in · uses your API key"
    }

    /// `codex login status`: "Logged in using ChatGPT", or using an API key.
    nonisolated static func codexLine(_ out: String?) -> String {
        guard let out, AgentKind.codexSignedIn(out) else { return "Not signed in: run codex login in Terminal" }
        return out.contains("ChatGPT") ? "Signed in · uses your ChatGPT plan" : "Signed in · uses your API key"
    }

    /// The agents that have the server, except the ones that run the chat: "Cursor, Gemini CLI and 4 more".
    var othersLine: String? {
        let names = library.filter { l in l.connected && !ChatAgent.allCases.contains { $0.name == l.name } }.map(\.name)
        guard !names.isEmpty else { return nil }
        if names.count <= 2 { return names.joined(separator: " and ") }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }
}

// MARK: - The line under "Takes" and its card

/// "Claude Code · Opus ⌄" under "Takes" in the chat header. A click opens the card.
struct AgentLine: View {
    var chat: ClaudeChat
    @State private var open = false
    @AppStorage("chatAgent") private var agentRaw = ChatAgent.claude.rawValue
    @AppStorage("chatModel.claude") private var claudeModel = ""
    @AppStorage("chatModel.codex") private var codexModel = ""

    var body: some View {
        let _ = (agentRaw, claudeModel, codexModel)  // redraw when a setting changes
        let agent = chat.agent
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text("\(agent.name) · \(agent.model.name)").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.sans(11.5))
            .foregroundStyle(open ? Theme.accentInk : Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Which agent and model does the work")
        .takesPopover(isPresented: $open) {
            AgentCard(chat: chat) { open = false }
        }
    }
}

/// Who does the work, its model, and a link to Settings › Agents.
struct AgentCard: View {
    var chat: ClaudeChat
    let close: () -> Void
    @Environment(\.openSettings) private var openSettings
    @AppStorage("chatAgent") private var agentRaw = ChatAgent.claude.rawValue
    @AppStorage("chatModel.claude") private var claudeModel = ""
    @AppStorage("chatModel.codex") private var codexModel = ""
    /// The agent this card just switched to: the card says a new conversation started.
    @State private var switched: ChatAgent?
    private var status: AgentsStatus { AgentsStatus.shared }

    var body: some View {
        let _ = (agentRaw, claudeModel, codexModel)
        let agent = chat.agent
        VStack(alignment: .leading, spacing: 12) {
            Text("Who does the work").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.muted)
            VStack(spacing: 6) {
                ForEach(ChatAgent.allCases) { a in row(a, selected: a == agent) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.muted)
                if agent.models.count > 1 { ModelSegments(agent: agent) }
                Text(agent.model.hint).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let switched, switched == agent {
                Text("\(switched.name) starts a new conversation. The last one stays in Past conversations.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
            Rule()
            Button {
                UserDefaults.standard.set(SettingsView.SettingsPage.agents.rawValue, forKey: "settingsPage")
                close()
                openSettings()
            } label: {
                (Text(status.othersLine.map { "\($0) can also open your library. " } ?? "Other agents can open your library too. ")
                    .foregroundStyle(Theme.muted)
                 + Text("Agents…").foregroundStyle(Theme.accentInk).fontWeight(.medium))
                    .font(Theme.sans(12))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
        .animation(Theme.motion, value: switched)
        .onAppear { status.checkOnce() }
    }

    private func row(_ a: ChatAgent, selected: Bool) -> some View {
        let there = status.has(a)
        let line = !there ? "Not on this Mac" : (status.signedIn[a] ?? nil) ?? a.plan
        return Button {
            guard !selected, there else { return }
            if chat.switchAgent(to: a) { switched = a } else { switched = nil }
        } label: {
            HStack(spacing: 10) {
                AgentTile(name: a.name, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(line).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accentSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent : Theme.border))
            .contentShape(Rectangle())
            .opacity(there ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!there || (chat.running && !selected))
        .help(chat.running && !selected ? "Wait until Takes is done to switch" : "")
    }
}

/// Opus | Sonnet | Haiku, on the menu kit's switch.
struct ModelSegments: View {
    let agent: ChatAgent
    @AppStorage("chatModel.claude") private var claudeModel = ""
    @AppStorage("chatModel.codex") private var codexModel = ""

    var body: some View {
        let _ = (claudeModel, codexModel)
        TakesSwitch(selection: Binding(get: { agent.model.id }, set: { UserDefaults.standard.set($0, forKey: agent.modelKey) }),
                    options: agent.models.map { ($0.id, $0.name) }, fill: true)
    }
}

/// A small square with the agent's first letters.
struct AgentTile: View {
    let name: String
    var size: CGFloat = 26
    var dim = false

    var body: some View {
        Group {
            if let mark = AgentMark.image(name) {
                Image(nsImage: mark.image).renderingMode(mark.tint == nil ? .original : .template)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .foregroundStyle(mark.tint ?? Theme.ink)
            } else {
                Image(systemName: "terminal").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .padding(size * 0.2)
        .frame(width: size, height: size)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: size * 0.28))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Theme.border, lineWidth: 0.5))
        .opacity(dim ? 0.5 : 1)
    }
}

/// The agents' real marks (assets/agents, README there for sources), from the app's Resources/Agents.
/// One-colour marks come back with a tint: they draw as templates, so they follow light and dark.
@MainActor
enum AgentMark {
    struct Mark { let image: NSImage; let tint: Color? }

    private static var cache: [String: Mark] = [:]

    static func file(_ name: String) -> (String, Color?)? {
        let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        switch name {
        case "Claude Code", "Claude Desktop": return ("claude.svg", claude)
        case "Codex": return ("openai.svg", Theme.ink)
        case "Cursor": return ("cursor.svg", Theme.ink)
        case "Gemini CLI": return ("gemini.svg", nil)
        case "Antigravity": return ("antigravity.png", nil)
        case "opencode": return ("opencode.svg", Theme.ink)
        case "pi": return ("pi.svg", Theme.ink)
        default: return nil
        }
    }

    static func image(_ name: String) -> Mark? {
        if let m = cache[name] { return m }
        guard let (f, tint) = file(name) else { return nil }
        // The built app has them in Resources; `swift run` and tests read the repo's own folder.
        let dirs = [Bundle.main.resourceURL?.appending(path: "Agents"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/agents")]
        guard let img = dirs.compactMap({ $0 }).lazy.compactMap({ NSImage(contentsOf: $0.appending(path: f)) }).first else { return nil }
        img.isTemplate = tint != nil
        let m = Mark(image: img, tint: tint)
        cache[name] = m
        return m
    }
}

// MARK: - Settings › Agents

struct AgentsPage: View {
    @AppStorage("chatAgent") private var agentRaw = ChatAgent.claude.rawValue
    @AppStorage("chatModel.claude") private var claudeModel = ""
    @AppStorage("chatModel.codex") private var codexModel = ""
    @AppStorage(ChatMCP.allKey) private var allMCP = false
    private var status: AgentsStatus { AgentsStatus.shared }

    var body: some View {
        let _ = (claudeModel, codexModel)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents").font(Theme.display(26)).foregroundStyle(Theme.ink)
                    Text("One agent runs the chat in Takes, on your own plan. Every agent below can also open your library, from its own app or terminal.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Runs the chat").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    card {
                        VStack(spacing: 0) {
                            ForEach(Array(ChatAgent.allCases.enumerated()), id: \.element) { i, a in
                                if i > 0 { Rule().opacity(0.6) }
                                runner(a)
                            }
                        }
                    }
                    Text("A new pick counts from the next new conversation. A conversation keeps the agent it started on.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("MCP servers in the chat").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    card {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(allMCP ? "All servers" : "Only the servers you added")
                                    .font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                                Text(allMCP
                                     ? "Also your claude.ai connectors and plugin servers. Each message starts about 1 s slower."
                                     : "takes and the servers you added with claude mcp add. Each message starts about 1 s faster.")
                                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            TakesSwitch(selection: $allMCP, options: [(false, "Mine"), (true, "All")])
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    Text("Claude Code only. Claude in Chrome stays on either way. Counts from the next message.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Can open your library").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button(status.checking ? "Checking…" : "Check again") { status.check() }.disabled(status.checking)
                    }
                    card {
                        if status.library.isEmpty {
                            Text(status.checking ? "Checking the agents on this Mac…" : "Takes found no agents on this Mac.")
                                .font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(status.library.enumerated()), id: \.element) { i, a in
                                    if i > 0 { Rule().opacity(0.6) }
                                    libraryRow(a)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
        .onAppear { status.check() }
    }

    private func runner(_ a: ChatAgent) -> some View {
        let on = ChatAgent(rawValue: agentRaw) ?? .claude
        let there = status.has(a)
        let line = !there ? "Not on this Mac" : (status.signedIn[a] ?? nil) ?? "Checking…"
        return HStack(spacing: 12) {
            Button { if there { agentRaw = a.rawValue } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(a == on ? Theme.accent : Theme.faint, lineWidth: 1.5).frame(width: 16, height: 16)
                        if a == on { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                    }
                    AgentTile(name: a.name, size: 30, dim: !there)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                        Text(line).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!there)
            TakesMenuButton(help: "The model \(a.name) uses") {
                HStack(spacing: 4) {
                    Text(a.model.name)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(Theme.sans(12.5, .medium))
                .foregroundStyle(there ? Theme.ink : Theme.muted)
                .contentShape(Rectangle())
            } content: {
                for m in a.models {
                    MenuButton(m.name, checked: m == a.model) {
                        UserDefaults.standard.set(m.id, forKey: a.modelKey)
                    }
                }
            }
            .fixedSize()
            .disabled(!there)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func libraryRow(_ a: AgentsStatus.Library) -> some View {
        HStack(spacing: 11) {
            AgentTile(name: a.name, size: 26, dim: !a.found)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(Theme.sans(13, .medium)).foregroundStyle(a.found ? Theme.ink : Theme.muted)
                if let note = Self.notes[a.name] {
                    Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if a.connected {
                HStack(spacing: 5) {
                    Circle().fill(Theme.live).frame(width: 6, height: 6)
                    Text("Connected").font(Theme.sans(12, .medium)).foregroundStyle(Theme.live)
                }
            } else if a.found {
                Button(status.connecting == a.name ? "Connecting…" : "Connect") { status.connect(a.name) }
                    .disabled(status.connecting != nil)
                    .help("Add the takes tools to \(a.name)")
            } else {
                Text("Not on this Mac").font(Theme.sans(12)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// One line on what each agent gets.
    static let notes: [String: String] = [
        "Claude Code": "In your terminal too, with the two Takes skills",
        "Codex": "In your terminal too, with the two Takes skills",
        "Cursor": "The main tools, so Cursor stays under its tool limit",
        "pi": "Through pi-mcp-adapter",
    ]

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}
