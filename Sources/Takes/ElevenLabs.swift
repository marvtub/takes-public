import AVFoundation
import AppKit
import Observation
import SwiftUI

/// ElevenLabs in Takes (2026-10-06): voice-overs, fixed words and other voices. The takes MCP does the
/// work (tools voices, design_voice, voiceover, fix_words, change_voice), for the chat and for this page
/// alike (`takes_mcp.py --eleven <tool> <json>`). The key sits in the login Keychain ("Takes ElevenLabs"),
/// written and read by the security tool, so neither the app nor the chat ever asks for it again.
@MainActor @Observable
final class ElevenLabs {
    static let shared = ElevenLabs()
    init() {}

    struct Voice: Identifiable, Equatable {
        var id: String
        var name: String
        var detail: String
        var preview: URL?
        var add: String?   // a library voice: "<owner>/<voice>" to add it to the account
    }

    enum State: Equatable { case unknown, noKey, ready(String), failed(String) }

    var state: State = .unknown
    var mine: [Voice] = []
    var library: [Voice] = []
    var defaultID: String?
    var busy: String?
    var playing: String?
    @ObservationIgnored private var player: AVPlayer?

    static let keys = URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    static let clone = URL(string: "https://elevenlabs.io/app/voice-lab")!

    /// Runs one MCP tool off the main thread. `input` goes on stdin (the key). `flag` picks the
    /// plugin's entry in takes_mcp.py (Replicate uses this too).
    nonisolated static func call(_ tool: String, _ args: [String: Any] = [:], input: String? = nil,
                                 flag: String = "--eleven") async -> [String: Any] {
        guard let script = Bundle.main.url(forResource: "takes_mcp", withExtension: "py") else { return ["error": "The takes server is missing."] }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/python3")
            p.arguments = [script.path, flag, tool, json]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Setup.localBin):" + (env["PATH"] ?? "/usr/bin:/bin")
            if let root = UserDefaults.standard.string(forKey: "root") { env["TAKES_ROOT"] = root }
            p.environment = env
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = inp
            guard (try? p.run()) != nil else { return ["error": "Could not start the takes server."] }
            if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
            try? inp.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["error": "The takes server gave no answer."]
        }.value
    }

    nonisolated static func voices(_ list: Any?) -> [Voice] {
        (list as? [[String: Any]] ?? []).compactMap { v in
            guard let name = v["name"] as? String else { return nil }
            let add = v["add"] as? String
            guard let id = v["id"] as? String ?? add else { return nil }
            let labels = v["labels"] as? [String: String] ?? [:]
            let bits = add == nil
                ? [v["category"] as? String, labels["accent"], labels["gender"]]
                : [v["accent"] as? String, v["gender"] as? String, v["age"] as? String, v["use_case"] as? String]
            return Voice(id: id, name: name,
                         detail: bits.compactMap { $0?.replacingOccurrences(of: "_", with: " ") }.filter { !$0.isEmpty }.joined(separator: " · "),
                         preview: (v["preview"] as? String).flatMap(URL.init(string:)), add: add)
        }
    }

    /// "Creator plan · 95,000 characters left"
    nonisolated static func accountLine(_ a: [String: Any]) -> String {
        var parts: [String] = []
        if let plan = a["plan"] as? String { parts.append(plan.prefix(1).uppercased() + plan.dropFirst() + " plan") }
        if let left = a["characters_left"] as? Int { parts.append("\(left.formatted()) characters left") }
        return parts.joined(separator: " · ")
    }

    func refresh() async {
        let r = await Self.call("voices")
        let account = r["account"] as? [String: Any] ?? [:]
        if let e = account["error"] as? String ?? r["error"] as? String {
            state = e.contains("No ElevenLabs API key") ? .noKey : .failed(e)
            mine = []
            return
        }
        state = .ready(Self.accountLine(account))
        mine = Self.voices(r["mine"])
        defaultID = (r["default"] as? [String: Any])?["id"] as? String
    }

    func saveKey(_ key: String) async {
        busy = "Saving…"
        let r = await Self.call("save_key", input: key)
        busy = nil
        if let e = r["error"] as? String { state = .failed(e); return }
        state = .unknown
        await refresh()
    }

    func removeKey() async {
        _ = await Self.call("save_key", input: "")
        state = .noKey
        mine = []
    }

    func makeDefault(_ v: Voice) async {
        let r = await Self.call("voices", ["set_default": v.id])
        if r["error"] == nil { defaultID = v.id }
    }

    func search(_ q: String) async {
        busy = "Searching…"
        let r = await Self.call("voices", ["search": q])
        busy = nil
        library = Self.voices(r["library"])
    }

    func addFromLibrary(_ v: Voice) async {
        guard let add = v.add else { return }
        busy = "Adding \(v.name)…"
        _ = await Self.call("voices", ["add": add, "name": v.name])
        busy = nil
        library.removeAll { $0.id == v.id }
        await refresh()
    }

    func play(_ v: Voice) {
        if playing == v.id { player?.pause(); playing = nil; return }
        guard let url = v.preview else { return }
        player = AVPlayer(url: url)
        player?.play()
        playing = v.id
    }

    // MARK: Asks for the chat

    nonisolated static func fixDraft(_ rel: String) -> String { "Fix words in \(rel) with fix_words: change \"" }
    nonisolated static func voiceDraft(_ rel: String) -> String { "Say \(rel) again in another voice with change_voice: " }
    nonisolated static let voiceoverAsk = "Make a voice-over of the script with the voiceover tool, in my default voice."
}

/// Plugins › Voices (Settings › Voices until 2026-10-08). The board draws the title.
struct VoicesPage: View {
    private var el = ElevenLabs.shared
    @State private var key = ""
    @State private var query = ""
    @State private var changingKey = false

    static let plugin = TakesPlugin(
        id: "voices", title: "Voices", icon: "waveform", key: " ",
        help: "Voice-overs, fixed words and other voices with ElevenLabs, in your own voice or any other. Uses the characters of your ElevenLabs plan.",
        badge: { _ in AnyView(EmptyView()) }, board: nil,
        settings: { _ in AnyView(VoicesPage()) })

    var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                card { account }
                if case .ready = el.state {
                    section("Your voices", "The default voice speaks when you do not name one.") {
                        if el.mine.isEmpty { Text("No voices yet.").font(Theme.sans(12)).foregroundStyle(Theme.faint) }
                        ForEach(el.mine) { v in voiceRow(v) }
                        HStack(spacing: 6) {
                            Image(systemName: "person.wave.2").foregroundStyle(Theme.accentInk)
                            Text("Your own voice: make a Professional Voice Clone on ElevenLabs. It shows here when it is ready.")
                                .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            Button("Open ElevenLabs") { NSWorkspace.shared.openSoon(ElevenLabs.clone) }
                        }
                        .padding(.top, 6)
                    }
                    section("Find a voice", "Search the ElevenLabs library: \"deep British narrator\", \"young energetic woman\".") {
                        HStack {
                            TextField("Describe a voice", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await el.search(query) } }
                            Button("Search") { Task { await el.search(query) } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        ForEach(el.library) { v in voiceRow(v) }
                        Text("Or describe a new voice to Takes in the chat: \"Design a calm German narrator voice\".")
                            .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where to use it").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    use("text.badge.checkmark", "Fix words", "Assets › right-click a take › Fix Words…, then say what to change. Takes says the new words in the voice and cuts them in.")
                    use("person.2.wave.2", "Another voice", "Assets › right-click › Change Voice…: same words and timing, another voice.")
                    use("bubble.left", "Voice-over", "Ask Takes: \"Make a voice-over of the script\" or \"Read this in Anna's voice\".")
                    Text("New files land in the session's generated folder, with the voice's name.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                }
            }
        .task { await el.refresh() }
    }

    @ViewBuilder private var account: some View {
        switch el.state {
        case .unknown:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(Theme.sans(12.5)).foregroundStyle(Theme.muted) }
        case .noKey:
            keyForm("Connect ElevenLabs", "Paste an API key from ElevenLabs › Developers › API Keys. Takes keeps it in your Keychain.")
        case .failed(let why):
            keyForm("ElevenLabs is not connected", why)
        case .ready(let line):
            if changingKey {
                keyForm("Change the API key", "The new key replaces the old one in your Keychain.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connected").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                        Text(line).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    Button("Change Key") { changingKey = true }
                    Button("Disconnect") { Task { await el.removeKey() } }
                }
            }
        }
    }

    private func keyForm(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SecureField("API key", text: $key).textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(action: save) {
                    Text(el.busy ?? "Connect").font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || el.busy != nil)
            }
            HStack(spacing: 12) {
                Button("Get a key") { NSWorkspace.shared.openSoon(ElevenLabs.keys) }.buttonStyle(.link)
                if changingKey { Button("Cancel") { changingKey = false; key = "" }.buttonStyle(.link) }
            }
            .font(Theme.sans(12))
        }
    }

    private func save() {
        let k = key
        key = ""
        changingKey = false
        Task { await el.saveKey(k) }
    }

    private func voiceRow(_ v: ElevenLabs.Voice) -> some View {
        HStack(spacing: 10) {
            Button { el.play(v) } label: {
                Image(systemName: el.playing == v.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 10)).frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.hover))
            }
            .buttonStyle(.plain).disabled(v.preview == nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.name).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if !v.detail.isEmpty { Text(v.detail).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if v.add != nil {
                Button("Add") { Task { await el.addFromLibrary(v) } }
            } else if el.defaultID == v.id {
                Text("Default").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.accentInk)
            } else {
                Button("Make Default") { Task { await el.makeDefault(v) } }.font(Theme.sans(11.5))
            }
        }
        .padding(.vertical, 2)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func section<C: View>(_ title: String, _ detail: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            card { VStack(alignment: .leading, spacing: 6) { c() } }
        }
    }

    private func use(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.accentInk).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
