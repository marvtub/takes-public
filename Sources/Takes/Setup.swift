import AppKit
import Foundation
import Observation
import SwiftUI

/// What a new Mac needs before Takes works (2026-10-05): Claude Code, signed in, and ffmpeg.
/// A downloaded Takes checks this at launch and each time it comes to the front. While a step is
/// missing, the sidebar shows Finish setup; its panel fixes each step with one click. The app
/// installs Claude Code with Anthropic's installer and ffmpeg as a static build in ~/.local/bin
/// (no Homebrew needed). Sign-in opens Terminal, because `claude auth login` needs a terminal.
@MainActor @Observable
final class Setup {
    static let shared = Setup()
    init() {}

    enum Status: Equatable { case unknown, ok, missing, working, failed(String) }

    var claude: Status = .unknown
    var signedIn: Status = .unknown
    var ffmpeg: Status = .unknown
    private var checking = false

    /// True once a check found something to do. Nothing shows before the first check ends.
    var needed: Bool { [claude, signedIn, ffmpeg].contains { $0 != .ok && $0 != .unknown } }
    var left: Int { [claude, signedIn, ffmpeg].filter { $0 != .ok }.count }

    nonisolated static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    nonisolated static var localBin: String { home + "/.local/bin" }

    /// ffmpeg or ffprobe: Homebrew, the usual places, or the copy Takes downloads.
    nonisolated static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", localBin + "/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        Task { await check() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = Setup.shared
                if s.needed { Task { await s.check() } }
            }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let path = Namer.claudePath
        let (signed, hasFFmpeg) = await Task.detached(priority: .utility) {
            (path.map { Self.isSignedIn(claude: $0) } ?? false, Self.tool("ffmpeg") != nil && Self.tool("ffprobe") != nil)
        }.value
        if claude != .working { claude = path == nil ? .missing : .ok }
        if signedIn != .working { signedIn = signed ? .ok : .missing }
        if ffmpeg != .working { ffmpeg = hasFFmpeg ? .ok : .missing }
    }

    nonisolated static func isSignedIn(claude: String) -> Bool {
        let (_, out) = run(claude, ["auth", "status"])
        return signedIn(status: out)
    }

    /// `claude auth status` prints JSON with "loggedIn".
    nonisolated static func signedIn(status: String) -> Bool {
        guard let start = status.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(status[start...].utf8)) as? [String: Any]
        else { return false }
        return json["loggedIn"] as? Bool ?? false
    }

    // MARK: Fixes

    func installClaude() {
        claude = .working
        Task {
            let (ok, out) = await Task.detached(priority: .userInitiated) {
                Self.run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"])
            }.value
            claude = ok && Namer.claudePath != nil ? .ok : .failed(Self.lastLine(out) ?? "The install did not finish.")
            if claude == .ok { AgentSetup.run() }
            await check()
        }
    }

    /// Opens Terminal on `claude auth login`. Takes checks again when it comes back to the front.
    func signIn() {
        guard let claude = Namer.claudePath else { return }
        let script = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "takes-sign-in.command")
        let text = """
        #!/bin/bash
        clear
        echo "Sign in to Claude Code for Takes. Your browser opens."
        '\(claude)' auth login
        echo
        echo "Done. You can close this window and go back to Takes."
        """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.openSoon(script)
        } catch {
            signedIn = .failed("Could not open Terminal. Run claude auth login in Terminal.")
        }
    }

    func installFFmpeg() {
        ffmpeg = .working
        Task {
            do {
                try await Self.downloadFFmpeg()
                ffmpeg = .ok
            } catch {
                ffmpeg = .failed(error.localizedDescription)
            }
            await check()
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// The static arm64 builds that ffmpeg.org links to, checked against their SHA-256.
    nonisolated static func downloadFFmpeg(to bin: String = localBin) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] where !fm.isExecutableFile(atPath: bin + "/" + name) {
            let latest = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/\(name).zip")!
            let (zip, response) = try await URLSession.shared.download(from: latest)
            guard let real = response.url, (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure("The \(name) download failed. Try again later.")
            }
            let (sum, _) = try await URLSession.shared.data(from: real.appendingPathExtension("sha256"))
            let want = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let (_, got) = run("/usr/bin/shasum", ["-a", "256", zip.path])
            guard !want.isEmpty, got.hasPrefix(want) else { throw Failure("The \(name) download did not match its checksum.") }
            let dir = fm.temporaryDirectory.appending(path: "takes-\(name)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: zip) }
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).0 else { throw Failure("Could not unpack \(name).") }
            let dest = bin + "/" + name
            try? fm.removeItem(atPath: dest)
            try fm.moveItem(at: dir.appending(path: name), to: URL(fileURLWithPath: dest))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        }
    }

    nonisolated private static func lastLine(_ s: String) -> String? {
        s.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// "Finish setup" at the top of the sidebar while a step is missing. It opens the checklist.
struct SetupButton: View {
    private var setup = Setup.shared
    @State private var open = false
    @State private var hover = false

    var body: some View {
        if setup.needed {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checklist").frame(width: 16)
                    Text("Finish setup").font(Theme.sans(13, .semibold))
                    Spacer(minLength: 4)
                    Text(setup.left == 1 ? "1 step" : "\(setup.left) steps").font(Theme.sans(11, .medium)).opacity(0.8)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover || open ? Theme.accent.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.bottom, 4)
            .popover(isPresented: $open, arrowEdge: .trailing) { SetupPanel(setup: setup) }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// The three steps, each with its state and the button that does it.
struct SetupPanel: View {
    var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Finish setup").font(Theme.display(17))
                Text("Takes records on its own. These steps let Takes storyboard, edit and write posts for you.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 14) {
                step("Install Claude Code", "The assistant behind Takes. Uses your Claude plan.",
                     setup.claude, action: "Install", busy: "Installing…", setup.installClaude)
                step("Sign in", "Opens Terminal and then your browser. Come back here when you are done.",
                     setup.claude == .ok ? setup.signedIn : .missing, action: "Sign in", busy: "Waiting…",
                     enabled: setup.claude == .ok, setup.signIn)
                step("Get ffmpeg", "Cuts and exports video. About 60 MB, into ~/.local/bin.",
                     setup.ffmpeg, action: "Download", busy: "Downloading…", setup.installFFmpeg)
            }
            .padding(18)
        }
        .frame(width: 400)
        .background(Theme.paper)
        .task { await setup.check() }
    }

    private func step(_ title: String, _ detail: String, _ status: Setup.Status, action: String, busy: String,
                      enabled: Bool = true, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status == .ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15)).foregroundStyle(status == .ok ? Theme.accent : Theme.faint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                if case .failed(let why) = status {
                    Text(why).font(Theme.sans(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if status != .ok {
                    Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if status == .working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            } else if status != .ok {
                Button(action: run) {
                    Text(action).font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }
}
