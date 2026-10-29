import Foundation
import SwiftUI
import Testing
@testable import Takes

/// The Skills plugin: reading, installing, updating and removing skills.
struct SkillsTests {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Where the shipped skills are: scripts/public/skills here, skills/ in the public copy.
    static func shipped(_ repo: URL) -> URL {
        let here = repo.appending(path: "scripts/public/skills")
        return FileManager.default.fileExists(atPath: here.path) ? here : repo.appending(path: "skills")
    }

    private func temp() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func skill(_ dir: URL, _ name: String, _ body: String = "Do the thing.") throws -> URL {
        let d = dir.appending(path: name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \"Use when \(name).\"\n---\n\n\(body)\n".write(to: d.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return d
    }

    @Test func readsTheFrontMatter() throws {
        let d = temp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appending(path: "Odd Folder")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try "---\nname: takes-video-edit\ndescription: >\n  Edit a video\n  in Takes.\nother: x\n---\nBody".write(to: f.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let s = try #require(SkillShelf.read(f))
        #expect(s.name == "takes-video-edit")
        #expect(s.description == "Edit a video in Takes.")
        #expect(s.title == "Video edit")
        #expect(SkillShelf.read(d) == nil)
        #expect(SkillShelf.clean("../My Skill!") == "my-skill")
    }

    @Test func installsUpdatesAndRemoves() throws {
        let src = temp(), home = temp()
        defer { for d in [src, home] { try? FileManager.default.removeItem(at: d) } }
        let s = try #require(SkillShelf.read(try skill(src, "image-prompt")))
        #expect(SkillShelf.status(of: s, in: home) == .missing)
        try SkillShelf.install(s, source: SkillShelf.fromTakes, to: home)
        #expect(SkillShelf.status(of: s, in: home) == .installed)
        #expect(SkillShelf.source(of: home.appending(path: "image-prompt")) == "takes")
        // A newer copy in Takes: Update.
        try "changed".write(to: s.folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let newer = SkillInfo(name: s.name, description: "", folder: s.folder)
        #expect(SkillShelf.status(of: newer, in: home) == .changed)
        try SkillShelf.install(newer, source: SkillShelf.fromTakes, to: home)
        #expect(SkillShelf.status(of: newer, in: home) == .installed)
        try SkillShelf.remove("image-prompt", from: home)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "image-prompt").path))
    }

    @Test func leavesTheUsersOwnSkillAlone() throws {
        let src = temp(), home = temp()
        defer { for d in [src, home] { try? FileManager.default.removeItem(at: d) } }
        _ = try skill(home, "video-edit", "Mine.")
        let s = try #require(SkillShelf.read(try skill(src, "video-edit")))
        #expect(SkillShelf.status(of: s, in: home) == .yours(where: "~/.claude/skills"))
        #expect(throws: SkillShelf.Problem.self) { try SkillShelf.install(s, source: "takes", to: home) }
        #expect(throws: SkillShelf.Problem.self) { try SkillShelf.remove("video-edit", from: home) }
        #expect(try String(contentsOf: home.appending(path: "video-edit/SKILL.md"), encoding: .utf8).contains("Mine."))
    }

    /// The user's own video-edit in their notes repo counts as Takes' takes-video-edit.
    @Test func aShortNameCountsAsTheSame() throws {
        let src = temp(), home = temp(), life = temp()
        defer { for d in [src, home, life] { try? FileManager.default.removeItem(at: d) } }
        let project = life.appending(path: "notes/.claude/skills")
        _ = try skill(project, "video-edit")
        let s = try #require(SkillShelf.read(try skill(src, "takes-video-edit")))
        #expect(SkillShelf.status(of: s, in: home, project: project) == .yours(where: "notes"))
        #expect(SkillShelf.status(of: s, in: home) == .missing)
        #expect(SkillsSettings.short("Edit a video in Takes. Use when the user asks.") == "Edit a video in Takes")
    }

    @Test func addsEverySkillInARepoFolder() throws {
        let src = temp(), home = temp()
        defer { for d in [src, home] { try? FileManager.default.removeItem(at: d) } }
        _ = try skill(src.appending(path: "skills"), "one")
        _ = try skill(src.appending(path: "skills"), "two")
        try FileManager.default.createDirectory(at: src.appending(path: ".git"), withIntermediateDirectories: true)
        let names = try SkillShelf.add(folder: src, to: home)
        #expect(names == ["one", "two"])
        #expect(SkillShelf.source(of: home.appending(path: "one")) == src.path)
        #expect(throws: SkillShelf.Problem.self) { try SkillShelf.add(folder: home.appending(path: "nothing"), to: home) }
    }

    /// A pack is one switch: on when Takes installed any of its skills, the user's own when they
    /// put its main skill there, and off takes only what Takes installed.
    @Test func aPackIsOneSwitch() throws {
        let home = temp(); defer { try? FileManager.default.removeItem(at: home) }
        let pack = SkillPack.hyperframes
        #expect(SkillShelf.status(of: pack, in: home) == .missing)
        for n in ["hyperframes", "hyperframes-core"] {
            let s = try #require(SkillShelf.read(try skill(temp(), n)))
            try SkillShelf.install(s, source: pack.repo, to: home)
        }
        _ = try skill(home, "grill-me")
        #expect(SkillShelf.status(of: pack, in: home) == .installed)
        try SkillShelf.remove(pack, from: [home])
        #expect(SkillShelf.status(of: pack, in: home) == .missing)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "grill-me/SKILL.md").path))
        _ = try skill(home, "hyperframes")
        #expect(SkillShelf.status(of: pack, in: home) == .yours(where: "~/.claude/skills"))
        #expect(throws: Never.self) { try SkillShelf.remove(pack, from: [home]) }
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "hyperframes/SKILL.md").path))
    }

    @Test func readsGitHubLinks() throws {
        let a = try #require(SkillShelf.gitHub("github.com/anthropics/skills"))
        #expect(a.repo.absoluteString == "https://github.com/anthropics/skills.git" && a.branch == nil && a.path.isEmpty)
        let b = try #require(SkillShelf.gitHub("https://github.com/anthropics/skills/tree/main/skills/pdf"))
        #expect(b.branch == "main" && b.path == "skills/pdf")
        let c = try #require(SkillShelf.gitHub("https://github.com/o/r/blob/dev/x/SKILL.md"))
        #expect(c.branch == "dev" && c.path == "x")
        #expect(SkillShelf.gitHub("owner/repo.git")?.repo.absoluteString == "https://github.com/owner/repo.git")
        #expect(SkillShelf.gitHub("example.com") == nil)
        #expect(SkillShelf.gitHub("hello") == nil)
        // The HyperFrames pack's link reads too.
        do {
            let g = try #require(SkillShelf.gitHub(SkillPack.hyperframes.link))
            #expect(g.repo.absoluteString == "https://github.com/heygen-com/hyperframes.git")
            #expect(g.branch == "main" && g.path == "skills")
        }
    }

    /// The skills build.sh puts in the app, each with a name and a description, and the image
    /// prompt finder is there. All public since 2026-10-13.
    @Test func theCatalogIsWhole() throws {
        let names = SkillShelf.list(in: Self.shipped(repo))
        #expect(Set(names.map(\.name)).isSuperset(of: ["takes-video-edit", "takes-storyboard", "takes-image-prompt"]))
        for s in names {
            #expect(!s.description.isEmpty, "\(s.name) needs a description")
            #expect(s.name == s.folder.lastPathComponent, "\(s.name) sits in a folder of another name")
        }
        #expect(FileManager.default.fileExists(atPath: Self.shipped(repo).appending(path: "takes-image-prompt/scripts/find_prompts.py").path))
    }
}

extension Snap {
    /// The Plugins board with the Skills plugin's list: one installed, one to install, one of the user's own.
    @Test(.enabled(if: snapDir != nil)) func pluginsPage() throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cat = fm.temporaryDirectory.appending(path: "snapcat-\(UUID().uuidString)"), home = fm.temporaryDirectory.appending(path: "snaphome-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: cat); try? fm.removeItem(at: home) }
        try fm.createDirectory(at: cat, withIntermediateDirectories: true)
        for d in ["takes-video-edit", "takes-storyboard", "takes-image-prompt"] {
            try fm.copyItem(at: SkillsTests.shipped(repo).appending(path: d), to: cat.appending(path: d))
        }
        let life = home.appending(path: "x/notes/.claude/skills")
        for n in ["video-edit", "storyboard", "journal"] {
            try fm.createDirectory(at: life.appending(path: n), withIntermediateDirectories: true)
            try "---\nname: \(n)\ndescription: Mine.\n---\n".write(to: life.appending(path: "\(n)/SKILL.md"), atomically: true, encoding: .utf8)
        }
        // HyperFrames on, as the first launch leaves it.
        let hf = home.appending(path: "hyperframes")
        try fm.createDirectory(at: hf, withIntermediateDirectories: true)
        try "---\nname: hyperframes\ndescription: Video from HTML.\n---\n".write(to: hf.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try SkillPack.hyperframes.repo.write(to: hf.appending(path: SkillShelf.marker), atomically: true, encoding: .utf8)
        let own = home.appending(path: "grill-me")
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        try "---\nname: grill-me\ndescription: Ask hard questions about a plan until it holds.\n---\n".write(to: own.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let view = ScrollView {
            SkillsSettings(catalogDir: cat, homeDir: home, projectDir: life).padding(20)
        }.background(Theme.paper)
        shoot("plugins-skills", view, size: CGSize(width: 580, height: 520))
        shoot("plugins-skills-dark", view, size: CGSize(width: 580, height: 520), dark: true)
        shoot("plugins-page", PluginsBoard().background(Theme.canvas).environment(AppModel()), size: CGSize(width: 940, height: 640))
    }
}

/// Downloads a real public repo. Off by default: TAKES_NET=1 swift test --filter SkillsNet
struct SkillsNet {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_NET"] != nil)) func addsFromGitHub() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "skillsnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let names = try await SkillShelf.add(gitHub: "https://github.com/anthropics/skills/tree/main/skills/pdf", to: home)
        #expect(names == ["pdf"])
        #expect(SkillShelf.source(of: home.appending(path: "pdf")) == "https://github.com/anthropics/skills")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "pdf/.git").path))
        await #expect(throws: SkillShelf.Problem.self) { try await SkillShelf.add(gitHub: "github.com/marvtub/no-such-repo-xyz", to: home) }
    }

    /// The real HyperFrames repo still keeps its skills where the pack looks.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_NET"] != nil)) func downloadsHyperFrames() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "skillsnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let names = try await SkillShelf.install(SkillPack.hyperframes, to: home)
        #expect(names.contains("hyperframes") && names.contains("hyperframes-core"))
        #expect(SkillShelf.status(of: SkillPack.hyperframes, in: home) == .installed)
    }
}
