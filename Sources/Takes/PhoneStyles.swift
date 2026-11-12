import AppKit
import Foundation

// The Styles board for the phone (2026-10-08: "the styles feature is missing from ios"): every
// style with its preview, one style's guide, colours, type and parts, Keep and Trash for a new
// style, and the style one video uses. Comments on a style's parts use the library folder as the
// session id ("_library/styles/Magazine"), so the phone's review player works as in a session.

struct PhoneStyleCard: Codable, Hashable {
    var name: String
    var description: String
    var source: String?
    var isNew: Bool
    /// Absolute paths, for /media and /thumb.
    var video: String?
    var poster: String?
    /// Session ids of the videos with edits in this style, newest first.
    var usedBy: [String]
    var openComments: Int
}

struct PhoneStyles: Codable {
    var styles: [PhoneStyleCard]
    /// Projects with looks of their own (<project>/_library), A–Z.
    var projects: [String]
}

struct PhoneSwatch: Codable, Hashable {
    var name: String
    var value: String
    var usage: String
}

struct PhoneTypeSample: Codable, Hashable {
    var name: String
    var family: String
    var size: Double
    var weight: Int
}

struct PhoneStyleVersion: Codable, Hashable {
    var path: String
    var name: String
    var version: Int?
    var kind: String
    var size: Int64
    var modified: Date
    var note: String?
    var from: String?
    var openComments: Int
}

struct PhoneStyleItem: Codable, Hashable {
    var name: String
    /// Oldest first, as the Mac's v1 v2 v3 row.
    var versions: [PhoneStyleVersion]
}

struct PhoneStyleGroup: Codable, Hashable {
    var name: String
    var items: [PhoneStyleItem]
}

struct PhoneStyleDetail: Codable {
    /// The library folder inside the Takes root: the "session" id for its comments.
    var id: String
    var name: String
    var folder: String
    var readme: String?
    var readmeComments: Int
    var hasTokens: Bool
    var tokensComments: Int
    var swatches: [PhoneSwatch]
    var type: [PhoneTypeSample]
    /// Font files (otf, ttf) the phone loads, so the type samples look as on the Mac.
    var fonts: [String]
    var groups: [PhoneStyleGroup]
    var openComments: Int
}

/// The style one video uses, and the styles it can pick, for the Files tab.
struct PhoneSessionStyle: Codable {
    /// The video's own pick. Nil: its project's.
    var own: String?
    var project: String?
    var names: [String]
}

extension PhoneServer {
    /// A style folder or a project's _library, by its path inside the root. Nil for anything else.
    func library(_ id: String?) -> URL? {
        guard let id, !id.isEmpty, !id.contains(".."), id.contains(StyleLib.folder) else { return nil }
        let url = libraryRoot.appending(path: id).standardizedFileURL
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue,
              StyleLib.root(containing: url.appending(path: "x"))?.standardizedFileURL == url else { return nil }
        return url
    }

    /// Where a comment goes: a session, or a style library.
    func commentRoot(_ id: String?) -> URL? { session(id) ?? library(id) }

    func styles() async -> PhoneStyles {
        let root = libraryRoot
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let cards = StyleLib.cards(root: root).map { c in
                let dir = StyleLib.style(c.name, root: root)
                return PhoneStyleCard(name: c.name, description: c.description, source: c.source, isNew: c.isNew,
                                      video: c.video?.path, poster: c.poster?.path,
                                      usedBy: c.usedBy.map { String($0.standardizedFileURL.path.dropFirst(root.path.count + 1)) },
                                      openComments: CommentStore.read(dir).comments.filter(\.open).count)
            }
            let projects = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { p in
                    guard p.hasDirectoryPath, !p.lastPathComponent.hasPrefix("_") else { return false }
                    let items = (try? fm.contentsOfDirectory(atPath: StyleLib.project(p).path)) ?? []
                    return items.contains { $0 != "project.json" && !$0.hasPrefix(".") }
                }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return PhoneStyles(styles: cards, projects: projects)
        }.value
    }

    func style(_ dir: URL) async -> PhoneStyleDetail {
        let root = libraryRoot
        let store = await MainActor.run { () -> LibraryStore in
            let s = LibraryStore()
            s.scan(dir)
            return s
        }
        return await MainActor.run {
            let open = CommentStore.read(dir).comments.filter(\.open)
            let count = { (file: String) in open.filter { $0.file == file }.count }
            let groups = store.groups.map { g in
                PhoneStyleGroup(name: g.name, items: g.items.map { item in
                    PhoneStyleItem(name: item.name, versions: item.versions.map { a in
                        let rel = "assets/\(item.group)/\(a.name)"
                        let n = store.notes[rel]
                        return PhoneStyleVersion(path: a.url.standardizedFileURL.path, name: a.name, version: StyleLib.split(a.name).version,
                                                 kind: Self.kind(a.url), size: a.size, modified: a.modified,
                                                 note: n?.note.isEmpty == false ? n?.note : nil, from: n?.from, openComments: count(rel))
                    })
                })
            }
            let fonts = ((try? FileManager.default.contentsOfDirectory(at: dir.appending(path: "fonts"), includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)) ?? [])
                .filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
                .map(\.standardizedFileURL.path)
            let name = dir.lastPathComponent == StyleLib.folder ? "Only \(dir.deletingLastPathComponent().lastPathComponent)" : dir.lastPathComponent
            return PhoneStyleDetail(id: String(dir.path.dropFirst(root.path.count + 1)), name: name, folder: dir.path,
                                    readme: store.readme, readmeComments: count("README.md"),
                                    hasTokens: store.hasTokens, tokensComments: count("tokens.json"),
                                    swatches: store.swatches.map { PhoneSwatch(name: $0.name, value: $0.value, usage: $0.usage) },
                                    type: store.type.map { PhoneTypeSample(name: $0.name, family: $0.family, size: Double($0.size), weight: $0.weight) },
                                    fonts: fonts, groups: groups, openComments: open.count)
        }
    }

    /// {"action": "keep" | "trash", "name": "<Style>"}
    @MainActor func changeStyle(_ b: [String: String]) -> PhoneResponse {
        let root = libraryRoot
        guard let name = b["name"], StyleLib.styleNames(root: root).contains(name) else { return .error(404, "No such style") }
        let dir = StyleLib.style(name, root: root)
        switch b["action"] {
        case "keep":
            StyleLib.keep(name, root: root)
        case "trash":
            if let f = appModel?.styleFile, f.path.hasPrefix(dir.path + "/") { appModel?.styleFile = nil }
            do { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) } catch {
                return .error(500, "Could not move \(name) to the Trash: \(error.localizedDescription)")
            }
            appModel?.show(toast: "\(name) moved to the Trash")
        default:
            return .error(400, "Keep or trash?")
        }
        return .encode(["ok": true])
    }

    nonisolated static func sessionStyle(_ s: URL, meta: SessionMeta, root: URL) -> PhoneSessionStyle {
        let names = StyleLib.styleNames(root: root)
        return PhoneSessionStyle(own: meta.style.flatMap { names.contains($0) ? $0 : nil },
                                 project: StyleLib.chosen(project: s.deletingLastPathComponent(), root: root), names: names)
    }

    /// {"style": "<Style>" or "" (the project's), "project": "1" (it becomes the project's style)}
    @MainActor func setStyle(_ b: [String: String], in s: URL) -> PhoneResponse {
        let names = StyleLib.styleNames(root: libraryRoot)
        let pick = b["style"].flatMap { $0.isEmpty ? nil : $0 }
        if let pick, !names.contains(pick) { return .error(404, "No such style") }
        guard let d = sessionDoc(s) else { return .error(404, "No such session") }
        if b["project"] == "1", let pick {
            StyleLib.choose(pick, project: s.deletingLastPathComponent())
            d.meta.style = nil
        } else {
            d.meta.style = pick
        }
        d.save()
        return .encode(Self.sessionStyle(s, meta: d.meta, root: libraryRoot))
    }
}

// The Effects tab for the phone (2026-10-30): every effect with its preview and details, Use in a
// video and New effect, with the Mac's asks (EffectLib). Shipped effects live in the app, not the
// library, so their files come through /api/effects/file.

struct PhoneEffect: Codable, Hashable {
    var slug: String
    var name: String
    var description: String
    var when: String
    var kind: String
    var needs: [String]
    var seconds: Double?
    var shape: String
    var video: Bool
    var poster: Bool
    var readme: Bool
}

/// A row of the chat's @ list from the Mac: a style, an effect or a skill (ChatMentions.swift).
/// The phone sends `id` back with the message, and the Mac adds the same note as for its own @.
struct PhoneMention: Codable, Hashable {
    var kind: String
    var name: String
    var detail: String?
    var id: String
    /// A picture in the library, for /thumb.
    var image: String?
    /// An effect's slug: its poster comes from /api/effects/file.
    var effect: String?
}

extension PhoneServer {
    func effects() -> [PhoneEffect] {
        EffectLib.cards(root: libraryRoot).map { c in
            PhoneEffect(slug: c.slug, name: c.name, description: c.description, when: c.when, kind: c.kind, needs: c.needs,
                        seconds: c.seconds, shape: c.shape, video: c.video != nil, poster: c.poster != nil,
                        readme: c.dir.map { FileManager.default.fileExists(atPath: $0.appending(path: "README.md").path) } ?? false)
        }
    }

    /// ?slug=<effect>&file=preview.mp4 | preview.png | README.md
    func effectFile(_ slug: String?, _ file: String?) -> URL? {
        guard let file, ["preview.mp4", "preview.png", "README.md"].contains(file),
              let dir = EffectLib.cards(root: libraryRoot).first(where: { $0.slug == slug })?.dir else { return nil }
        let f = dir.appending(path: file)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// {"action": "use", "slug": "<effect>", "session": "<id>"}: the video's chat gets the Mac's ask.
    /// {"action": "new", "example": "…"}: the Styles chat builds a new effect.
    @MainActor func changeEffect(_ b: [String: String]) -> PhoneResponse {
        guard let app = appModel else { return .error(503, "Takes is starting") }
        switch b["action"] {
        case "use":
            guard let c = EffectLib.cards(root: libraryRoot).first(where: { $0.slug == b["slug"] }) else { return .error(404, "No such effect") }
            guard let s = session(b["session"]) else { return .error(404, "No such session") }
            let title = Store.readMeta(s)?.title ?? s.lastPathComponent
            app.chats.chat(s).send(EffectLib.useAsk(c), title: title, onStage: nil, origin: Self.origin(["from": "Styles"]))
        case "new":
            let x = (b["example"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !x.isEmpty else { return .error(400, "Paste a reel or say the move") }
            app.chats.styles.send(EffectLib.makeAsk(x, root: libraryRoot), title: "Styles", onStage: nil)
        default:
            return .error(400, "Use or new?")
        }
        return .encode(["ok": true])
    }

    /// The styles, effects and skills of the Mac's @ list, in its order. The phone lists the
    /// video's files itself.
    func mentions(_ s: URL?) -> [PhoneMention] {
        let root = libraryRoot.resolvingSymlinksInPath().path + "/"
        return Mentions.all(session: s, root: libraryRoot).filter { $0.kind != .asset }.map { m in
            let image = m.image.flatMap { $0.resolvingSymlinksInPath().path.hasPrefix(root) ? $0.path : nil }
            return PhoneMention(kind: m.kind.rawValue, name: m.name, detail: m.detail, id: m.id, image: image,
                                effect: m.kind == .effect ? m.path.lastPathComponent : nil)
        }
    }

    /// What the agent reads after a phone message, for the names picked with @: the Mac's note.
    func mentionNote(_ ids: String?, text: String, session s: URL) -> String {
        let want = Set((ids ?? "").split(separator: "\n").map(String.init))
        guard !want.isEmpty else { return "" }
        let picked = Mentions.all(session: s, root: libraryRoot).filter { want.contains($0.id) }
        return Mentions.note(Mentions.used(picked, in: text), session: s)
    }
}
