import AppKit
import SwiftUI

// @ in the chat box (2026-10-13). Typing @ opens one list of the styles, effects (2026-10-29),
// skills and files of this session, and the words after @ filter it. ↑ ↓ move, Return or Tab
// picks, Esc closes. A pick writes "@Name " into the box, tinted like a chip; Backspace right after
// it takes the whole name. On send, Takes adds what each name is for the agent: a style to switch
// this video to (set_style), an effect to use (list_effects), a skill to read and follow, a file's
// path. The chat shows the message without it.
// Design board, variant A "One list": https://claude.ai/artifact/2YE4US6uuJYdBBtvG8fXWo

struct Mention: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case style = "Styles", effect = "Effects", skill = "Skills", asset = "Assets" }
    let kind: Kind
    let name: String
    var detail: String?
    /// A picture for the row: a style's preview.png, a still, an edit.
    var image: URL?
    /// The style, effect or skill folder, or the file.
    let path: URL
    var id: String { kind.rawValue + ":" + path.path }
    var token: String { "@" + name }
}

enum Mentions {
    static let mark = "\n\n[@mentions: what I picked with @ in Takes]\n"

    /// The "@words" at the end of the box, where the list opens. Nil when no @ is being typed: an
    /// @ inside a word (an email), a line break after it, or a name already picked.
    static func query(_ draft: String, picked: [Mention] = []) -> (at: String.Index, text: String)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let text = String(draft[draft.index(after: at)...])
        guard text.count <= 40, !text.contains("\n"), text.first != " " else { return nil }
        if picked.contains(where: { text.hasPrefix($0.name) }) { return nil }
        return (at, text)
    }

    /// The rows for what was typed after @: a name that has the words, or every row of a kind
    /// ("sty" shows the styles). Names that start with the words come first.
    static func filter(_ all: [Mention], _ typed: String) -> [Mention] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        let hits = all.filter { $0.name.lowercased().contains(q) || $0.kind.rawValue.lowercased().hasPrefix(q) }
        return Mention.Kind.allCases.flatMap { kind in
            let of = hits.filter { $0.kind == kind }
            return of.filter { $0.name.lowercased().hasPrefix(q) } + of.filter { !$0.name.lowercased().hasPrefix(q) }
        }
    }

    /// The box after a pick: the typed "@words" become "@Name ".
    static func pick(_ m: Mention, into draft: String, picked: [Mention] = []) -> String {
        guard let q = query(draft, picked: picked) else { return draft + m.token + " " }
        return String(draft[..<q.at]) + m.token + " "
    }

    /// The picked names still in the message, once each.
    static func used(_ picked: [Mention], in text: String) -> [Mention] {
        var seen = Set<String>()
        return picked.filter { text.contains($0.token) && seen.insert($0.id).inserted }
    }

    /// What the agent reads after the message: what each name is and what to do with it.
    static func note(_ used: [Mention], session: URL?) -> String {
        guard !used.isEmpty else { return "" }
        let lines = used.map { m -> String in
            switch m.kind {
            case .style:
                let target = session.map { "this video (set_style with session \($0.path))" }
                    ?? "the project I mean (set_style with project; ask which if it is not clear)"
                return "- \(m.token): the style \"\(m.name)\". Switch \(target) to it, then make the work "
                    + "in this message in that style: get_library gives its guide and parts."
            case .effect:
                return "- \(m.token): the effect \"\(m.name)\". Use it in the work in this message: "
                    + "list_effects \(m.path.lastPathComponent) gives its README and source."
            case .skill:
                return "- \(m.token): the skill \(m.path.lastPathComponent), at \(m.path.appending(path: "SKILL.md").path). "
                    + "Read it and follow it for this message."
            case .asset:
                return "- \(m.token): the file \(m.path.path)"
            }
        }
        return mark + lines.joined(separator: "\n")
    }

    /// The names a sent message picked, read back from its note: the chat tints them.
    static func tokens(in sent: String) -> [String] {
        guard let r = sent.range(of: mark, options: .backwards) else { return [] }
        return sent[r.upperBound...].components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("- @"), let end = line.range(of: ": the ") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])
        }
    }

    /// The ranges of the names in a text, longest names first so "@Green Room Argon" is not cut
    /// at "@Green Room".
    static func ranges(of tokens: [String], in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for t in Set(tokens).sorted(by: { $0.count > $1.count }) {
            var from = text.startIndex
            while let r = text.range(of: t, range: from..<text.endIndex) {
                if !found.contains(where: { $0.overlaps(r) }) { found.append(r) }
                from = r.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A sent message with its names as chips on the dark bubble.
    static func styled(_ text: String, tokens: [String]) -> AttributedString {
        var out = AttributedString(text)
        guard !tokens.isEmpty else { return out }
        for r in ranges(of: tokens, in: text) {
            guard let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].backgroundColor = Color.white.opacity(0.16)
            out[lo..<hi].font = Theme.sans(13, .medium)
        }
        return out
    }

    /// Everything the list can show for a chat. Reads a few folders: call it when the list opens.
    static func all(session: URL?, root: URL, effects: URL = EffectLib.shipped) -> [Mention] {
        let fm = FileManager.default
        var out: [Mention] = []
        let inUse = session.flatMap { s in
            StyleLib.chosen(session: s, pick: StyleLib.json(s.appending(path: "session.json"))["style"] as? String, root: root)
        }
        for name in StyleLib.styleNames(root: root) {
            let dir = StyleLib.style(name, root: root)
            let png = dir.appending(path: "preview.png")
            out.append(Mention(kind: .style, name: name, detail: name == inUse ? "In use" : nil,
                               image: fm.fileExists(atPath: png.path) ? png : nil, path: dir))
        }
        // Effects are opt-in: picking one with @ is asking for it.
        for c in EffectLib.cards(shipped: effects, root: root) {
            out.append(Mention(kind: .effect, name: c.name, detail: c.kind.isEmpty ? nil : c.kind,
                               image: c.poster, path: c.dir ?? EffectLib.own(root: root).appending(path: c.slug)))
        }
        var titles = Set<String>()
        // Takes' own skills and packs first: the rest of ~/.claude/skills can be long.
        let skills = SkillShelf.list(in: SkillShelf.home)
        let ours = skills.filter { SkillShelf.source(of: $0.folder) != nil }
        for skill in ours + skills.filter({ !ours.contains($0) }) where titles.insert(skill.title.lowercased()).inserted {
            out.append(Mention(kind: .skill, name: skill.title, path: skill.folder))
        }
        if let session {
            let label = ["edits": "Edit", "stills": "Still", "thumbnails": "Thumbnail", "assets": "File"]
            let files = AssetStore.walk(session, takeFiles: [])
                .filter { label[$0.group] != nil }
                .sorted { $0.modified > $1.modified }
                .prefix(12)
            for a in files {
                out.append(Mention(kind: .asset, name: a.url.lastPathComponent, detail: label[a.group],
                                   image: [.video, .image].contains(a.kind) ? a.url : nil, path: a.url))
            }
        }
        return out
    }
}

/// The list's state for one message box: what it can show, the lit row, the names picked.
@MainActor @Observable
final class MentionPicker {
    var session: URL?
    /// Names picked into the box and not sent yet.
    var picked: [Mention] = []
    var lit = 0
    /// The box's text when Esc closed the list: it stays closed until the text changes.
    var shut: String?
    @ObservationIgnored private var all: [Mention] = []
    @ObservationIgnored private var wasOpen = false
    @ObservationIgnored var root: URL = ClaudeChat.libraryRoot

    /// The rows to show now. Empty: the list is closed.
    func rows(_ draft: String) -> [Mention] {
        guard shut != draft, let q = Mentions.query(draft, picked: picked) else { wasOpen = false; return [] }
        // Read the folders each time the list opens: a new edit or style shows at once.
        if !wasOpen { all = Mentions.all(session: session, root: root); wasOpen = true }
        return Mentions.filter(all, q.text)
    }

    func add(_ m: Mention) { if !picked.contains(m) { picked.append(m) } }

    /// The note for a message as it is sent; the picks are used up.
    func take(for text: String) -> String {
        let note = Mentions.note(Mentions.used(picked, in: text), session: session)
        picked = []
        return note
    }
}

/// The list over the box. MenuKit's look: paper, hairline, radius 12, rows 30 high.
struct MentionMenu: View {
    let rows: [Mention]
    let lit: Int
    let hover: (Int) -> Void
    let pick: (Mention) -> Void

    private static let rowHeight: CGFloat = 30
    private static let labelHeight: CGFloat = 24

    var body: some View {
        let kinds = Mention.Kind.allCases.filter { k in rows.contains { $0.kind == k } }
        let height = CGFloat(rows.count) * (Self.rowHeight + 1) + CGFloat(kinds.count) * Self.labelHeight + 12
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(kinds, id: \.self) { kind in
                        Text(kind.rawValue).font(Theme.sans(11, .medium)).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 8).frame(height: Self.labelHeight, alignment: .bottomLeading)
                            .padding(.bottom, 2)
                        ForEach(rows.indices.filter { rows[$0].kind == kind }, id: \.self) { i in
                            MentionRow(mention: rows[i], lit: i == lit)
                                .id(i)
                                .onHover { if $0 { hover(i) } }
                                .onTapGesture { pick(rows[i]) }
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 268, height: min(height, 320))
            .onChange(of: lit) { _, i in proxy.scrollTo(i) }
        }
        .menuChrome()
        .shadow(color: Theme.ink.opacity(0.14), radius: 16, y: 8)
        .accessibilityLabel("Mention a style, effect, skill or file")
    }
}

private struct MentionRow: View {
    let mention: Mention
    let lit: Bool

    var body: some View {
        HStack(spacing: 9) {
            MentionThumb(mention: mention)
            Text(mention.name).font(Theme.sans(13)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            if let d = mention.detail {
                Text(d).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).kerning(0.4).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Theme.ink.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A 20 pt picture: the style's or effect's preview, the still, the edit's frame. A skill has its icon.
private struct MentionThumb: View {
    let mention: Mention
    @State private var image: NSImage?

    var body: some View {
        let shown = image ?? still
        ZStack {
            if let image = shown {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            if shown != nil {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5)
            }
        }
        .task(id: mention.image) {
            // A video gives a frame, later. A picture shows at once (still).
            guard let url = mention.image, Asset.kind(of: url) == .video else { image = nil; return }
            image = await Thumbs.shared.image(Asset.at(url))
        }
    }

    /// A picture opens as it is: NSImage reads its pixels only when drawn.
    private var still: NSImage? {
        guard let url = mention.image, Asset.kind(of: url) == .image else { return nil }
        return Self.picture(url)
    }

    private static var pictures: [URL: NSImage] = [:]
    private static func picture(_ url: URL) -> NSImage? {
        if let hit = pictures[url] { return hit }
        let image = NSImage(contentsOf: url)
        pictures[url] = image
        return image
    }

    private var icon: String {
        switch mention.kind {
        case .style: "square.grid.2x2"
        case .effect: "sparkles"
        case .skill: "wand.and.stars"
        case .asset: "doc"
        }
    }
}

/// A TextField cannot style part of its text, so the picked names are tinted in its editor while
/// you type: drawing-only colours, the text itself stays plain.
@MainActor
enum MentionTint {
    /// The editor of the box being typed in: the key window's, else any window's (a test window).
    static func editor() -> NSTextView? {
        for window in [NSApp.keyWindow].compactMap({ $0 }) + NSApp.windows {
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return editor }
        }
        return nil
    }

    static func apply(_ tokens: [String]) {
        RunLoop.main.perform {
            guard let editor = editor() else { return }
            let text = editor.string
            let ranges = Mentions.ranges(of: tokens, in: text).map { NSRange($0, in: text) }
            let colours: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor(Theme.accentSoft),
                                                          .foregroundColor: NSColor(Theme.accentInk)]
            if let layout = editor.textLayoutManager, let content = layout.textContentManager {
                layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
                layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
                for r in ranges {
                    guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                          let end = content.location(start, offsetBy: r.length),
                          let range = NSTextRange(location: start, end: end) else { continue }
                    for (key, value) in colours { layout.addRenderingAttribute(key, value: value, for: range) }
                }
            } else if let layout = editor.layoutManager {
                let all = NSRange(location: 0, length: (text as NSString).length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
                for r in ranges { layout.addTemporaryAttributes(colours, forCharacterRange: r) }
            }
        }
    }
}
