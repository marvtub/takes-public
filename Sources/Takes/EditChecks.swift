import AppKit
import SwiftUI

/// check_edit's results (2026-10-11): the agent cannot hear or watch a video, so check_edit compares
/// each edit with the take it came from (sound, picture, sync, cut words, undone fixes) and runs the
/// learned rules that have a check. The results land in <session>/checks.json, one entry per file
/// (same format as t_check_edit in mcp/takes_mcp.py, entry "v": 2). The review player shows them in a
/// line under its controls, and the Assets tile of an edit with problems gets an amber badge.

/// One result. Built-in checks have `check`, learned rules `rule`; `say` is written for the user.
struct EditCheck: Decodable, Hashable {
    let check: String?
    let rule: String?
    let pass: Bool?
    let label: String?
    let say: String?
    let text: String?
    let at: [Double]?
    let skip: String?
    let error: String?

    init(check: String? = nil, rule: String? = nil, pass: Bool?, label: String? = nil, say: String? = nil,
         text: String? = nil, at: [Double]? = nil, skip: String? = nil, error: String? = nil) {
        self.check = check; self.rule = rule; self.pass = pass; self.label = label; self.say = say
        self.text = text; self.at = at; self.skip = skip; self.error = error
    }

    /// The capsule's words: the fixed label, else the rule's first words.
    var title: String {
        label ?? text.map { "Rule: " + ($0.count <= 30 ? $0 : $0.prefix(29).trimmingCharacters(in: .whitespaces) + "…") } ?? "Problem"
    }
    var help: String { (say ?? text ?? title) + " Ask Takes in the chat to fix it." }
    /// Why it did not run.
    var reason: String { skip ?? error ?? "No reason given." }
}

enum EditChecks {
    enum State: Equatable {
        /// Every check that ran passes; `skipped`: why the others did not run.
        case passed(skipped: [String])
        case problems([EditCheck])
        case nothingRan
        /// The file changed after its last check.
        case stale
        /// No check yet, or only the old rule checks (before 2026-10-11).
        case unchecked
    }

    private struct Entry: Decodable {
        let v: Int?
        let mtime: Double?
        let results: [EditCheck]?
    }

    /// Every entry of checks.json, by file path in the session. Empty when it is missing or does not read.
    nonisolated static func load(_ session: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: session.appending(path: "checks.json")),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return all
    }

    nonisolated static func read(_ session: URL, file rel: String, modified: Date) -> State {
        state(load(session)[rel], modified: modified)
    }

    nonisolated static func state(_ raw: Any?, modified: Date) -> State {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let e = try? JSONDecoder().decode(Entry.self, from: data), e.v == 2 else { return .unchecked }
        // A second of slack: the file system rounds times.
        if let m = e.mtime, modified.timeIntervalSince1970 > m + 1 { return .stale }
        let results = e.results ?? []
        let bad = results.filter { $0.pass == false }
        if !bad.isEmpty { return .problems(bad) }
        let idle = results.filter { $0.pass == nil }
        if idle.count == results.count { return .nothingRan }
        return .passed(skipped: idle.map(\.reason))
    }

    /// How many problems the newest check found, for the Assets badge.
    nonisolated static func problems(_ s: State) -> Int {
        if case .problems(let p) = s { return p.count }
        return 0
    }

    /// The words of the line under the player.
    static func line(_ s: State) -> String {
        switch s {
        case .passed(let skipped):
            return skipped.isEmpty ? "All checks pass." : "All checks pass. \(skipped.count) did not run."
        case .problems(let p): return p.count == 1 ? "1 problem:" : "\(p.count) problems:"
        case .nothingRan: return "Takes could not check this edit. Ask Takes in the chat why."
        case .stale: return "Changed since the last check. Ask Takes to check it again."
        case .unchecked: return "Not checked yet. Ask Takes to check this edit."
        }
    }

    /// A file the line shows for: a video or a sound in the session's edits/ folder.
    nonisolated static func isEdit(_ url: URL, in session: URL) -> Bool {
        let base = session.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > base.count + 1 && Array(parts.prefix(base.count)) == base && parts[base.count] == "edits"
    }
}

/// The line under the review player: what check_edit found in this edit, in plain words. A problem
/// with a time is a capsule you click to go there. One row; what does not fit shows as "+N more".
struct CheckLine: View {
    let state: EditChecks.State
    let width: CGFloat
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(EditChecks.line(state))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .help(help)
            if case .problems(let all) = state {
                let n = Self.fit(all.map(\.title), width: width - Self.textWidth(EditChecks.line(state)) - 6)
                ForEach(Array(all.prefix(n).enumerated()), id: \.offset) { _, c in capsule(c) }
                if n < all.count {
                    Text("+\(all.count - n) more").foregroundStyle(.white.opacity(0.7))
                        .help(all.dropFirst(n).map { $0.say ?? $0.title }.joined(separator: "\n"))
                }
            }
        }
        .font(Theme.sans(11, .medium))
        .frame(maxWidth: width, alignment: .center)
        .id(EditChecks.line(state) + (Self.titles(state)))
        .arrive(0)
    }

    private var help: String {
        if case .passed(let skipped) = state, !skipped.isEmpty { return "Did not run:\n" + skipped.joined(separator: "\n") }
        return ""
    }

    private func capsule(_ c: EditCheck) -> some View {
        Button {
            if let t = c.at?.first { onSeek(t) }
        } label: {
            Text(c.title).font(Theme.sans(11, .semibold)).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Theme.warn, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(PressScale())
        .help(c.help)
    }

    static func titles(_ s: EditChecks.State) -> String {
        if case .problems(let p) = s { return p.map(\.title).joined(separator: "|") }
        return ""
    }

    /// The width of s in the line's type (Inter 11 at the app's text size), measured with Inter or the
    /// system font, plus a little: a capsule that is cut is worse than one more "+N more".
    static func textWidth(_ s: String, bold: Bool = false) -> CGFloat {
        let size = 11 * TextSize.shared.factor
        let font = NSFont(name: bold ? "Inter-SemiBold" : "Inter-Medium", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width * 1.05)
    }

    /// How many capsules fit in one row of `width`, keeping room for "+N more" when some do not.
    static func fit(_ titles: [String], width: CGFloat) -> Int {
        let widths = titles.map { textWidth($0, bold: true) + 14 + 6 }
        if widths.reduce(0, +) <= width { return titles.count }
        let more = textWidth("+\(titles.count) more") + 6
        var used: CGFloat = more, n = 0
        for w in widths {
            if used + w > width { break }
            used += w
            n += 1
        }
        return n
    }
}
