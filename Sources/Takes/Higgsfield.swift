import AppKit
import Foundation
import Observation
import SwiftUI

/// Higgsfield in Takes (2026-10-06): make and change videos with Seedance, Kling, Veo and 30+ more
/// video models. Images go to GPT Image 2.5 directly (the make_image tool), which costs much less. Takes installs Higgsfield's official CLI into ~/.local/bin and
/// signs in with Higgsfield's own browser sign-in (no API key). The takes MCP's `higgsfield` tool
/// runs the jobs, so the chat, a storyboard shot and the Assets tab all use the same path.
@MainActor @Observable
final class Higgsfield {
    static let shared = Higgsfield()
    init() {}

    enum State: Equatable {
        case unknown, missing
        /// Installed, not signed in. The CLI's reason when it says more than "not signed in".
        case signedOut(String?)
        /// The account line: "me@example.com — Basic plan, 120 credits".
        case ready(String)
        case working(String)
        case failed(String)
    }

    var state: State = .unknown
    var ready: Bool { if case .ready = state { return true } else { return false } }
    @ObservationIgnored private var login: Process?

    nonisolated static var cli: String? { Setup.tool("higgsfield") }
    static let pricing = URL(string: "https://higgsfield.ai/pricing")!

    // MARK: Models (2026-10-09)

    /// Hand-picked, with the same model's preview from Replicate; then the rest, without pictures.
    var featured: [VideoModel] = []
    var more: [VideoModel] = []
    /// The job type ✦ and the chat use.
    var defaultModel = "seedance_2_5"

    nonisolated static func call(_ what: String, _ args: [String: Any] = [:]) async -> [String: Any] {
        await ElevenLabs.call(what, args, flag: "--higgsfield")
    }

    func loadCatalog() async {
        let r = await Self.call("catalog")
        featured = VideoModel.list(r, "featured")
        more = VideoModel.list(r, "more")
        if let d = r["default"] as? String { defaultModel = d }
    }

    func makeDefault(_ model: String) async {
        let r = await Self.call("set_default", ["model": model])
        if let d = r["default"] as? String { defaultModel = d }
    }

    /// "Seedance 2.5" for the default, from the lists.
    var defaultLabel: String {
        (featured + more).first { $0.model == defaultModel }?.label ?? defaultModel
    }

    func check() async {
        if case .working = state { return }
        guard let cli = Self.cli else { state = .missing; return }
        var (ok, out) = await Task.detached(priority: .utility) { Setup.run(cli, ["account", "status"]) }.value
        // The sign-in leaves no workspace picked, and the button looped back to "Sign in" (2026-10-08).
        // With one workspace, pick it; with more, the message says to pick one.
        if !ok, out.lowercased().contains("no workspace selected") {
            (ok, out) = await Task.detached(priority: .utility) {
                let (_, list) = Setup.run(cli, ["workspace", "list", "--json"])
                guard let id = Higgsfield.onlyWorkspace(list) else { return (false, out) }
                _ = Setup.run(cli, ["workspace", "set", id])
                return Setup.run(cli, ["account", "status"])
            }.value
        }
        state = Self.state(ok: ok, out: out)
    }

    /// The id from `higgsfield workspace list --json` when there is exactly one workspace.
    nonisolated static func onlyWorkspace(_ json: String) -> String? {
        guard let all = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
              all.count == 1 else { return nil }
        return all[0]["id"] as? String
    }

    nonisolated static func state(ok: Bool, out: String) -> State {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if ok, let first = lines.first { return .ready(first) }
        let err = lines.first { $0.lowercased().hasPrefix("error") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let plain = err.map { e in ["not authenticated", "session expired"].contains { e.lowercased().contains($0) } } ?? true
        return .signedOut(plain ? nil : err)
    }

    /// Higgsfield's installer, into ~/.local/bin (no sudo). `--no-hf` leaves Hugging Face's `hf` alone.
    func install() {
        state = .working("Installing…")
        Task {
            let (ok, out) = await Task.detached(priority: .userInitiated) {
                Setup.run("/bin/bash", ["-c", "curl -fsSL https://raw.githubusercontent.com/higgsfield-ai/cli/main/install.sh | sh -s -- --prefix=\"$HOME/.local\" --no-hf"])
            }.value
            if ok, Self.cli != nil {
                state = .unknown
                await check()
            } else {
                state = .failed(out.split(separator: "\n").last.map(String.init) ?? "The install did not finish.")
            }
        }
    }

    /// `higgsfield auth login` opens the browser and waits for its sign-in page to call back.
    func signIn() {
        guard let cli = Self.cli else { state = .missing; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            Task { @MainActor in
                let s = Higgsfield.shared
                s.login = nil
                s.state = .unknown
                await s.check()
            }
        }
        do {
            try p.run()
            login = p
            state = .working("Finish the sign-in in your browser…")
        } catch {
            state = .failed("Could not start the sign-in.")
        }
    }

    func cancelSignIn() { login?.terminate() }

    func signOut() {
        guard let cli = Self.cli else { return }
        state = .working("Signing out…")
        Task {
            _ = await Task.detached { Setup.run(cli, ["auth", "logout"]) }.value
            state = .unknown
            await check()
        }
    }

    // MARK: Asks for the chat

    /// The chat message the ✦ button on a storyboard shot sends.
    nonisolated static func shotPrompt(_ shot: StoryShot) -> String {
        "Make the clip for storyboard shot \(shot.id) with Higgsfield (the higgsfield tool, shot=\(shot.id)). "
            + "Write a real-footage prompt from the shot's lines and how to film it, and use its sketch as the composition reference."
    }

    /// The draft "Change with Higgsfield…" puts in the chat box: The user types what to change.
    nonisolated static func changeDraft(_ rel: String) -> String { "Change \(rel) with Higgsfield: " }
    /// Images go to GPT Image directly, not Higgsfield: much cheaper.
    nonisolated static func imageDraft(_ rel: String) -> String { "Change \(rel) with make_image: " }

    /// Images are GPT Image drafts until the user likes one (2026-10-09); then Make Final redraws it with
    /// Nano Banana 2.1 at 4K. A GPT label in .models.json marks a draft.
    nonisolated static func isDraft(_ url: URL) -> Bool { MadeWith.label(for: url)?.hasPrefix("GPT Image") == true }
    nonisolated static func finalAsk(_ rel: String, shot: String? = nil) -> String {
        "Make the final of \(rel) with make_image (from=\(rel)): Nano Banana 2.1 at 4K, the same picture, sharp."
            + (shot.map { " Then add it to storyboard shot \($0)'s variants right after \(rel) with set_storyboard, and put it in the video if \(rel) is." } ?? "")
    }
}

/// Plugins › Higgsfield (Settings › Higgsfield until 2026-10-08). The board draws the title.
struct HiggsfieldPage: View {
    private var hf = Higgsfield.shared
    @State private var open: VideoModel?

    static let plugin = TakesPlugin(
        id: "higgsfield", title: "Higgsfield", icon: "sparkles", key: " ",
        help: "Make and change videos with AI: Seedance, Kling, Veo and 30+ more video models. Uses the credits of your Higgsfield plan.",
        badge: { _ in AnyView(EmptyView()) }, board: nil,
        settings: { _ in AnyView(HiggsfieldPage()) })

    var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                account
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                if hf.ready { models }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where to use it").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    use("sparkles", "Storyboard", "Press ✦ on a shot. Takes writes the prompt from the shot and its sketch, and the clip plays on the shot.")
                    use("photo.on.rectangle", "Assets", "Right-click a video › Change with Higgsfield…, then say what to change.")
                    use("bubble.left", "Chat", "Ask Takes, for example: \"Make a 5 s clip of my desk at sunrise\" or \"Make this edit vertical\".")
                    Text("New files land in the session's generated folder.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                }
            }
        .task {
            await hf.check()
            if hf.ready { await hf.loadCatalog() }
        }
        .sheet(item: $open) { m in
            ModelSheet(card: m, provider: "Higgsfield", load: { await Higgsfield.call("details", ["model": m.model]) },
                       action: { action(m) })
        }
    }

    /// The video model Takes uses, and the browser to pick another. Nothing shows until the lists are in.
    @ViewBuilder private var models: some View {
        if !hf.featured.isEmpty || !hf.more.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Video model:").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(hf.defaultLabel).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.accentInk)
                    Text("for ✦ and the chat, unless you name another.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                .arrive(0)
                ModelShelf(title: "Featured", detail: "Previews from the same models on Replicate.", models: hf.featured, from: 1,
                           caption: { $0.model }, action: action, open: { open = $0 })
                ModelChips(title: "More video models", detail: "Click one for its price and settings.", models: hf.more,
                           from: hf.featured.count + 2, open: { open = $0 })
            }
        }
    }

    private func action(_ m: VideoModel) -> ModelAction {
        ModelAction(title: "Use", done: hf.defaultModel == m.model ? "In use" : nil,
                    help: "Use this model for ✦ and the chat") { Task { await hf.makeDefault(m.model) } }
    }

    @ViewBuilder private var account: some View {
        switch hf.state {
        case .unknown:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(Theme.sans(12.5)).foregroundStyle(Theme.muted) }
        case .missing:
            row("Install Higgsfield", "Higgsfield's own command-line tool, about 18 MB, into ~/.local/bin.", "Install", hf.install)
        case .signedOut(let why):
            row("Sign in to Higgsfield", why ?? "Opens your browser. New to Higgsfield? You can make an account there.", "Sign in", hf.signIn)
        case .working(let what):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(what).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                Spacer()
                if what.contains("browser") { Button("Cancel") { hf.cancelSignIn() } }
            }
        case .failed(let why):
            row("Higgsfield could not be set up", why, "Try again") { hf.state = .unknown; Task { await hf.check() } }
        case .ready(let line):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                    Text(line).font(Theme.sans(12)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Get credits") { NSWorkspace.shared.openSoon(Higgsfield.pricing) }
                Button("Sign out") { hf.signOut() }
            }
        }
    }

    private func row(_ title: String, _ detail: String, _ action: String, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(Theme.faint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: run) {
                Text(action).font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
