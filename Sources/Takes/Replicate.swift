import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Replicate in Takes (2026-10-09): the same video models as Higgsfield (Seedance 2.5, Kling, Veo)
/// at Replicate's price per second, with no plan. The user moved to it because his Higgsfield plan
/// cost about a third more per clip. The takes MCP does the work (tools replicate, replicate_model,
/// replicate_status), for the chat and for this page alike (`takes_mcp.py --replicate <call> <json>`).
/// The token sits in the login Keychain ("Takes Replicate"). This page only holds the token and a
/// short list of default models; the chat sets the rest per clip from each model's own inputs.
@MainActor @Observable
final class Replicate {
    static let shared = Replicate()
    init() {}

    enum State: Equatable { case unknown, noKey, ready(String), failed(String) }

    var state: State = .unknown
    /// The default video models, owner/name; the first one is the default.
    var models: [String] = []
    var busy: String?
    /// Why the last model could not be added.
    var problem: String?

    var connected: Bool { if case .ready = state { return true } else { return false } }

    var featured: [VideoModel] = []
    var popular: [VideoModel] = []

    static let tokens = URL(string: "https://replicate.com/account/api-tokens")!
    static let explore = URL(string: "https://replicate.com/collections/text-to-video")!

    nonisolated static func call(_ what: String, _ args: [String: Any] = [:], input: String? = nil) async -> [String: Any] {
        await ElevenLabs.call(what, args, input: input, flag: "--replicate")
    }

    func refresh() async {
        let r = await Self.call("status")
        models = r["models"] as? [String] ?? []
        if let e = r["problem"] as? String ?? r["error"] as? String { state = .failed(e); return }
        guard r["token"] as? Bool == true else { state = .noKey; return }
        state = .ready((r["account"] as? String).map { "Signed in as \($0)" } ?? "Connected")
    }

    /// The browser's lists. The MCP keeps them a day, so this is quick after the first time.
    func loadCatalog() async {
        let r = await Self.call("catalog")
        featured = VideoModel.list(r, "featured")
        popular = VideoModel.list(r, "popular")
    }

    /// "14703995" → "14.7M runs".
    nonisolated static func runs(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM runs", Double(n) / 1e6)
        case 1_000...: "\(n / 1000)K runs"
        default: "\(n) runs"
        }
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
    }

    /// Checks the model on Replicate first, so a typo never becomes a default.
    func add(_ model: String) async {
        let m = Self.clean(model)
        guard !m.isEmpty else { return }
        busy = "Checking…"
        problem = nil
        let r = await Self.call("model", ["model": m])
        busy = nil
        if let e = r["error"] as? String { problem = e; return }
        await save(models + [m])
    }

    func remove(_ model: String) async { await save(models.filter { $0 != model }) }

    func makeDefault(_ model: String) async { await save([model] + models.filter { $0 != model }) }

    private func save(_ list: [String]) async {
        let r = await Self.call("set_models", ["models": list])
        if let e = r["error"] as? String { problem = e; return }
        models = r["models"] as? [String] ?? list
    }

    /// "https://replicate.com/bytedance/seedance-2.5/" → "bytedance/seedance-2.5".
    nonisolated static func clean(_ s: String) -> String {
        var m = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "replicate.com/", "www.replicate.com/"] where m.hasPrefix(p) { m.removeFirst(p.count) }
        return m.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// "bytedance/seedance-2.5" → "Seedance 2.5" (like rep_label in the MCP).
    nonisolated static func label(_ model: String) -> String {
        let name = model.split(separator: "/").last.map { String($0.split(separator: ":")[0]) } ?? model
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { w in
                if w.count == 3, w.dropFirst().first == "2" { return w.uppercased() }  // i2v → I2V
                return w.first?.isNumber == true ? String(w) : w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")
    }

    // MARK: Asks for the chat

    nonisolated static func shotPrompt(_ shot: StoryShot) -> String {
        "Make the clip for storyboard shot \(shot.id) with Replicate (the replicate tool, shot=\(shot.id)), with my default model. "
            + "Write a real-footage prompt from the shot's lines and how to film it. Use the sketch only as a composition "
            + "reference if the model takes reference images, never as the first frame."
    }

    nonisolated static func changeDraft(_ rel: String) -> String { "Change \(rel) with Replicate: " }
}

/// Which service makes a video when the user presses ✦ on a shot or changes a video on Assets: Replicate
/// once its token is in (it costs less), else Higgsfield. Nil when both plugins are off.
enum VideoMaker {
    case replicate, higgsfield

    @MainActor static var current: VideoMaker? {
        let rep = Plugins.isInstalled(ReplicatePage.plugin.id), hf = Plugins.isInstalled(HiggsfieldPage.plugin.id)
        if rep && (Replicate.shared.connected || !hf) { return .replicate }
        return hf ? .higgsfield : nil
    }

    var name: String { self == .replicate ? "Replicate" : "Higgsfield" }
    var plugin: String { self == .replicate ? ReplicatePage.plugin.id : HiggsfieldPage.plugin.id }

    func shotPrompt(_ shot: StoryShot) -> String {
        self == .replicate ? Replicate.shotPrompt(shot) : Higgsfield.shotPrompt(shot)
    }

    func changeDraft(_ rel: String) -> String {
        self == .replicate ? Replicate.changeDraft(rel) : Higgsfield.changeDraft(rel)
    }

    /// Set up, so a job can start. Checks again first when it does not know yet.
    @MainActor func ready() async -> Bool {
        switch self {
        case .replicate:
            if !Replicate.shared.connected { await Replicate.shared.refresh() }
            return Replicate.shared.connected
        case .higgsfield:
            if !Higgsfield.shared.ready { await Higgsfield.shared.check() }
            return Higgsfield.shared.ready
        }
    }
}

/// Plugins › Replicate: the token and the default video models. The board draws the title.
struct ReplicatePage: View {
    private var rep = Replicate.shared
    @State private var key = ""
    @State private var changingKey = false
    @State private var adding = ""
    @State private var open: VideoModel?

    static let plugin = TakesPlugin(
        id: "replicate", title: "Replicate", icon: "film.stack", key: " ",
        help: "Make and change videos with AI on Replicate: Seedance, Kling, Veo and more. You pay Replicate per second of video, with no plan.",
        badge: { _ in AnyView(EmptyView()) }, board: nil,
        settings: { _ in AnyView(ReplicatePage()) })

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            card { account }
            if rep.connected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default video models").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("Takes uses the first one unless you name another in the chat. Length, shape, sound and quality: just ask Takes.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    card {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(rep.models.enumerated()), id: \.element) { i, m in modelRow(m, first: i == 0) }
                            HStack(spacing: 8) {
                                TextField("owner/name, or paste the model's replicate.com link", text: $adding)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(add)
                                Button(rep.busy ?? "Add", action: add)
                                    .disabled(Replicate.clean(adding).isEmpty || rep.busy != nil)
                            }
                            .padding(.top, 6)
                            if let p = rep.problem {
                                Text(p).font(Theme.sans(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                browser
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Where to use it").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                use("sparkles", "Storyboard", "Press ✦ on a shot. Takes writes the prompt from the shot, and the clip plays on the shot.")
                use("photo.on.rectangle", "Assets", "Right-click a video › Change with Replicate…, then say what to change.")
                use("bubble.left", "Chat", "Ask Takes, for example: \"Make a 5 s clip of my desk at sunrise, 480p first\".")
                Text("New files land in the session's generated folder. With Replicate connected, ✦ and Assets use it before Higgsfield.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await rep.refresh()
            if rep.connected { await rep.loadCatalog() }
        }
        .sheet(item: $open) { m in
            ModelSheet(card: m, provider: "Replicate", load: { await Replicate.call("details", ["model": m.model]) },
                       action: { action(m) })
        }
    }

    /// Featured and most popular video models, each with its preview. Nothing shows until the
    /// lists are in; then the cards arrive in order.
    @ViewBuilder private var browser: some View {
        if !rep.featured.isEmpty || !rep.popular.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                shelf("Featured", "The newest models from the big video labs.", rep.featured, from: 0)
                shelf("Most popular", "Run the most on Replicate.", rep.popular, from: rep.featured.count)
                Button("See all video models on replicate.com") { NSWorkspace.shared.openSoon(Replicate.explore) }
                    .buttonStyle(.link).font(Theme.sans(12))
            }
        }
    }

    private func shelf(_ title: String, _ detail: String, _ cards: [VideoModel], from: Int) -> some View {
        ModelShelf(title: title, detail: detail, models: cards, from: from,
                   caption: { Replicate.runs($0.runs) }, action: action, open: { open = $0 })
    }

    private func action(_ m: VideoModel) -> ModelAction {
        ModelAction(title: "Add", done: rep.models.contains(m.model) ? "Added" : nil,
                    help: "Add to your default video models") { Task { await rep.add(m.model) } }
    }

    @ViewBuilder private var account: some View {
        switch rep.state {
        case .unknown:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(Theme.sans(12.5)).foregroundStyle(Theme.muted) }
        case .noKey:
            keyForm("Connect Replicate", "Paste an API token from replicate.com › Account › API tokens. Takes keeps it in your Keychain.")
        case .failed(let why):
            keyForm("Replicate is not connected", why)
        case .ready(let line):
            if changingKey {
                keyForm("Change the API token", "The new token replaces the old one in your Keychain.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connected").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                        Text(line).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    Button("Change Token") { changingKey = true }
                    Button("Disconnect") { Task { await rep.removeKey() } }
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
                SecureField("r8_…", text: $key).textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(action: save) {
                    Text(rep.busy ?? "Connect").font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || rep.busy != nil)
            }
            HStack(spacing: 12) {
                Button("Get a token") { NSWorkspace.shared.openSoon(Replicate.tokens) }.buttonStyle(.link)
                if changingKey { Button("Cancel") { changingKey = false; key = "" }.buttonStyle(.link) }
            }
            .font(Theme.sans(12))
        }
    }

    private func save() {
        let k = key
        key = ""
        changingKey = false
        Task { await rep.saveKey(k) }
    }

    private func add() {
        let m = adding
        Task {
            await rep.add(m)
            if rep.problem == nil { adding = "" }
        }
    }

    private func modelRow(_ m: String, first: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Replicate.label(m)).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(m).font(Theme.mono(11)).foregroundStyle(Theme.faint).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if first {
                Text("Default").font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.accentInk)
            } else {
                Button("Make Default") { Task { await rep.makeDefault(m) } }.font(Theme.sans(11.5))
            }
            Button { Task { await rep.remove(m) } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Remove from the defaults")
                .disabled(rep.models.count == 1)
        }
        .padding(.vertical, 2)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
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
