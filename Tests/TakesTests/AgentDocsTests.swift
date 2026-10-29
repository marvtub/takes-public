import Foundation
import Testing

/// The AGENTS.md files point agents at files (2026-10-09). Their old file list fell 76 files behind
/// the code, so now a renamed or deleted file fails here until the docs follow it.
struct AgentDocsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every path in the repo, relative to its root. Build output and git are left out.
    static func paths() -> [String] {
        let skip: Set<String> = [".git", ".build", "build.noindex", "node_modules", "__pycache__"]
        let root = repo.standardizedFileURL.path + "/"
        var out: [String] = []
        let walk = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if skip.contains(url.lastPathComponent) { walk?.skipDescendants(); continue }
            out.append(String(url.standardizedFileURL.path.dropFirst(root.count)))
        }
        return out
    }

    /// The `code` spans of a doc that name a file in the repo: a source or script file name, or a
    /// path that starts at a top-level folder. Patterns (`Phone*.swift`, `<name>`), home and
    /// absolute paths, and paths in the library on disk (`edits/`) are not checked.
    static func references(in text: String, topLevel: Set<String>) -> [String] {
        let spans = text.split(separator: "`", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        return spans.filter { s in
            guard !s.isEmpty, !s.contains(where: { " *<>=({~$".contains($0) }),
                  !s.hasPrefix("/"), !s.hasPrefix("..") else { return false }
            let s = s.hasPrefix("./") ? String(s.dropFirst(2)) : s
            let isCode = [".swift", ".py", ".sh", ".yml"].contains { s.hasSuffix($0) }
            let first = s.split(separator: "/").first.map(String.init) ?? s
            return isCode || (s.contains("/") && topLevel.contains(first))
        }
    }

    @Test func everyFileTheDocsNameExists() throws {
        let all = Self.paths()
        let topLevel = Set(all.filter { !$0.contains("/") })
        let docs = all.filter { $0 == "AGENTS.md" || $0.hasSuffix("/AGENTS.md") }
        #expect(docs.count >= 3, "AGENTS.md, ios/AGENTS.md and mcp/AGENTS.md")
        var missing: [String] = []
        for doc in docs {
            let text = try String(contentsOf: Self.repo.appending(path: doc), encoding: .utf8)
            let dir = doc.contains("/") ? String(doc[..<doc.lastIndex(of: "/")!]) + "/" : ""
            for ref in Self.references(in: text, topLevel: topLevel) {
                let r = (ref.hasPrefix("./") ? String(ref.dropFirst(2)) : ref)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // From the repo root, from the doc's folder, or the end of a path (`Plugins/Feedback.swift`).
                let found = all.contains { $0 == r || $0 == dir + r || $0.hasSuffix("/" + r) }
                if !found { missing.append("\(doc): `\(ref)`") }
            }
        }
        #expect(missing.isEmpty, "The docs name files that are gone:\n\(missing.joined(separator: "\n"))")
        // The parser finds names of files, not folders, globs or home paths.
        let refs = Self.references(in: "Read `Gone.swift`, `mcp/gone.py`, `edits/`, `Phone*.swift` and `~/Movies`.",
                                   topLevel: ["mcp"])
        #expect(refs == ["Gone.swift", "mcp/gone.py"])
    }
}
