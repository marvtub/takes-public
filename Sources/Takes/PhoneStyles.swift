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
