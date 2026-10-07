import Foundation

// The blog article (2026-10-04): posts/article.md, a post for the user's blog in the
// blog's own format: markdown plus the MDX components the site has (Callout, Terminal, TLDR, ...).
// Front matter title, description, category (Tech | Life | Business), slug and the usual post keys.
// Later the same article goes out as a LinkedIn article and an X article, and a video points to it.
//
// The preview is the blog's post page, so this renders the markdown to HTML the way the site does:
// no GFM, no syntax colours, sentences not wrapped. The look is in ArticleView.swift.

enum Article {
    static let categories = ["Tech", "Life", "Business"]
    /// Pictures the site serves from its own folder (/images/...) load from the live site.
    static var site: String { UserDefaults.standard.string(forKey: "articleSite") ?? "https://example.com" }

    /// The words in the text, without markup: for the counter and the reading time (200 a minute, as the site).
    static func words(_ md: String) -> Int {
        md.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
    }

    static func minutes(_ md: String) -> Int { minutes(words: words(md)) }
    static func minutes(words: Int) -> Int { max(1, Int((Double(words) / 200).rounded(.up))) }

    /// The slug the site would give the title: lower case, words joined with "-".
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        let parts = folded.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return parts.joined(separator: "-")
    }

    private static let markPattern = try! NSRegularExpression(
        pattern: #"</?[A-Z][^>]*>|^#{1,6} |^> |^```.*$|\*\*|(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])|^\s*(?:[-*+]|\d+\.) "#,
        options: [.anchorsMatchLines])

    /// The marks of the markdown, quiet in the editor: component tags, # and > at a line's start, ** and fences.
    static func marks(_ md: String) -> [NSRange] {
        markPattern.matches(in: md, range: NSRange(location: 0, length: (md as NSString).length)).map(\.range)
    }

    // MARK: - Markdown to HTML

    /// The article body as the site renders it inside `<article class="prose">`.
    static func html(_ md: String) -> String {
        blocks(md).map(\.html).joined(separator: "\n")
    }

    /// Each top-level block with the markdown it came from. The page edits blocks in place and
    /// writes back only the ones that changed, so the rest keeps its exact source (2026-10-04).
    static func blocks(_ md: String) -> [(html: String, md: String)] {
        var r = Renderer(lines: md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return r.blocks()
    }

    /// The components the site's MDX knows. Anything else that looks like a tag passes through as HTML.
    static let components: Set<String> = ["Callout", "Terminal", "Tooltip", "Tweet", "FileTree", "Flowchart",
                                          "Harmonograph", "Prompt", "TLDR", "TaskHorizonChart", "Steps", "Step",
                                          "Collapse", "Ascii", "BarChart", "LineChart", "PieChart", "Video"]

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Where a picture or a link points: the session for relative paths, the live site for /...
    static func src(_ s: String) -> String {
        if s.hasPrefix("/") && !s.hasPrefix("//") { return site + s }
        return s
    }

    // MARK: Inline

    private static let codeSpan = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#)
    private static let strong = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|__(.+?)__"#)
    private static let em = try! NSRegularExpression(pattern: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#)
    private static let tooltip = try! NSRegularExpression(pattern: #"&lt;Tooltip\s+text=(?:&quot;(.*?)&quot;|\{&quot;(.*?)&quot;\})\s*&gt;(.*?)&lt;/Tooltip&gt;"#)
    private static let expr = try! NSRegularExpression(pattern: #"\{\s*(?:&quot;(.*?)&quot;|'(.*?)'|`(.*?)`)\s*\}"#)
    private static let br = try! NSRegularExpression(pattern: #"&lt;br\s*/?&gt;"#)

    /// One line or paragraph of text: code, pictures, links, bold, italics, tooltips.
    static func inline(_ raw: String) -> String {
        // Code first, so nothing inside it turns into markup.
        var codes: [String] = []
        var s = replace(codeSpan, in: raw) { m in
            codes.append("<code>\(esc(m[1]))</code>")
            return "\u{E000}\(codes.count - 1)\u{E001}"
        }
        s = esc(s)
        s = replace(expr, in: s) { m in m[1].isEmpty ? (m[2].isEmpty ? m[3] : m[2]) : m[1] }
        s = replace(tooltip, in: s) { m in
            let tip = m[1].isEmpty ? m[2] : m[1]
            return "<span class=\"tip\"><span class=\"tip-word\">\(m[3])</span><span class=\"tip-bubble\" role=\"tooltip\">\(tip)</span></span>"
        }
        s = replace(image, in: s) { m in "<img src=\"\(src(unescape(m[2])))\" alt=\"\(m[1])\" loading=\"lazy\">" }
        s = replace(link, in: s) { m in "<a href=\"\(src(unescape(m[2])))\">\(m[1])</a>" }
        s = replace(strong, in: s) { m in "<strong>\(m[1].isEmpty ? m[2] : m[1])</strong>" }
        s = replace(em, in: s) { m in "<em>\(m[1].isEmpty ? m[2] : m[1])</em>" }
        s = br.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<br>")
        for (i, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: c) }
        return s
    }

    private static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "&amp;", with: "&") }

    /// Replaces each match with what `f` makes of its groups (empty string for a group that did not take part).
    static func replace(_ re: NSRegularExpression, in s: String, _ f: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: Components

    /// A component's attributes: name="text", name={expression} and bare names (true).
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let c = Array(s)
        var i = 0
        func skipSpace() { while i < c.count && c[i].isWhitespace { i += 1 } }
        while i < c.count {
            skipSpace()
            var name = ""
            while i < c.count && (c[i].isLetter || c[i].isNumber || c[i] == "-" || c[i] == "_") { name.append(c[i]); i += 1 }
            if name.isEmpty { i += 1; continue }
            skipSpace()
            guard i < c.count && c[i] == "=" else { out[name] = "true"; continue }
            i += 1
            skipSpace()
            guard i < c.count else { break }
            if c[i] == "\"" || c[i] == "'" {
                let q = c[i]; i += 1
                var v = ""
                while i < c.count && c[i] != q { v.append(c[i]); i += 1 }
                i += 1
                out[name] = v
            } else if c[i] == "{" {
                var depth = 0, v = ""
                var quote: Character?
                while i < c.count {
                    let ch = c[i]
                    if let q = quote { if ch == q && c[i - 1] != "\\" { quote = nil } }
                    else if ch == "\"" || ch == "'" || ch == "`" { quote = ch }
                    else if ch == "{" { depth += 1 }
                    else if ch == "}" { depth -= 1; if depth == 0 { i += 1; break } }
                    v.append(ch); i += 1
                }
                out[name] = String(v.dropFirst()).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                if v.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("[") { out[name] = String(v.dropFirst()) }
            } else {
                var v = ""
                while i < c.count && !c[i].isWhitespace { v.append(c[i]); i += 1 }
                out[name] = v
            }
        }
        return out
    }

    /// The text inside a component, without a {`...`} wrapper or {"..."} pieces.
    static func plain(_ inner: String) -> String {
        var t = inner.trimmingCharacters(in: .newlines)
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{`") && trimmed.hasSuffix("`}") { t = String(trimmed.dropFirst(2).dropLast(2)) }
        t = replace(try! NSRegularExpression(pattern: #"\{\s*(?:"(.*?)"|'(.*?)')\s*\}"#), in: t) { m in m[1].isEmpty ? m[2] : m[1] }
        return t.trimmingCharacters(in: .newlines)
    }

    /// The steps of a Flowchart: a JS array of strings and {decision, yes, no} objects.
    static func flowSteps(_ js: String) -> [Any] {
        var json = js.trimmingCharacters(in: .whitespacesAndNewlines)
        json = replace(try! NSRegularExpression(pattern: #"'((?:[^'\\]|\\.)*)'"#), in: json) { m in
            "\"" + m[1].replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        json = json.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_]\w*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
        json = json.replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] ?? []
    }

    static func component(_ name: String, _ a: [String: String], _ inner: String) -> String {
        switch name {
        case "Callout":
            let type = ["tip", "warning", "note"].contains(a["type"] ?? "") ? a["type"]! : "note"
            let icon = ["tip": "[→]", "warning": "[!]", "note": "[*]"][type]!
            return "<div class=\"callout\"><span class=\"callout-icon\">\(icon)</span><div class=\"callout-body\">"
                + "<span class=\"callout-label\">\(type)</span><div class=\"callout-text\">\(html(inner))</div></div></div>"
        case "Terminal":
            let prompt = a["command"] != nil ? "$" : "&gt;"
            return "<div class=\"terminal\"><div class=\"terminal-bar\"><span class=\"dots\"><i class=\"r\"></i><i class=\"y\"></i><i class=\"g\"></i></span>"
                + "<span class=\"copy\">\(copyIcon)</span></div><div class=\"terminal-body\"><pre><span class=\"prompt\">\(prompt)</span> \(esc(plain(inner)))</pre></div></div>"
        case "Tweet":
            let id = a["id"] ?? ""
            return "<figure class=\"tweet\"><p class=\"tweet-label\">X post</p><a href=\"https://x.com/i/status/\(esc(id))\">View referenced post</a></figure>"
        case "Video":
            let poster = a["poster"].map { " poster=\"\(esc(src($0)))\"" } ?? ""
            return "<figure class=\"video\"><video src=\"\(esc(src(a["src"] ?? "")))\"\(poster) controls playsinline preload=\"metadata\"></video></figure>"
        case "FileTree":
            return "<div class=\"filetree\"><pre>\(esc(plain(inner)))</pre></div>"
        case "Ascii":
            let cap = a["caption"].map { "<figcaption>\(inline($0))</figcaption>" } ?? ""
            return "<figure class=\"ascii\"><div><pre>\(esc(plain(inner)))</pre></div>\(cap)</figure>"
        case "Prompt":
            let head = a["title"].map { "<span class=\"prompt-title\">\(esc($0))</span>" } ?? "<span class=\"prompt-tag\">[prompt]</span>"
            return "<div class=\"promptbox\"><div class=\"promptbox-bar\">\(head)<span class=\"copy\">\(copyIcon)</span></div>"
                + "<div class=\"promptbox-body\">\(esc(plain(inner)))</div></div>"
        case "TLDR":
            return "<aside class=\"tldr\"><details><summary><span class=\"tldr-sign\"></span>TL;DR</summary><div class=\"tldr-body\">\(html(inner))</div></details></aside>"
        case "Collapse":
            return "<details class=\"collapse\"><summary>\(esc(a["title"] ?? ""))</summary><div>\(html(inner))</div></details>"
        case "Steps":
            return "<div class=\"steps\">\(html(inner))</div>"
        case "Step":
            return "<div class=\"step\"><span class=\"step-n\"></span><div><div class=\"step-title\">\(esc(a["title"] ?? ""))</div><div class=\"step-text\">\(html(inner))</div></div></div>"
        case "Flowchart":
            return flowchart(flowSteps(a["steps"] ?? "[]"), caption: a["caption"])
        case "Harmonograph":
            let cap = a["caption"].map { "<figcaption>\(inline($0))</figcaption>" } ?? ""
            let h = Int(a["height"] ?? "") ?? 420
            return "<figure class=\"harmonograph\"><div style=\"height:\(min(h, 420))px\"><span>harmonograph</span></div>\(cap)</figure>"
        case "TaskHorizonChart":
            return "<figure class=\"wide\"><img src=\"\(site)/images/task-horizon-curve.webp\" alt=\"The Task Horizon Curve\"></figure>"
        case "BarChart", "LineChart", "PieChart":
            let h = Int(a["height"] ?? "") ?? 300
            let title = a["title"].map { esc($0) } ?? name.replacingOccurrences(of: "Chart", with: " chart").lowercased()
            return "<div class=\"chart\" style=\"height:\(h)px\"><span>[\(name == "PieChart" ? "pie" : name == "LineChart" ? "line" : "bar")] \(title)</span></div>"
        default:
            return ""
        }
    }

    private static func flowchart(_ steps: [Any], caption: String?) -> String {
        var parts: [String] = []
        for (i, s) in steps.enumerated() {
            if i > 0 { parts.append("<div class=\"flow-arrow\"><i></i><span>▼</span></div>") }
            if let t = s as? String {
                parts.append("<div class=\"flow-box\">\(esc(t))</div>")
            } else if let d = s as? [String: Any] {
                let q = d["decision"] as? String ?? "", yes = d["yes"] as? String ?? "", no = d["no"] as? String ?? ""
                parts.append("<div class=\"flow-box\">\(esc(q))</div><div class=\"flow-branches\">"
                    + "<div><span class=\"flow-label\">yes</span><div class=\"flow-box\">\(esc(yes))</div></div>"
                    + "<div><span class=\"flow-label\">no</span><div class=\"flow-box no\">\(esc(no))</div><span class=\"flow-loop\">↻ loops back</span></div></div>")
            }
        }
        let cap = caption.map { "<figcaption>\(inline($0))</figcaption>" } ?? ""
        return "<figure class=\"flow\"><div class=\"flow-col\">\(parts.joined())</div>\(cap)</figure>"
    }

    private static let copyIcon = "<svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><rect x=\"9\" y=\"9\" width=\"13\" height=\"13\" rx=\"2\"/><path d=\"M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1\"/></svg>"

    // MARK: Blocks

    private struct Renderer {
        let lines: [String]
        var i = 0

        init(lines: [String]) { self.lines = lines }

        private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*#*\s*$"#)
        private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
        private static let openTag = try! NSRegularExpression(pattern: #"^\s*<([A-Z][A-Za-z]*)\b"#)

        mutating func blocks() -> [(html: String, md: String)] {
            var out: [(html: String, md: String)] = []
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { i += 1; continue }
                let start = i
                guard let html = block(line, t) else { continue }
                var end = i
                while end > start + 1 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
                out.append((html, lines[start..<end].joined(separator: "\n")))
            }
            return out
        }

        /// One block from line i on; nil only when it read nothing.
        private mutating func block(_ line: String, _ t: String) -> String? {
            let at = i
            let html: String
            if t.hasPrefix("```") || t.hasPrefix("~~~") { html = fence() }
            else if let name = Self.match(Self.openTag, line)?[1], Article.components.contains(name), name != "Tooltip" { html = component(name) }
            else if let m = Self.match(Self.heading, line) {
                let n = m[1].count
                html = "<h\(n)>\(Article.inline(m[2]))</h\(n)>"; i += 1
            }
            else if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { html = "<hr>"; i += 1 }
            else if t.hasPrefix(">") { html = quote() }
            else if Self.match(Self.listItem, line) != nil { html = list() }
            else if t.hasPrefix("<") && !t.hasPrefix("<Tooltip") && t.range(of: #"^</?[a-z]"#, options: .regularExpression) != nil { html = rawHTML() }
            else { html = paragraph() }
            if i == at { i += 1; return nil }
            return html
        }

        static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }

        private mutating func fence() -> String {
            let open = lines[i].trimmingCharacters(in: .whitespaces)
            let mark = String(open.prefix(3))
            let lang = open.dropFirst(3).trimmingCharacters(in: .whitespaces)
            i += 1
            var body: [String] = []
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(mark) { body.append(lines[i]); i += 1 }
            i += 1
            let cls = lang.isEmpty ? "" : " class=\"language-\(Article.esc(lang))\""
            return "<pre><code\(cls)>\(Article.esc(body.joined(separator: "\n")))</code></pre>"
        }

        /// A component from its opening tag to its closing tag (or a self-closing tag), at any depth.
        private mutating func component(_ name: String) -> String {
            var tag = "", rest = ""
            // The opening tag may span lines: read until its ">" outside quotes and braces.
            var depth = 0
            var quote: Character?
            var closed = false, selfClosing = false
            let start = i
            outer: while i < lines.count {
                let line = lines[i]
                var j = line.startIndex
                if i == start, let lt = line.firstIndex(of: "<") { j = line.index(after: lt) }
                while j < line.endIndex {
                    let ch = line[j]
                    if let q = quote { if ch == q { quote = nil } }
                    else if ch == "\"" || ch == "'" || ch == "`" { quote = ch }
                    else if ch == "{" { depth += 1 }
                    else if ch == "}" { depth -= 1 }
                    else if ch == ">" && depth == 0 {
                        selfClosing = tag.hasSuffix("/")
                        rest = String(line[line.index(after: j)...])
                        closed = true
                        i += 1
                        break outer
                    }
                    tag.append(ch)
                    j = line.index(after: j)
                }
                tag.append("\n")
                i += 1
            }
            guard closed else { return "" }
            if selfClosing { tag.removeLast() }
            let attrs = Article.attributes(String(tag.dropFirst(name.count)))
            if selfClosing { return Article.component(name, attrs, "") }
            // The children: until the matching close tag, counting nested ones of the same name.
            let closeTag = "</\(name)>"
            var inner: [String] = []
            var level = 1
            var line = rest
            while true {
                var cut: String.Index?
                var scan = line.startIndex
                while scan < line.endIndex {
                    let tail = line[scan...]
                    if tail.hasPrefix(closeTag) { level -= 1; if level == 0 { cut = scan; break }; scan = line.index(scan, offsetBy: closeTag.count); continue }
                    if tail.hasPrefix("<\(name)") {
                        let after = line.index(scan, offsetBy: name.count + 1)
                        if after == line.endIndex || !(line[after].isLetter) { level += 1 }
                    }
                    scan = line.index(after: scan)
                }
                if let cut {
                    inner.append(String(line[..<cut]))
                    let after = String(line[line.index(cut, offsetBy: closeTag.count)...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { inner.append(after) }   // rare: text after the close tag
                    break
                }
                inner.append(line)
                guard i < lines.count else { break }
                line = lines[i]; i += 1
            }
            return Article.component(name, attrs, inner.joined(separator: "\n"))
        }

        private mutating func quote() -> String {
            var body: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                var s = t.dropFirst()
                if s.hasPrefix(" ") { s = s.dropFirst() }
                body.append(String(s)); i += 1
            }
            return "<blockquote>\(Article.html(body.joined(separator: "\n")))</blockquote>"
        }

        private mutating func list() -> String {
            guard let first = Self.match(Self.listItem, lines[i]) else { return "" }
            let indent = first[1].count
            let ordered = first[2].first!.isNumber
            var items: [[String]] = []
            var loose = false, blank = false
            var content = indent + first[2].count + 1
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    blank = true; i += 1; continue
                }
                let lead = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                if let m = Self.match(Self.listItem, line), lead == indent {
                    if m[2].first!.isNumber != ordered { break }
                    if blank && !items.isEmpty { loose = true }
                    items.append([m[3]]); content = indent + m[2].count + 1; blank = false; i += 1; continue
                }
                if lead > indent, !items.isEmpty {
                    // A line of the item: a nested list or more of its text.
                    if blank { items[items.count - 1].append("") }
                    items[items.count - 1].append(String(line.dropFirst(min(lead, content))))
                    blank = false; i += 1; continue
                }
                if blank { break }
                if lead < indent || Self.match(Self.listItem, line) != nil { break }
                // A lazy continuation line of the item's paragraph.
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces)); i += 1
            }
            let tag = ordered ? "ol" : "ul"
            let lis = items.map { item -> String in
                var body = Article.html(item.joined(separator: "\n"))
                if !loose, body.hasPrefix("<p>"), let end = body.range(of: "</p>") {
                    body = String(body[body.index(body.startIndex, offsetBy: 3)..<end.lowerBound]) + body[end.upperBound...]
                }
                return "<li>\(body)</li>"
            }
            return "<\(tag)>\(lis.joined())</\(tag)>"
        }

        private mutating func rawHTML() -> String {
            var body: [String] = []
            while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[i]); i += 1 }
            return body.joined(separator: "\n")
        }

        private mutating func paragraph() -> String {
            var body: [String] = []
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix(">") || t.hasPrefix("#") && Self.match(Self.heading, line) != nil { break }
                if !body.isEmpty, Self.match(Self.listItem, line) != nil { break }
                if let name = Self.match(Self.openTag, line)?[1], Article.components.contains(name), name != "Tooltip" { break }
                body.append(t); i += 1
            }
            return "<p>\(Article.inline(body.joined(separator: "\n")))</p>"
        }
    }
}
