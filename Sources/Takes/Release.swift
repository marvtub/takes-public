import AppKit
import Foundation
import Observation

/// Takes > Release to GitHub (2026-10-04): runs scripts/public/release.sh in the background. It
/// copies origin/main without personal values, tests the copy and pushes the public repo. The
/// script itself comes from origin/main too, so the checkout's branch or edits never matter.
/// build.sh writes the repo into Info.plist (ReleaseRepo) only where the script exists, so a
/// build of the public copy has no Release item.
@MainActor @Observable
final class Releaser {
    static let shared = Releaser()

    nonisolated static let repo: String? = Bundle.main.object(forInfoDictionaryKey: "ReleaseRepo") as? String
    nonisolated static var available: Bool { repo.map { FileManager.default.fileExists(atPath: $0 + "/.git") } ?? false }
    /// Fetches, then runs origin/main's release.sh; extra arguments follow it.
    nonisolated static func command(_ repo: String) -> String {
        let r = "'" + repo.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "git -C \(r) fetch -q origin && TAKES_REPO=\(r) bash <(git -C \(r) show origin/main:scripts/public/release.sh)"
    }

    private(set) var running = false
    /// The script's last progress line, shown in the menu while it runs.
    private(set) var step = ""
    @ObservationIgnored private var output = ""

    var menuTitle: String { running ? "Releasing… \(step)" : "Release to GitHub…" }

    /// Asks first (the push is public once the repo is), then runs. `toast` gets the result.
    func confirmAndRun(toast: @escaping (String) -> Void) {
        guard let repo = Self.repo, !running else { return }
        let alert = NSAlert()
        alert.messageText = "Release Takes to GitHub?"
        alert.informativeText = "Takes copies main without your personal data, builds and tests the copy, "
            + "and pushes it to the public repo. It runs in the background and takes a few minutes."
        alert.addButton(withTitle: "Release")
        alert.addButton(withTitle: "Cancel")
        let media = NSButton(checkboxWithTitle: "Redraw the README pictures first", target: nil, action: nil)
        alert.accessoryView = media
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(repo, args: media.state == .on ? ["--media"] : [], toast: toast)
    }

    private func run(_ repo: String, args: [String], toast: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Self.command(repo) + " " + args.joined(separator: " ")]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in Releaser.shared.read(text) }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            let ok = p.terminationStatus == 0
            Task { @MainActor in Releaser.shared.finish(ok: ok, toast: toast) }
        }
        output = ""
        step = "starting"
        running = true
        do { try p.run() } catch { finish(ok: false, toast: toast) }
    }

    private func read(_ text: String) {
        output += text
        if let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            step = last.replacingOccurrences(of: "…", with: "").lowercased()
        }
    }

    private func finish(ok: Bool, toast: @escaping (String) -> Void) {
        running = false
        step = ""
        let lines = output.split(separator: "\n").map(String.init)
        if ok {
            toast(lines.contains { $0.hasPrefix("No changes") } ? "Released: nothing new since the last release"
                                                              : "Released to GitHub")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The release stopped"
        alert.informativeText = lines.suffix(12).joined(separator: "\n")
        alert.runModal()
    }

    /// One line for the chat agents, so "release Takes" works from any chat.
    nonisolated static var agentNote: String? {
        guard available, let repo else { return nil }
        return "To release Takes to its public GitHub repo (only when asked), run in bash: \(command(repo)). It copies "
            + "origin/main without personal data, tests the copy and pushes it, then prints the result. "
            + "Never edit or build the public copy by hand."
    }
}
