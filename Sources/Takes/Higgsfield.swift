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

    func check() async {
        if case .working = state { return }
        guard let cli = Self.cli else { state = .missing; return }
        let (ok, out) = await Task.detached(priority: .utility) { Setup.run(cli, ["account", "status"]) }.value
        state = Self.state(ok: ok, out: out)
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
}

/// Takes › Settings › Higgsfield.
struct HiggsfieldPage: View {
    private var hf = Higgsfield.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Higgsfield").font(Theme.display(26)).foregroundStyle(Theme.ink)
                    Text("Make and change videos with AI, inside Takes: Seedance, Kling, Veo and 30+ more video models. Uses the credits of your Higgsfield plan.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                account
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where to use it").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    use("sparkles", "Storyboard", "Press ✦ on a shot. Takes writes the prompt from the shot and its sketch, and the clip plays on the shot.")
                    use("photo.on.rectangle", "Assets", "Right-click a video › Change with Higgsfield…, then say what to change.")
                    use("bubble.left", "Chat", "Ask Takes, for example: \"Make a 5 s clip of my desk at sunrise\" or \"Make this edit vertical\".")
                    Text("New files land in the session's generated folder.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
        .task { await hf.check() }
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
                Button("Get credits") { NSWorkspace.shared.open(Higgsfield.pricing) }
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
