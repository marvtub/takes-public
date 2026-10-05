import AppKit
import SwiftUI

// Markdown to read (2026-10-04): the Comments library showed its files as raw markdown, and the
// target list is mostly tables. This draws headings, lists, quotes, code, links and real tables
// in a text view you can select in, so commenting on a quote works the same as in the editor.

enum MarkdownText {
    /// The whole file as styled text. `size` is the body size.
    static func attributed(_ md: String, size: CGFloat = 14) -> NSAttributedString {
        var r = Builder(size: size)
        r.build(md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return r.out
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight == .bold ? "Inter-Bold" : weight == .semibold ? "Inter-SemiBold"
            : weight == .medium ? "Inter-Medium" : "Inter-Regular"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Bold, italic, code and links inside one line, in the given font.
    static func inline(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let i = run.inlinePresentationIntent {
                if i.contains(.stronglyEmphasized) { f = Self.font(font.pointSize, .semibold) }
                if i.contains(.emphasized) { attrs[.obliqueness] = 0.14 }
                if i.contains(.code) {
                    f = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                    attrs[.backgroundColor] = NSColor(Theme.hover)
                }
                if i.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor(Theme.accentInk)
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    private struct Builder {
        let size: CGFloat
        var out = NSMutableAttributedString()
        init(size: CGFloat) { self.size = size }

        private var ink: NSColor { Theme.inkNS }
        private var muted: NSColor { NSColor(Theme.muted) }

        private func para(before: CGFloat = 0, after: CGFloat, indent: CGFloat = 0, head: CGFloat? = nil) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = size * 0.3
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.headIndent = indent
            p.firstLineHeadIndent = head ?? indent
            return p
        }

        private mutating func add(_ s: NSAttributedString, _ p: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n"))
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }

        mutating func build(_ lines: [String]) {
            var i = 0
            // Front matter: quiet, as it is for the agent.
            if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
               let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                code(Array(lines[0...end]))
                i = end + 1
            }
            var text: [String] = []
            func flush(_ b: inout Builder) {
                guard !text.isEmpty else { return }
                b.add(inline(text.joined(separator: " "), font: font(b.size), color: b.ink), b.para(after: b.size * 0.7))
                text = []
            }
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { flush(&self); i += 1; continue }
                if t.hasPrefix("```") || t.hasPrefix("~~~") {
                    flush(&self)
                    var j = i + 1
                    while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(String(t.prefix(3))) { j += 1 }
                    code(Array(lines[(i + 1)..<min(j, lines.count)]))
                    i = j + 1; continue
                }
                if let (level, title) = heading(t) {
                    flush(&self)
                    let s: CGFloat = level == 1 ? size * 1.6 : level == 2 ? size * 1.3 : level == 3 ? size * 1.12 : size
                    add(inline(title, font: font(s, level <= 2 ? .bold : .semibold), color: ink),
                        para(before: out.length == 0 ? 0 : size * (level <= 2 ? 1.1 : 0.7), after: size * 0.45))
                    i += 1; continue
                }
                if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                    flush(&self)
                    add(NSAttributedString(string: "\u{00A0}", attributes: [.font: font(4),
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor(Theme.border)]),
                        para(before: size * 0.4, after: size * 0.8))
                    i += 1; continue
                }
                if t.hasPrefix("|"), i + 1 < lines.count, Self.isSeparator(lines[i + 1]) {
                    flush(&self)
                    var rows = [Self.cells(t)]
                    var j = i + 2
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        rows.append(Self.cells(lines[j].trimmingCharacters(in: .whitespaces))); j += 1
                    }
                    table(rows)
                    i = j; continue
                }
                if t.hasPrefix(">") {
                    flush(&self)
                    var q: [String] = []
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                    }
                    add(inline(q.joined(separator: " "), font: font(size), color: muted),
                        para(after: size * 0.7, indent: size * 1.2))
                    continue
                }
                if let (depth, mark, body) = Self.item(line) {
                    flush(&self)
                    let indent = size * 1.4 * CGFloat(depth + 1)
                    let bullet = mark.first?.isNumber == true ? mark : "•"
                    let s = NSMutableAttributedString(string: bullet + "\t", attributes: [.font: font(size), .foregroundColor: muted])
                    s.append(inline(body, font: font(size), color: ink))
                    let p = para(after: size * 0.3, indent: indent, head: indent - size * 1.2)
                    p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    p.defaultTabInterval = size
                    add(s, p)
                    i += 1; continue
                }
                text.append(t)
                i += 1
            }
            flush(&self)
        }

        private func heading(_ t: String) -> (Int, String)? {
            let hashes = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
            return (hashes, String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
        }

        private mutating func code(_ lines: [String]) {
            let f = NSFont.monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
            for (n, l) in lines.enumerated() {
                add(NSAttributedString(string: l.isEmpty ? " " : l, attributes: [.font: f, .foregroundColor: muted]),
                    para(after: n == lines.count - 1 ? size * 0.8 : 0, indent: size * 0.6))
            }
        }

        private mutating func table(_ rows: [[String]]) {
            let cols = rows.map(\.count).max() ?? 0
            guard cols > 0 else { return }
            let t = NSTextTable()
            t.numberOfColumns = cols
            t.layoutAlgorithm = .automaticLayoutAlgorithm
            t.collapsesBorders = true
            t.setContentWidth(100, type: .percentageValueType)
            let line = NSColor(Theme.border)
            for (r, row) in rows.enumerated() {
                for c in 0..<cols {
                    let b = NSTextTableBlock(table: t, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    b.setWidth(size * 0.5, type: .absoluteValueType, for: .padding)
                    b.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    b.setBorderColor(line)
                    if r == 0 { b.backgroundColor = NSColor(Theme.hover) }
                    let p = NSMutableParagraphStyle()
                    p.textBlocks = [b]
                    p.lineSpacing = size * 0.15
                    let cell = c < row.count ? row[c] : ""
                    let s = NSMutableAttributedString(attributedString:
                        inline(cell.isEmpty ? " " : cell, font: font(size * 0.9, r == 0 ? .semibold : .regular), color: ink))
                    s.append(NSAttributedString(string: "\n"))
                    s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                }
            }
            // Room after the table.
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(size * 0.6),
                                                                     .paragraphStyle: para(after: 0)]))
        }

        static func isSeparator(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("|") && t.range(of: #"^\|?(\s*:?-{2,}:?\s*\|)+\s*:?-*:?\s*$"#, options: .regularExpression) != nil
        }

        /// The cells of a table row; a `|` inside backticks or after a backslash stays in its cell.
        static func cells(_ row: String) -> [String] {
            var cells: [String] = [], cur = "", code = false, prev: Character = " "
            for ch in row {
                if ch == "`" { code.toggle() }
                if ch == "|", !code, prev != "\\" { cells.append(cur); cur = "" } else { cur.append(ch) }
                prev = ch
            }
            cells.append(cur)
            if row.hasPrefix("|") { cells.removeFirst() }
            if row.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        static func item(_ line: String) -> (Int, String, String)? {
            guard let m = line.range(of: #"^(\s*)([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
            let head = String(line[m])
            let spaces = head.prefix(while: { $0 == " " || $0 == "\t" }).count
            let mark = head.trimmingCharacters(in: .whitespaces)
            return (spaces / 2, mark, String(line[m.upperBound...]))
        }
    }
}

/// A markdown file to read: styled, selectable, links open in the browser. Open comments' quotes
/// are marked; select text and comment on it as in the editor.
struct MarkdownReader: NSViewRepresentable {
    let text: String
    var size: CGFloat = 14
    var highlights: [String] = []
    var reveal: (quote: String, token: Int)? = nil
    var onSelect: (String) -> Void = { _ in }
    var onComment: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: tables (NSTextTable) draw only there.
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 40, height: 32)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [.foregroundColor: NSColor(Theme.accentInk), .cursor: NSCursor.pointingHand]
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        let c = context.coordinator
        c.parent = self
        let page = Theme.paperNS
        tv.backgroundColor = page
        scroll.backgroundColor = page
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.22)]
        let key = "\(text.hashValue)|\(size)|\(scheme)"
        if c.drawn != key {
            c.drawn = key
            let y = scroll.contentView.bounds.origin.y
            tv.textStorage?.setAttributedString(MarkdownText.attributed(text, size: size))
            c.lit = nil
            // An agent's edit redraws in place: keep the reading position.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        c.highlight(tv, highlights)
        if let reveal, reveal.token != c.lastReveal {
            c.lastReveal = reveal.token
            let r = (tv.string as NSString).range(of: MarkdownReader.plain(reveal.quote))
            if r.location != NSNotFound {
                tv.setSelectedRange(r)
                tv.scrollRangeToVisible(r)
                tv.showFindIndicator(for: r)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownReader
        var drawn = ""
        var lit: [String]?
        var lastReveal = 0
        init(_ p: MarkdownReader) { parent = p; lastReveal = p.reveal?.token ?? 0 }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            let s = r.length > 0 ? (tv.string as NSString).substring(with: r) : ""
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.parent.onSelect(trimmed) }
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Comment for Takes…", action: #selector(comment), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func comment() { parent.onComment() }

        func highlight(_ tv: NSTextView, _ quotes: [String]) {
            guard lit != quotes, let lm = tv.layoutManager else { return }
            lit = quotes
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            for q in quotes where !q.isEmpty {
                let r = (tv.string as NSString).range(of: MarkdownReader.plain(q))
                guard r.location != NSNotFound else { continue }
                lm.addTemporaryAttributes([.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.22),
                                           .underlineStyle: NSUnderlineStyle.single.rawValue,
                                           .underlineColor: NSColor(Theme.accent)], forCharacterRange: r)
            }
        }
    }

    /// A quote made in the editor, as Read shows it: link targets and ** marks gone.
    static func plain(_ quote: String) -> String {
        MarkdownText.inline(quote, font: MarkdownText.font(12), color: .black).string
    }
}
