import AppKit
import SwiftUI

/// Skills for Claude Code, installed from inside Takes (2026-10-08). The chat is Claude Code, so a
/// skill in ~/.claude/skills works in every chat. Takes brings its own (video edit, storyboard,
/// image prompts) in Resources/plugin-skills, offers packs from their own GitHub repos
/// (HyperFrames), and adds others from a GitHub link or a folder.
///
/// Public since 2026-10-13, with the HyperFrames pack: The user wants both in the public Takes.
enum SkillsPlugin {
    static let plugin = TakesPlugin(
        id: "skills", title: "Skills", icon: "wand.and.stars", key: "j",
        help: "New work for the chat: skills from Takes, HyperFrames, GitHub or a folder",
        badge: { _ in AnyView(EmptyView()) }, board: nil,
        settings: { _ in
            AnyView(SkillsSettings()
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border)))
        })
}

/// A set of skills Takes offers from its own GitHub repo (2026-10-13). Takes downloads it when it
/// is switched on, so the app never carries a copy and the user gets the newest one.
struct SkillPack: Identifiable, Equatable {
    let id: String
    let title: String
    let what: String
    /// The repo, as SkillShelf.add(gitHub:) writes it into each skill's marker.
    let repo: String
    /// The folder in the repo that holds the skills.
    let path: String
    /// A tool the skills run, said under the switch when this Mac does not have it.
    var needs: (tool: String, label: String)? = nil

    var link: String { path.isEmpty ? repo : "\(repo)/tree/main/\(path)" }

    /// HyperFrames (HeyGen, Apache-2.0): motion graphics, captions and title cards made in HTML and
    /// rendered to video. The edit skill uses it for the picture layers over a cut.
    static let hyperframes = SkillPack(
        id: "hyperframes", title: "HyperFrames",
        what: "Motion graphics, title cards and captions, made in HTML. By HeyGen.",
        repo: "https://github.com/heygen-com/hyperframes", path: "skills",
        needs: ("node", "Needs Node.js (nodejs.org) to render"))
    static let all: [SkillPack] = [hyperframes]

    static func == (a: SkillPack, b: SkillPack) -> Bool { a.id == b.id }
}

/// One skill folder: a SKILL.md with a name and a description at the top.
struct SkillInfo: Identifiable, Equatable {
    let name: String
    let description: String
    let folder: URL
    var id: String { folder.path }

    /// "takes-video-edit" reads "Video edit".
    var title: String {
        var t = name.hasPrefix("takes-") ? String(name.dropFirst(6)) : name
        t = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

enum SkillShelf {
    /// Where Claude Code finds the skills of this Mac's user.
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills") }
    /// The skills this build brings (build.sh copies them in).
    static var catalog: URL { Bundle.main.bundleURL.appending(path: "Contents/Resources/plugin-skills") }
    /// Inside each skill Takes installed: where it came from. Takes removes and updates only these.
    static let marker = ".takes-skill"
    static let fromTakes = "takes"
    /// The other agents' skill folder (Codex, pi, opencode, Gemini CLI): AgentSetup copies Takes'
    /// own skills there too, so switching one off removes it there as well.
    static var agentsHome: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agents/skills") }
    /// Takes' own skills and packs the user switched off. AgentSetup leaves these out at launch.
    static let offKey = "skillsOff"
    static var off: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: offKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: offKey) }
    }

    enum Status: Equatable {
        case missing, installed, changed
        /// The user has this skill already, under its name or without "takes-" (video-edit for
        /// takes-video-edit), in ~/.claude/skills or the chat's folder. Takes leaves it alone.
        case yours(where: String)
    }

    enum Problem: LocalizedError {
        case notASkill, taken(String), clone(String)
        var errorDescription: String? {
            switch self {
            case .notASkill: return "No skill there: a skill is a folder with a SKILL.md."
            case .taken(let n): return "You already have a skill called \(n). Takes leaves it alone."
            case .clone(let why): return why
            }
        }
    }

    /// The name and description from a SKILL.md's front matter. Nil: no SKILL.md.
    static func read(_ folder: URL) -> SkillInfo? {
        guard let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else { return nil }
        var name = "", desc = ""
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                let line = lines[i]
                if let v = value(line, "name") { name = v }
                if var v = value(line, "description") {
                    // A folded description (">" or "|") goes on in the indented lines below.
                    if v == ">" || v == "|" || v == ">-" || v == "|-" { v = "" }
                    while i + 1 < lines.count, lines[i + 1].hasPrefix(" ") || lines[i + 1].hasPrefix("\t") {
                        i += 1
                        v += (v.isEmpty ? "" : " ") + lines[i].trimmingCharacters(in: .whitespaces)
                    }
                    desc = v
                }
                i += 1
            }
        }
        return SkillInfo(name: clean(name) ?? clean(folder.lastPathComponent) ?? "skill", description: desc, folder: folder)
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
        return v
    }

    /// A safe folder name: lowercase letters, digits, - and _.
    static func clean(_ s: String) -> String? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return t.isEmpty || t.hasPrefix("-") ? nil : String(t.prefix(64))
    }

    /// The skills in a folder of skills, by name.
    static func list(in dir: URL) -> [SkillInfo] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap(read).sorted { $0.name < $1.name }
    }

    /// Where an installed skill came from: "takes", a GitHub link, a folder. Nil: not from Takes.
    static func source(of folder: URL) -> String? {
        (try? String(contentsOf: folder.appending(path: marker), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "takes-video-edit" also goes by "video-edit".
    static func names(of skill: SkillInfo) -> [String] {
        skill.name.hasPrefix("takes-") ? [skill.name, String(skill.name.dropFirst(6))] : [skill.name]
    }

    static func status(of skill: SkillInfo, in home: URL = home, project: URL? = nil) -> Status {
        let fm = FileManager.default
        let dest = home.appending(path: skill.name)
        if fm.fileExists(atPath: dest.appending(path: "SKILL.md").path), source(of: dest) != nil {
            return same(skill.folder, dest) ? .installed : .changed
        }
        for (dir, label) in [(home, "~/.claude/skills")] + (project.map { [($0, $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)] } ?? []) {
            for n in names(of: skill) where fm.fileExists(atPath: dir.appending(path: "\(n)/SKILL.md").path) {
                return .yours(where: label)
            }
        }
        return .missing
    }

    /// The same files with the same bytes, the marker aside.
    static func same(_ a: URL, _ b: URL) -> Bool {
        let fa = files(a), fb = files(b)
        guard fa.keys.sorted() == fb.keys.sorted() else { return false }
        return fa.allSatisfy { k, v in (try? Data(contentsOf: v)) == fb[k].flatMap { try? Data(contentsOf: $0) } }
    }

    private static func files(_ dir: URL) -> [String: URL] {
        var out: [String: URL] = [:]
        let base = dir.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = String(f.standardizedFileURL.path.dropFirst(base.count + 1))
            if rel != marker && !rel.hasSuffix(".DS_Store") { out[rel] = f }
        }
        return out
    }

    /// Copies a skill folder into `home` under its name, over an older copy Takes installed.
    @discardableResult
    static func install(_ skill: SkillInfo, source: String, to home: URL = home) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let dest = home.appending(path: skill.name)
        if fm.fileExists(atPath: dest.path), self.source(of: dest) == nil { throw Problem.taken(skill.name) }
        let tmp = home.appending(path: ".\(skill.name)-\(UUID().uuidString)")
        try fm.copyItem(at: skill.folder, to: tmp)
        try? fm.removeItem(at: tmp.appending(path: ".git"))
        try source.write(to: tmp.appending(path: marker), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return skill.name
    }

    /// A pack is on when Takes installed any of its skills, and the user's own when they put its
    /// main skill (named like the pack) there themselves.
    static func status(of pack: SkillPack, in home: URL = home) -> Status {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        if items.contains(where: { source(of: $0) == pack.repo }) { return .installed }
        if fm.fileExists(atPath: home.appending(path: "\(pack.id)/SKILL.md").path) { return .yours(where: "~/.claude/skills") }
        return .missing
    }

    /// Downloads the pack and installs its skills in `home`, then copies them to `also` (the other
    /// agents' folder). Skills the user has under the same name stay theirs.
    @discardableResult
    static func install(_ pack: SkillPack, to home: URL = home, also: [URL] = []) async throws -> [String] {
        let names = try await add(gitHub: pack.link, to: home)
        for dir in also {
            for n in names { if let s = read(home.appending(path: n)) { _ = try? install(s, source: pack.repo, to: dir) } }
        }
        return names
    }

    /// Every skill of the pack that Takes installed goes to the Trash, in each folder.
    static func remove(_ pack: SkillPack, from homes: [URL] = [home]) throws {
        for home in homes {
            let items = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
            for f in items where source(of: f) == pack.repo { try FileManager.default.trashItem(at: f, resultingItemURL: nil) }
        }
    }

    /// Whether a command-line tool is on the PATH the chat gets. Off the main thread: the first
    /// call starts a login shell, and waiting for it inside a view's body aborts SwiftUI.
    nonisolated static func has(_ tool: String) -> Bool {
        let dirs = (ClaudeChat.shellPath + ":/opt/homebrew/bin:/usr/local/bin").split(separator: ":")
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }

    /// To the Trash, so it can come back. Only a skill Takes installed.
    static func remove(_ name: String, from home: URL = home) throws {
        let dest = home.appending(path: name)
        guard source(of: dest) != nil else { throw Problem.taken(name) }
        try FileManager.default.trashItem(at: dest, resultingItemURL: nil)
    }

    /// The skill folders in a download: the folder itself, or folders with a SKILL.md up to three
    /// levels down (a repo of skills keeps them in skills/<name>).
    static func found(in root: URL) -> [SkillInfo] {
        if let s = read(root) { return [s] }
        var out: [SkillInfo] = []
        func look(_ dir: URL, _ depth: Int) {
            guard depth <= 3, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for d in items.sorted(by: { $0.path < $1.path }) where !d.lastPathComponent.hasPrefix(".") && d.hasDirectoryPath {
                if let s = read(d) { out.append(s) } else { look(d, depth + 1) }
            }
        }
        look(root, 1)
        return out
    }

    /// "owner/repo", github.com/owner/repo(.git) or a link to a folder in it (/tree/<branch>/<path>).
    static func gitHub(_ text: String) -> (repo: URL, branch: String?, path: String)? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        if t.hasPrefix("github.com/") { t = String(t.dropFirst(11)) } else if t.contains(".") && !t.contains("/") { return nil }
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].contains(".") || parts.count > 2 else { return nil }
        let owner = parts[0], repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        guard [owner, repo].allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }),
              let url = URL(string: "https://github.com/\(owner)/\(repo).git") else { return nil }
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            var path = parts.dropFirst(4).joined(separator: "/")
            if path.hasSuffix("SKILL.md") { path = String(path.dropLast(8)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            return (url, parts[3], path)
        }
        return (url, nil, "")
    }

    /// Downloads a GitHub repo (git, no account needed for a public one) and installs every skill
    /// in it, or in the linked folder. Returns their names.
    static func add(gitHub text: String, to home: URL = home) async throws -> [String] {
        guard let g = gitHub(text) else { throw Problem.clone("That is not a GitHub link. Paste one like github.com/owner/repo.") }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "takes-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // No LFS: a repo that keeps media in LFS (HyperFrames) fails to check out on a Mac whose git
        // runs the LFS hook without git-lfs on its PATH, and skills need none of it (2026-10-13).
        let noLFS = ["-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=", "-c", "filter.lfs.required=false"]
        var args = noLFS + ["clone", "--depth", "1", "--quiet"]
        // A folder in the repo: fetch only that folder (HyperFrames' skills are 18 MB of 80+).
        if !g.path.isEmpty { args += ["--filter=blob:none", "--sparse"] }
        if let b = g.branch { args += ["--branch", b] }
        args += [g.repo.absoluteString, tmp.path]
        let sparse = noLFS + ["-C", tmp.path, "sparse-checkout", "set", g.path]
        let (ok, out) = await Task.detached {
            let r = git(args)
            return r.0 && !g.path.isEmpty ? git(sparse) : r
        }.value
        guard ok else {
            throw Problem.clone(out.contains("Repository not found") || out.contains("could not read Username")
                ? "Git could not find that repo. Is it public?" : "Git could not download it: \(out.prefix(160))")
        }
        let root = g.path.isEmpty ? tmp : tmp.appending(path: g.path)
        return try install(found(in: root), source: "https://github.com/" + g.repo.path.dropFirst().replacingOccurrences(of: ".git", with: ""), to: home)
    }

    /// Installs every skill in a folder on this Mac.
    static func add(folder: URL, to home: URL = home) throws -> [String] {
        try install(found(in: folder), source: folder.path, to: home)
    }

    private static func install(_ skills: [SkillInfo], source: String, to home: URL) throws -> [String] {
        guard !skills.isEmpty else { throw Problem.notASkill }
        var done: [String] = [], first: Error?
        for s in skills {
            do { done.append(try install(s, source: source, to: home)) } catch { first = first ?? error }
        }
        if done.isEmpty, let first { throw first }
        return done
    }

    nonisolated private static func git(_ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "git is missing") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// The Skills plugin's part of the Plugins board: one short list (Takes' skills, the packs and those
/// added here, each with a switch), an Add button, and the user's own skills folded into one line.
struct SkillsSettings: View {
    /// Other folders for the snapshot test.
    var catalogDir = SkillShelf.catalog
    var homeDir = SkillShelf.home
    var projectDir = ClaudeChat.folder.appending(path: ".claude/skills")
    var agentsDir = SkillShelf.agentsHome
    var packs = SkillPack.all
    @State private var catalog: [SkillInfo] = []
    @State private var added: [SkillInfo] = []
    @State private var own: [SkillInfo] = []
    @State private var adding = false
    @State private var link = ""
    @State private var busy = false
    @State private var note: (text: String, ok: Bool)?
    @State private var showOwn = false
    /// Kept in state: a switch flip changes only files on disk, so the lists above stay equal
    /// and SwiftUI would not draw the row again.
    @State private var statuses: [String: SkillShelf.Status] = [:]
    @State private var packStatus: [String: SkillShelf.Status] = [:]
    /// The pack that is downloading.
    @State private var fetching: String?
    /// Packs whose tool (Node.js) this Mac lacks, found in the background.
    @State private var lacking: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(packs.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rule().opacity(0.5) }
                row(p)
            }
            ForEach(Array((catalog + added).enumerated()), id: \.element.id) { i, s in
                if i > 0 || !packs.isEmpty { Rule().opacity(0.5) }
                row(s)
            }
            Rule().opacity(0.5)
            footer.padding(.vertical, 10)
        }
        .task {
            reload()
            let needs = packs.compactMap { p in p.needs.map { (p.id, $0.tool) } }
            lacking = await Task.detached { Set(needs.filter { !SkillShelf.has($0.1) }.map(\.0)) }.value
        }
    }

    private func reload() {
        catalog = SkillShelf.list(in: catalogDir)
        let home = SkillShelf.list(in: homeDir).filter { s in !catalog.contains { $0.name == s.name } }
        // A pack shows as one row, not one per skill.
        let packRepos = Set(packs.map(\.repo))
        added = home.filter { s in SkillShelf.source(of: s.folder).map { !packRepos.contains($0) } ?? false }
        // The user's own, minus those that stand in for one of Takes' (video-edit for takes-video-edit).
        let standIns = Set(catalog.flatMap(SkillShelf.names))
        own = (home.filter { SkillShelf.source(of: $0.folder) == nil } + SkillShelf.list(in: projectDir))
            .filter { !standIns.contains($0.name) }
        statuses = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, SkillShelf.status(of: $0, in: homeDir, project: projectDir)) })
        packStatus = Dictionary(uniqueKeysWithValues: packs.map { ($0.id, SkillShelf.status(of: $0, in: homeDir)) })
    }

    private func row(_ p: SkillPack) -> some View {
        let status = packStatus[p.id] ?? .missing
        let missingTool = lacking.contains(p.id) ? p.needs?.label : nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                    Text("Pack").font(Theme.sans(10, .medium)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.border.opacity(0.6)))
                }
                Group {
                    if case .yours(let place) = status {
                        Text("On: your copy in \(place)")
                    } else if fetching == p.id {
                        Text("Downloading from GitHub…")
                    } else if status == .installed, let missingTool {
                        Text(missingTool).foregroundStyle(Theme.accent)
                    } else {
                        Text(p.what)
                    }
                }
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .help(p.what + "\nFrom " + p.repo.replacingOccurrences(of: "https://", with: ""))
            Spacer(minLength: 10)
            if fetching == p.id {
                ProgressView().controlSize(.small)
            } else if case .yours = status {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                    .help("You have this pack already. Takes leaves your copy alone.")
            } else {
                if status == .installed {
                    Button("Update") { fetch(p) }
                        .buttonStyle(.link).font(Theme.sans(12)).help("Download the newest version from GitHub")
                }
                RuleSwitch(on: status == .installed) {
                    if status == .installed {
                        act { try SkillShelf.remove(p, from: [homeDir, agentsDir]); SkillShelf.off.insert(p.id) }
                    } else { fetch(p) }
                }
                .help(status == .installed ? "On: every chat can use it. Off moves it to the Trash." : "Download it from GitHub for every chat")
            }
        }
        .padding(.vertical, 9)
    }

    private func fetch(_ p: SkillPack) {
        fetching = p.id
        note = nil
        Task {
            do {
                let names = try await SkillShelf.install(p, to: homeDir, also: [agentsDir])
                SkillShelf.off.remove(p.id)
                note = ("\(p.title): \(names.count) skills. New chats can use them.", true)
            } catch { note = (error.localizedDescription, false) }
            fetching = nil
            reload()
        }
    }

    private func row(_ s: SkillInfo) -> some View {
        let status = catalog.contains(s) ? statuses[s.name] ?? .missing : .installed
        let on = status != .missing
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                Group {
                    if case .yours(let place) = status {
                        Text("On: your copy in \(place)")
                    } else if !catalog.contains(s), let src = SkillShelf.source(of: s.folder) {
                        Text("From " + src.replacingOccurrences(of: "https://", with: ""))
                    } else {
                        Text(Self.short(s.description))
                    }
                }
                .font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .help(s.description)
            Spacer(minLength: 10)
            if status == .changed {
                Button("Update") { act { _ = try SkillShelf.install(s, source: SkillShelf.fromTakes, to: homeDir) } }
                    .buttonStyle(.link).font(Theme.sans(12)).help("Takes has a newer copy of this skill")
            }
            if case .yours = status {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                    .help("You have this skill already. Takes leaves your copy alone.")
            } else {
                RuleSwitch(on: on) {
                    let own = catalog.contains(s)
                    act {
                        if !on {
                            _ = try SkillShelf.install(s, source: SkillShelf.fromTakes, to: homeDir)
                            if own { _ = try? SkillShelf.install(s, source: SkillShelf.fromTakes, to: agentsDir); SkillShelf.off.remove(s.name) }
                        } else {
                            try SkillShelf.remove(s.name, from: homeDir)
                            // Takes' own: also gone for the other agents, and not back at the next launch.
                            if own { try? SkillShelf.remove(s.name, from: agentsDir); SkillShelf.off.insert(s.name) }
                        }
                    }
                }
                .help(on ? "On: every chat can use it. Off moves it to the Trash." : "Install it for every chat")
            }
        }
        .padding(.vertical, 9)
    }

    /// The first sentence: what the skill does, without its "Use when…" list.
    static func short(_ d: String) -> String {
        let cut = d.range(of: ". Use ")?.lowerBound ?? d.range(of: ". ")?.lowerBound ?? d.endIndex
        return String(d[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if adding {
                HStack(spacing: 8) {
                    TextField("GitHub link, like github.com/owner/repo", text: $link)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(12)).onSubmit(addLink)
                    Button("Add", action: addLink).disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Folder…", action: addFolder).disabled(busy).help("Add a skill folder from this Mac")
                    Button { adding = false; note = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .foregroundStyle(Theme.faint).help("Close")
                }
            }
            if busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…").font(Theme.sans(11.5)).foregroundStyle(Theme.muted) }
            } else if let note {
                Text(note.text).font(Theme.sans(11.5)).foregroundStyle(note.ok ? Theme.muted : Theme.accent)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if !adding {
                    Button { withAnimation(Theme.motion) { adding = true } } label: {
                        Label("Add a skill", systemImage: "plus").font(Theme.sans(12))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accentInk)
                    .help("From a GitHub link or a folder on this Mac")
                }
                Spacer()
                if !own.isEmpty {
                    Button { withAnimation(Theme.motion) { showOwn.toggle() } } label: {
                        Text(showOwn ? "Hide your skills" : "\(own.count) skills of your own")
                            .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Skills you put on this Mac yourself. Takes leaves them alone.")
                }
            }
            if showOwn {
                Text(own.map(\.name).joined(separator: " · "))
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func act(_ work: () throws -> Void) {
        do { try work(); note = nil } catch { note = (error.localizedDescription, false) }
        reload()
    }

    private func addLink() {
        let text = link
        busy = true
        note = nil
        Task {
            do {
                let names = try await SkillShelf.add(gitHub: text, to: homeDir)
                note = ("Added \(names.joined(separator: ", ")). New chats can use \(names.count == 1 ? "it" : "them").", true)
                link = ""
                adding = false
            } catch { note = (error.localizedDescription, false) }
            busy = false
            reload()
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Skill"
        panel.message = "Choose a skill folder (with a SKILL.md), or a folder of skills."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let names = try SkillShelf.add(folder: url, to: homeDir)
            note = ("Added \(names.joined(separator: ", ")). New chats can use \(names.count == 1 ? "it" : "them").", true)
            adding = false
        } catch { note = (error.localizedDescription, false) }
        reload()
    }
}
