import AppKit
import SwiftUI

/// The Gemini key (2026-10-08, after a demo where a new user asked "do I need Gemini?"). Takes
/// works without it; a few features use it. Settings › Gemini says which ones, and saves a pasted
/// key as GEMINI_API_KEY in ~/.claude/.env, where the app (`Keys`) and the takes MCP both read it.
enum GeminiKey {
    static let names = ["GEMINI_API_KEY", "GOOGLE_AI_API_KEY"]
    static let getKey = URL(string: "https://aistudio.google.com/apikey")!

    static var envFile: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.env") }

    static var found: Bool { let k = Keys.load(); return names.contains { k[$0] != nil } }

    /// What uses the key, and what happens without it.
    static let uses: [(icon: String, title: String, without: String)] = [
        ("pencil.and.scribble", "Storyboard sketches", "Without it, GPT Image draws them with an OpenAI key, or Nano Banana with a Replicate token. Else the chat can draw them itself."),
        ("film.stack", "B-roll names and descriptions", "Gemini watches each clip you save, so Takes can find it later. Without it, a clip keeps its file name."),
        ("scissors", "Best cut of a storyboard take", "Gemini finds the clean part of each take. Without it, Takes finds it when it edits."),
        ("textformat", "Session names", "Faster names for new sessions. Without it, Claude names them."),
    ]

    /// The .env text with `key` as its GEMINI_API_KEY: an old GEMINI_API_KEY line goes, every
    /// other line stays as it was.
    static func withKey(_ text: String, _ key: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("export ") { l.removeFirst(7) }
            return l.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "GEMINI_API_KEY"
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("GEMINI_API_KEY=\(key)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func save(_ key: String, to file: URL = envFile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try withKey(old, key).write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Asks Google whether the key works. nil means yes; else why not.
    static func check(_ key: String) async -> String? {
        var r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        r.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: r) else {
            return "Could not reach Google. Check the connection and try again."
        }
        return (response as? HTTPURLResponse)?.statusCode == 200 ? nil : "Google did not accept this key."
    }
}

/// Takes › Settings › Gemini.
struct GeminiPage: View {
    @State private var found = GeminiKey.found
    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var changing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gemini").font(Theme.display(26)).foregroundStyle(Theme.ink)
                    Text("Takes records, writes, edits and posts without Gemini. A Google Gemini key adds the parts below. Google bills its use to your Google account.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                card { account }
                VStack(alignment: .leading, spacing: 12) {
                    Text("What uses it").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    ForEach(GeminiKey.uses, id: \.title) { u in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: u.icon).font(.system(size: 13)).foregroundStyle(Theme.accentInk).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                                Text(u.without).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
        .onAppear { found = GeminiKey.found }
    }

    @ViewBuilder private var account: some View {
        if found && !changing {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                    Text("Takes found a Gemini key.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button("Change Key") { changing = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(changing ? "Change the key" : "Add a Gemini key").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                    Text(problem ?? "Paste a key from Google AI Studio. Takes keeps it in ~/.claude/.env, where Claude Code finds it too.")
                        .font(Theme.sans(12)).foregroundStyle(problem == nil ? Theme.muted : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    SecureField("API key", text: $key).textFieldStyle(.roundedBorder).onSubmit(save)
                    Button(action: save) {
                        Text(busy ? "Checking…" : "Save").font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Theme.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                HStack(spacing: 12) {
                    Button("Get a key") { NSWorkspace.shared.openSoon(GeminiKey.getKey) }.buttonStyle(.link)
                    if changing { Button("Cancel") { changing = false; key = ""; problem = nil }.buttonStyle(.link) }
                }
                .font(Theme.sans(12))
            }
        }
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !busy else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            if let why = await GeminiKey.check(k) { problem = why; return }
            do {
                try GeminiKey.save(k)
                key = ""
                changing = false
                found = true
            } catch {
                problem = "Could not save the key: \(error.localizedDescription)"
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}
