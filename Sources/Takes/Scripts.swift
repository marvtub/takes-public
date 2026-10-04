import Foundation

// Script drafts, variants and history, per session:
//
//   script.md                       the main script
//   variants/<slug>.md              alternative scripts (front matter: name, author, note, created)
//   history/<stamp>-<draft>.md      snapshots (front matter: author, note, created, draft)
//
// "draft" is "main" or a variant slug. The MCP server writes the same files.

enum FrontMatter {
    static func parse(_ raw: String) -> ([String: String], String) {
        guard raw.hasPrefix("---\n"),
              let end = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex)
        else { return ([:], raw) }
        var fields: [String: String] = [:]
        for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let i = line.firstIndex(of: ":") else { continue }
            fields[line[..<i].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return (fields, String(raw[end.upperBound...]))
    }

    static func render(_ fields: [(String, String)], _ body: String) -> String {
        "---\n" + fields.map { "\($0.0): \($0.1.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            + "\n---\n" + body
    }
}

struct Variant: Identifiable, Equatable {
    let slug: String
    var name: String
    var author: String
    var note: String
    var created: String
    var text: String
    var id: String { slug }
}

struct ScriptVersion: Identifiable, Hashable {
    let url: URL
    let created: Date
    let author: String
    let note: String
    let draft: String
    var id: URL { url }

    func text() -> String {
        FrontMatter.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "").1
    }
}

extension SessionDoc {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoNoFraction = ISO8601DateFormatter()
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    var variantsDir: URL { url.appending(path: "variants") }
    var historyDir: URL { url.appending(path: "history") }

    // MARK: Active draft (what the teleprompter shows)

    var activeText: String {
        get {
            activeDraft == "main" ? script : (variants.first { $0.slug == activeDraft }?.text ?? "")
        }
        set {
            if activeDraft == "main" {
                script = newValue
            } else if let i = variants.firstIndex(where: { $0.slug == activeDraft }), variants[i].text != newValue {
                variants[i].text = newValue
                lastEdit = Date()
                dirtyDrafts.insert(activeDraft)
                scheduleVariantSave(activeDraft)
            }
        }
    }

    func draftName(_ draft: String) -> String {
        draft == "main" ? "Main" : (variants.first { $0.slug == draft }?.name ?? Self.titleFromFolder(draft))
    }

    // MARK: Variants

    func readVariants() -> [Variant] {
        let files = (try? FileManager.default.contentsOfDirectory(at: variantsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { f -> Variant? in
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
            let (m, body) = FrontMatter.parse(raw)
            let slug = f.deletingPathExtension().lastPathComponent
            return Variant(slug: slug, name: m["name"] ?? Self.titleFromFolder(slug), author: m["author"] ?? "",
                           note: m["note"] ?? "", created: m["created"] ?? "", text: body)
        }
        .sorted { ($0.created, $0.slug) < ($1.created, $1.slug) }
    }

    func reloadVariantsFromDisk() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: variantsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var stamp: [String: Date] = [:]
        for f in files where f.pathExtension == "md" {
            stamp[f.lastPathComponent] = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        if stamp != variantsStamp {
            variantsStamp = stamp
            var fresh = readVariants()
            // Never clobber the variant you are typing in.
            if activeDraft != "main", Date().timeIntervalSince(lastEdit) < 5,
               let local = variants.first(where: { $0.slug == activeDraft }),
               let i = fresh.firstIndex(where: { $0.slug == activeDraft }) {
                fresh[i].text = local.text
            }
            if fresh != variants { variants = fresh }
            if activeDraft != "main" && !variants.contains(where: { $0.slug == activeDraft }) { activeDraft = "main" }
        }
        let hs = Store.modified(historyDir)
        if hs != historyStamp {
            historyStamp = hs
            lastSnapshotText.removeAll()  // someone else may have written history
            let count = ((try? fm.contentsOfDirectory(atPath: historyDir.path)) ?? []).filter { $0.hasSuffix(".md") }.count
            if count != historyCount { historyCount = count }
        }
    }

    func writeVariant(_ v: Variant) {
        try? FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        let raw = FrontMatter.render([("name", v.name), ("author", v.author), ("note", v.note), ("created", v.created)], v.text)
        try? raw.write(to: variantsDir.appending(path: "\(v.slug).md"), atomically: true, encoding: .utf8)
    }

    private func scheduleVariantSave(_ slug: String) {
        variantSaveTask?.cancel()
        variantSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let v = self.variants.first(where: { $0.slug == slug }) else { return }
            self.writeVariant(v)
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.autoSnapshotIfDue(slug)
        }
    }

    func renameVariant(_ slug: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = variants.firstIndex(where: { $0.slug == slug }) else { return }
        variants[i].name = clean
        writeVariant(variants[i])
    }

    /// One favorite per session. Pass the current favorite again to clear it.
    func toggleFavorite(_ draft: String) {
        meta.favorite = meta.favorite == draft ? nil : draft
        save()
    }

    @discardableResult
    func newVariant(name: String, text: String, author: String = "user", note: String = "") -> String {
        var slug = Library.slug(name).isEmpty ? "variant" : Library.slug(name)
        var n = 2
        let base = slug
        while variants.contains(where: { $0.slug == slug })
                || FileManager.default.fileExists(atPath: variantsDir.appending(path: "\(slug).md").path) {
            slug = "\(base)-\(n)"; n += 1
        }
        let v = Variant(slug: slug, name: name, author: author, note: note,
                        created: Self.iso.string(from: Date()), text: text)
        writeVariant(v)
        variants.append(v)
        activeDraft = slug
        return slug
    }

    func deleteVariant(_ slug: String) {
        snapshot(draft: slug, note: "Before deleting the variant")
        try? FileManager.default.trashItem(at: variantsDir.appending(path: "\(slug).md"), resultingItemURL: nil)
        variants.removeAll { $0.slug == slug }
        if activeDraft == slug { activeDraft = "main" }
        if meta.favorite == slug { meta.favorite = nil; save() }
    }

    /// The variant becomes the main script. The old main stays in history.
    func promote(_ slug: String) {
        guard let v = variants.first(where: { $0.slug == slug }) else { return }
        snapshot(draft: "main", note: "Before using “\(v.name)” as main")
        script = v.text
        flushScript()
        snapshot(draft: "main", author: v.author.isEmpty ? "user" : v.author, note: "Used “\(v.name)” as main")
        try? FileManager.default.trashItem(at: variantsDir.appending(path: "\(slug).md"), resultingItemURL: nil)
        variants.removeAll { $0.slug == slug }
        activeDraft = "main"
        if meta.favorite == slug { meta.favorite = "main"; save() }
    }

    // MARK: History

    func versions() -> [ScriptVersion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { f -> ScriptVersion? in
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
            let m = FrontMatter.parse(raw).0
            let created = m["created"].flatMap { Self.iso.date(from: $0) ?? Self.isoNoFraction.date(from: $0) }
            return ScriptVersion(url: f, created: created ?? .distantPast,
                                 author: m["author"] ?? "", note: m["note"] ?? "", draft: m["draft"] ?? "main")
        }
        .sorted { $0.created > $1.created }
    }

    /// Saves the draft's current text into history, unless it matches the latest snapshot of that draft.
    @discardableResult
    func snapshot(draft: String = "main", author: String = "user", note: String) -> Bool {
        let text = draft == "main" ? script : (variants.first { $0.slug == draft }?.text ?? "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let latest = lastSnapshotText[draft] ?? versions().first(where: { $0.draft == draft })?.text()
        if latest == text {
            lastSnapshotText[draft] = text
            lastSnapshotAt[draft] = Date()
            return false
        }
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let now = Date()
        var file = historyDir.appending(path: "\(Self.stampFormatter.string(from: now))-\(draft).md")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = historyDir.appending(path: "\(Self.stampFormatter.string(from: now))-\(draft)-\(n).md"); n += 1
        }
        let raw = FrontMatter.render([("author", author), ("note", note), ("created", Self.iso.string(from: now)),
                                      ("draft", draft)], text)
        try? raw.write(to: file, atomically: true, encoding: .utf8)
        lastSnapshotAt[draft] = now
        lastSnapshotText[draft] = text
        historyCount += 1
        historyStamp = Store.modified(historyDir)
        return true
    }

    /// While you keep editing, snapshot at most every 5 minutes.
    func autoSnapshotIfDue(_ draft: String) {
        if Date().timeIntervalSince(lastSnapshotAt[draft] ?? .distantPast) > 300 {
            snapshot(draft: draft, note: "Edited")
            dirtyDrafts.remove(draft)
        }
    }

    /// Snapshot everything edited since the last snapshot (session close, recording, quit).
    func snapshotDirty(note: String = "Edited") {
        for d in dirtyDrafts { snapshot(draft: d, note: note) }
        dirtyDrafts.removeAll()
    }

    func restore(_ v: ScriptVersion) {
        let target = (v.draft == "main" || variants.contains { $0.slug == v.draft }) ? v.draft : "main"
        let when = v.created.formatted(date: .abbreviated, time: .shortened)
        snapshot(draft: target, note: "Before restoring \(when)")
        let text = v.text()
        if target == "main" {
            script = text
            flushScript()
        } else if let i = variants.firstIndex(where: { $0.slug == target }) {
            variants[i].text = text
            writeVariant(variants[i])
        }
        snapshot(draft: target, note: "Restored \(when)")
        activeDraft = target
    }

    /// Flush pending writes and snapshot edits. Call when leaving the session or quitting.
    func close() {
        flushScript()
        variantSaveTask?.cancel()
        if activeDraft != "main", let v = variants.first(where: { $0.slug == activeDraft }) { writeVariant(v) }
        snapshotDirty()
    }
}
