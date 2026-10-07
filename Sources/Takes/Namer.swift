import Foundation

/// Names sessions from their script. Tries fast hosted models first, in order:
///
///   1. DeepSeek Flash (api.deepseek.com)     DEEPSEEK_API_KEY     ~1s
///   2. Gemini 3.8 Flash (Google AI)          GOOGLE_AI_API_KEY    ~0.8s
///   3. The local `claude` CLI (Haiku)        slow: the CLI takes seconds to boot
///   4. The first words of the script
///
/// Keys: see `Keys`. Each hosted model gets 8 seconds, then the next one takes over.
enum Namer {
    static func title(for script: String, project: String) async -> String? {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let excerpt = String(text.prefix(6000))
        let prompt = """
        You name video recording sessions. Project: "\(project)". Below is the script for one video.
        Reply with ONLY a short title of 2 to 6 words that says what the video is about. \
        No quotes, no punctuation at the end, no preamble.

        \(excerpt)
        """
        let keys = Keys.load()
        if let k = keys["DEEPSEEK_API_KEY"], let t = clean(await deepSeek("deepseek-flash", prompt, key: k)) { return t }
        if let k = keys["GOOGLE_AI_API_KEY"] ?? keys["GEMINI_API_KEY"],
           let t = clean(await gemini("gemini-3.8-flash", prompt, key: k)) { return t }
        if let t = clean(await askClaude(script: excerpt, project: project)) { return t }
        return fallback(text)
    }

    static func fallback(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# *-").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? "Untitled"
        return line.split(separator: " ").prefix(6).joined(separator: " ")
    }

    private static func clean(_ raw: String?) -> String? {
        guard let line = raw?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
            .map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.")) }),
              !line.isEmpty, line.count < 80 else { return nil }
        return line
    }

    // MARK: Hosted models

    private static func post(_ url: String, headers: [String: String], body: [String: Any]) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func deepSeek(_ model: String, _ prompt: String, key: String) async -> String? {
        // Thinking off: with it on, the reasoning eats the token budget and the answer comes back empty.
        let json = await post("https://api.deepseek.com/chat/completions",
                              headers: ["Authorization": "Bearer \(key)"],
                              body: ["model": model, "max_tokens": 40, "thinking": ["type": "disabled"],
                                     "messages": [["role": "user", "content": prompt]]])
        let choice = (json?["choices"] as? [[String: Any]])?.first
        return (choice?["message"] as? [String: Any])?["content"] as? String
    }

    private static func gemini(_ model: String, _ prompt: String, key: String) async -> String? {
        let json = await post("https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent",
                              headers: ["x-goog-api-key": key],
                              body: ["contents": [["parts": [["text": prompt]]]],
                                     "generationConfig": ["maxOutputTokens": 40, "thinkingConfig": ["thinkingBudget": 0]]])
        let parts = (((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        return parts?.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: Local Claude CLI (last resort before the plain fallback)

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func askClaude(script: String, project: String) async -> String? {
        guard let path = claudePath else { return nil }
        let prompt = """
        You name video recording sessions. Project: "\(project)". Below on stdin is the script for one video.
        Reply with ONLY a short title of 2 to 6 words that says what the video is about. \
        No quotes, no punctuation at the end, no preamble.
        """
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = ["-p", prompt, "--model", "haiku"]
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                let input = Pipe(), output = Pipe()
                p.standardInput = input
                p.standardOutput = output
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}

/// API keys, later sources win: your notes repo/.env, ~/.claude/.env, the process environment. Never logged.
enum Keys {
    static let files = [".config/takes/.env", ".claude/.env"]

    static func load() -> [String: String] {
        var out: [String: String] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let text = files.filter { Plugins.own || !$0.hasPrefix("Documents/") }.compactMap { try? String(contentsOf: home.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")
        for line in text.split(whereSeparator: \.isNewline) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }
            if l.hasPrefix("export ") { l.removeFirst(7) }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let v = l[l.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !v.isEmpty { out[String(l[..<eq])] = v }
        }
        for (k, v) in ProcessInfo.processInfo.environment where k.hasSuffix("_API_KEY") && !v.isEmpty { out[k] = v }
        return out
    }
}
