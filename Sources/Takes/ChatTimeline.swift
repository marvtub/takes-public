import SwiftUI

// The steps of a chat turn as a timeline (2026-10-12, after a "thinking" design the user liked):
// one plain line per step on a thin rail. The running step has an arc that orbits its glyph and a
// shimmer on its words; a finished step leaves a grey dot. The words change from "Reading" to
// "Read" when the step ends. Spec checked frame by frame against the reference video: orbit
// 0.75 s a turn, shimmer 1.2 s sweep + 0.8 s rest, rows arrive from a 4 px blur in 0.35 s.

/// One row of the timeline: a tool call, or a run of the same tool in a row ("Read 3 files").
struct ChatStep: Identifiable, Equatable {
    let id: UUID
    /// The tool, as the chat line names it: "Read", "Bash", "get session".
    let tool: String
    /// What each call was about: file names, search words, commands.
    var details: [String]
    var count: Int
    var done: Bool
    var failed: Bool
    /// A magnifier instead of a dot: the step looks for something.
    var search: Bool
    var run: String
    var finished: String
    /// The small cards under the words. Only a run of calls shows them: one call names its file.
    var chips: [String]
}

enum StepWords {
    /// Calls of these tools in a row join into one row.
    private static let joins: Set<String> = ["Read", "Edit", "MultiEdit", "Write", "Grep", "Glob", "WebSearch", "WebFetch"]
    private static let searches: Set<String> = ["Grep", "Glob", "WebSearch", "ToolSearch", "find words", "list broll", "find"]

    static func steps(_ tools: [ChatMessage]) -> [ChatStep] {
        var out: [ChatStep] = []
        var calls: [(ChatMessage, String, String?)] = []
        func flush() {
            guard let first = calls.first else { return }
            let tool = first.1
            let details = calls.compactMap(\.2)
            let w = words(tool, details: details, count: calls.count)
            let done = calls.allSatisfy { $0.0.done }
            out.append(ChatStep(
                id: first.0.id, tool: tool, details: details, count: calls.count, done: done,
                failed: done && calls.contains { $0.0.failed == true },
                search: searches.contains(tool) || tool.hasPrefix("search"),
                run: w.run, finished: w.done,
                chips: calls.count > 1 || (tool == "Bash" && w.raw) ? details : []))
            calls = []
        }
        for m in tools {
            if m.isActionNote {
                flush()
                out.append(ChatStep(id: m.id, tool: "activity", details: [], count: 1, done: m.done,
                                    failed: m.failed == true, search: false, run: m.text, finished: m.text, chips: []))
                continue
            }
            let (tool, detail) = split(m.text)
            // A failed call stands alone: it is the dead end, not one of the run.
            if let last = calls.last, last.1 == tool, m.failed != true, last.0.failed != true,
               joins.contains(tool) || (detail == nil && last.2 == nil) {
                calls.append((m, tool, detail))
            } else {
                flush()
                calls.append((m, tool, detail))
            }
        }
        flush()
        return out
    }

    /// "Bash · Cut the silences" → ("Bash", "Cut the silences"); "get comments" → ("get comments", nil).
    static func split(_ line: String) -> (String, String?) {
        let parts = line.components(separatedBy: " · ")
        let tool = parts[0].replacingOccurrences(of: "_", with: " ")
        let detail = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
        return (tool, detail?.isEmpty == true ? nil : detail)
    }

    /// The words while the step runs and once it is done. `raw`: a Bash line that is the command
    /// itself, not a description; it shows as a chip.
    static func words(_ tool: String, details: [String], count n: Int) -> (run: String, done: String, raw: Bool) {
        let d = details.first
        let q = d.map { "“\($0)”" }
        switch tool {
        case "Read":
            return n > 1 ? ("Reading \(n) files", "Read \(n) files", false) : ("Reading \(d ?? "a file")", "Read \(d ?? "a file")", false)
        case "Edit", "MultiEdit":
            return n > 1 ? ("Editing \(n) files", "Edited \(n) files", false) : ("Editing \(d ?? "a file")", "Edited \(d ?? "a file")", false)
        case "Write":
            return n > 1 ? ("Writing \(n) files", "Wrote \(n) files", false) : ("Writing \(d ?? "a file")", "Wrote \(d ?? "a file")", false)
        case "Grep", "Glob":
            return n > 1 || q == nil ? ("Searching the files", "Searched the files", false) : ("Searching for \(q!)", "Searched for \(q!)", false)
        case "WebSearch":
            return n > 1 || q == nil ? ("Searching the web", "Searched the web", false) : ("Searching the web for \(q!)", "Searched the web for \(q!)", false)
        case "WebFetch":
            return n > 1 ? ("Reading \(n) web pages", "Read \(n) web pages", false) : ("Reading a web page", "Read a web page", false)
        case "Bash":
            guard let d else { return ("Running a command", "Ran a command", false) }
            guard let first = d.first, first.isUppercase, first.isLetter else { return ("Running a command", "Ran a command", true) }
            return (inflect(d, gerund: true), inflect(d, gerund: false), false)
        case "Agent", "Task":
            return ("A helper is on it: \(d ?? "a side task")", "Helper finished: \(d ?? "a side task")", false)
        case "Skill":
            return ("Using the \(d ?? "a") skill", "Used the \(d ?? "a") skill", false)
        case "TodoWrite":
            return ("Updating the plan", "Updated the plan", false)
        case "ToolSearch":
            return ("Loading tools", "Loaded tools", false)
        default:
            break
        }
        let more = n > 1 ? " · \(n)" : ""
        if let w = takes[tool] { return (w.0 + more, w.1 + more, false) }
        // Any other tool: "set post hooks" → "Setting the post hooks" / "Set the post hooks".
        let parts = tool.split(separator: " ").map(String.init)
        guard let verb = parts.first, verbs.contains(verb) else {
            let t = tool.prefix(1).uppercased() + tool.dropFirst()
            return (t + more, t + more, false)
        }
        let rest = parts.dropFirst().joined(separator: " ")
        let object = rest.isEmpty ? "" : " the \(rest)"
        return (inflect(verb.capitalized, gerund: true) + object + more,
                inflect(verb.capitalized, gerund: false) + object + more, false)
    }

    /// Takes' own tools and the browser's, in the user's words.
    private static let takes: [String: (String, String)] = [
        "get session": ("Opening the session", "Opened the session"),
        "get rules": ("Reading your rules", "Read your rules"),
        "get library": ("Opening the library", "Opened the library"),
        "list broll": ("Looking through your b-roll", "Looked through your b-roll"),
        "find words": ("Finding the words in the take", "Found the words in the take"),
        "make image": ("Drawing an image", "Drew an image"),
        "set storyboard": ("Sketching the storyboard", "Sketched the storyboard"),
        "set post": ("Writing the post", "Wrote the post"),
        "create post variants": ("Drafting post versions", "Drafted post versions"),
        "set post hooks": ("Writing hooks", "Wrote hooks"),
        "post history": ("Reading your past posts", "Read your past posts"),
        "get comments": ("Reading the comments", "Read the comments"),
        "next path": ("Picking a file name", "Picked a file name"),
        "computer": ("Working in Chrome", "Worked in Chrome"),
        "navigate": ("Opening a page", "Opened a page"),
        "read page": ("Reading the page", "Read the page"),
        "get page text": ("Reading the page", "Read the page"),
        "javascript tool": ("Running a script on the page", "Ran a script on the page"),
        "tabs context mcp": ("Checking the tabs", "Checked the tabs"),
        "tabs create mcp": ("Opening a tab", "Opened a tab"),
    ]

    private static let verbs: Set<String> = [
        "get", "set", "list", "make", "add", "find", "create", "update", "delete", "read", "search",
        "write", "draw", "send", "import", "export", "render", "check", "save", "move", "remove",
        "open", "start", "stop", "run", "cut", "edit", "mix", "post", "schedule", "fix", "change",
    ]

    private static let irregular: [String: String] = [
        "cut": "cut", "run": "ran", "make": "made", "find": "found", "get": "got", "set": "set",
        "read": "read", "write": "wrote", "build": "built", "put": "put", "send": "sent", "take": "took",
        "draw": "drew", "give": "gave", "see": "saw", "keep": "kept", "split": "split", "do": "did",
        "let": "let", "hit": "hit", "go": "went", "pull": "pulled", "fix": "fixed", "mix": "mixed",
    ]
    private static let doubles: Set<String> = [
        "cut", "run", "get", "set", "put", "stop", "plan", "trim", "drop", "ship", "chop", "skip",
        "tap", "map", "swap", "grab", "scan", "pin", "wrap", "split", "commit", "submit", "hit",
        "let", "dig", "log", "tag", "zip", "begin", "clip", "crop", "flip", "snap", "strip", "prep",
    ]

    /// "Cut the silences" → "Cutting the silences" or "Cut the silences"; "List files" → "Listing
    /// files" or "Listed files". Only the first word changes, and it keeps its capital.
    static func inflect(_ line: String, gerund: Bool) -> String {
        let word = line.prefix { $0.isLetter }
        let rest = line.dropFirst(word.count)
        let w = word.lowercased()
        guard w.count > 1 else { return line }
        var out: String
        if gerund {
            if w.hasSuffix("ie") { out = String(w.dropLast(2)) + "ying" }
            else if w.hasSuffix("e"), !w.hasSuffix("ee"), !w.hasSuffix("ye"), !w.hasSuffix("oe") { out = String(w.dropLast()) + "ing" }
            else if doubles.contains(w) { out = w + String(w.last!) + "ing" }
            else { out = w + "ing" }
        } else if let past = irregular[w] {
            out = past
        } else if w.hasSuffix("e") {
            out = w + "d"
        } else if w.hasSuffix("y"), let c = w.dropLast().last, !"aeiou".contains(c) {
            out = String(w.dropLast()) + "ied"
        } else if doubles.contains(w) {
            out = w + String(w.last!) + "ed"
        } else {
            out = w + "ed"
        }
        if word.first?.isUppercase == true { out = out.prefix(1).uppercased() + out.dropFirst() }
        return out + rest
    }

    /// "12s", "1m 12s".
    static func time(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// A run of tool calls as a timeline. While Takes adds to it: "Working 12s" with a shimmer, every
/// step shown. Once done: "Worked for 12s · 5 steps". It stays open until the user writes again,
/// then folds to that one line; a click opens or shuts it.
struct StepTimeline: View {
    let tools: [ChatMessage]
    /// Takes is still adding to this run.
    let active: Bool
    /// No message from the user after it.
    let latest: Bool
    /// When the next message came: the end of the run.
    let end: Date?
    @State private var open: Bool?
    /// The run ended while on screen: the blue check pops in. An old one shows it still.
    @State private var justFinished = false

    private var activity: Bool { tools.contains(where: \.isActionNote) }

    static func defaultOpen(_ tools: [ChatMessage], active: Bool, latest: Bool) -> Bool {
        let activity = tools.contains(where: \.isActionNote)
        return active || tools.contains { !$0.done } || (activity ? tools.contains { $0.failed == true } : latest)
    }

    var body: some View {
        let working = active || tools.contains { !$0.done }
        let shown = open ?? Self.defaultOpen(tools, active: active, latest: latest)
        VStack(alignment: .leading, spacing: 4) {
            header(working: working, shown: shown)
            if shown {
                let steps = StepWords.steps(tools)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in
                        StepRow(step: step, live: working).transition(.stepIn)
                    }
                    if !working {
                        FinishRow(pop: justFinished).transition(.stepIn)
                    }
                }
                .background(alignment: .leading) {
                    Rectangle().fill(Theme.faint.opacity(0.45)).frame(width: 1)
                        .padding(.vertical, 12).padding(.leading, 8.5)
                }
                .transition(.stepIn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.35), value: tools.count)
        .animation(.easeOut(duration: 0.26), value: tools.map(\.done))
        .animation(.easeOut(duration: 0.26), value: working)
        .animation(Theme.motion, value: shown)
        .onChange(of: working) { was, now in if was && !now { justFinished = true } }
    }

    private func header(working: Bool, shown: Bool) -> some View {
        Button { open = !shown } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(shown ? 90 : 0))
                    .frame(width: 18, height: 18)
                if working {
                    Group {
                        if let start = tools.first?.at {
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Text("Working \(StepWords.time(ctx.date.timeIntervalSince(start)))")
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Working")
                        }
                    }
                    .font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                    .overlay { LayerShimmer(color: Theme.raised) }
                    .transition(.labelSwap)
                } else {
                    HStack(spacing: 0) {
                        Text(doneTitle).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.muted)
                        Text(" · \(tools.count) \(activity ? "update" : "step")\(tools.count == 1 ? "" : "s")")
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                    }
                    .transition(.labelSwap)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shown ? "Hide the details" : "Show every update and step")
    }

    private var doneTitle: String {
        if activity { return "Activity" }
        guard let start = tools.first?.at, let stop = end ?? tools.last?.at else { return "Worked" }
        return "Worked for \(StepWords.time(stop.timeIntervalSince(start)))"
    }
}

private struct StepRow: View {
    let step: ChatStep
    let live: Bool

    var body: some View {
        let running = !step.done
        let label = running ? step.run : step.failed ? "Dead end: \(step.finished)" : step.finished
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StepIcon(step: step).frame(width: 18, height: 18)
                Text(label)
                    .font(Theme.sans(12.5, running ? .medium : .regular))
                    .foregroundStyle(running ? Theme.ink : step.failed ? Theme.faint : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .overlay { if running { LayerShimmer(color: Theme.raised) } }
                    .id(label)
                    .transition(.labelSwap)
            }
            .frame(height: 24)
            if !step.chips.isEmpty {
                StepChips(chips: step.chips, live: live).padding(.leading, 26).padding(.bottom, 4)
            }
        }
        .help(step.details.count == 1 ? step.details[0] : "")
    }
}

/// The running glyph with its orbiting arc, or what the step left: a dot, a grey magnifier, an ×.
private struct StepIcon: View {
    let step: ChatStep

    var body: some View {
        ZStack {
            // Hides the rail behind the glyph: a small gap round a dot, the whole orbit round a running one.
            Circle().fill(Theme.raised).frame(width: step.done ? 11 : 16, height: step.done ? 11 : 16)
            if !step.done {
                glyph(Theme.ink)
                LayerSpinner(color: Theme.ink, lineWidth: 1.5, inset: 1.25, length: 0.47, duration: 0.75)
                    .transition(.opacity)
            } else if step.failed {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.faint)
                    .transition(.settle)
            } else if step.search {
                glyph(Theme.faint).transition(.settle)
            } else {
                Circle().fill(Theme.faint).frame(width: 5, height: 5).transition(.settle)
            }
        }
    }

    @ViewBuilder private func glyph(_ color: Color) -> some View {
        if step.search {
            Image(systemName: "magnifyingglass").font(.system(size: 7.5, weight: .bold)).foregroundStyle(color)
        } else {
            Circle().fill(color).frame(width: 5, height: 5)
        }
    }
}

/// File names, search words or commands, a card each. They come in one after the other.
private struct StepChips: View {
    let chips: [String]
    let live: Bool
    static let shownMax = 3

    /// As many chips as fit: a narrow chat (360 pt) with long file names shows fewer, never runs over.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(Self.shownMax)
            row(2)
            row(1)
        }
    }

    private func row(_ n: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(chips.prefix(n).enumerated()), id: \.offset) { i, c in
                StepChip(text: c, index: i, live: live)
            }
            if chips.count > n {
                StepChip(text: "+\(chips.count - n) more", index: n, live: live, plain: true)
            }
        }
    }
}

private struct StepChip: View {
    let text: String
    let index: Int
    let live: Bool
    var plain = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let on = shown || !live || still
        HStack(spacing: 5) {
            if !plain, let badge = Self.badge(text) {
                Text(badge).font(Theme.sans(8.5, .semibold)).foregroundStyle(Theme.accentInk)
            }
            Text(text).font(Theme.sans(11)).foregroundStyle(plain ? Theme.faint : Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(plain ? .clear : Theme.hover, in: Capsule())
        .frame(maxWidth: 170, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(on ? 1 : 0)
        .scaleEffect(on ? 1 : 0.8, anchor: .leading)
        .offset(x: on ? 0 : -4)
        .blur(radius: on ? 0 : 3)
        .onAppear {
            guard live, !shown else { return }
            withAnimation(.easeOut(duration: 0.35).delay(0.2 + Double(index) * 0.1)) { shown = true }
        }
    }

    /// "take-03.mov" → "MOV".
    static func badge(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        let known = ["mov", "mp4", "m4a", "wav", "mp3", "md", "txt", "json", "srt", "png", "jpg", "jpeg", "html", "swift", "py"]
        return known.contains(ext) ? (ext == "jpeg" ? "JPG" : ext.uppercased()) : nil
    }
}

/// The end of the rail: the one blue mark in the timeline.
private struct FinishRow: View {
    let pop: Bool
    @State private var shown = false

    var body: some View {
        let on = shown || !pop
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.raised).frame(width: 16, height: 16)
                Circle().fill(Theme.accent).frame(width: 14, height: 14)
                    .scaleEffect(on ? 1 : 0.01)
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.6)
            }
            .frame(width: 18, height: 18)
            Text("Finished").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
        }
        .frame(height: 24)
        .onAppear {
            guard pop, !shown else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.08)) { shown = true }
        }
    }
}

/// Opacity, blur and a small drop, as a row or a label arrives.
private struct BlurIn: ViewModifier {
    let on: Bool
    var y: CGFloat = 0
    var blur: CGFloat = 4
    var from: Double = 0

    func body(content: Content) -> some View {
        content.opacity(on ? from : 1).blur(radius: on ? blur : 0).offset(y: on ? y : 0)
    }
}

private extension AnyTransition {
    /// A new row: from a 4 px blur, 6 px above.
    static var stepIn: AnyTransition {
        .asymmetric(insertion: .modifier(active: BlurIn(on: true, y: -6), identity: BlurIn(on: false, y: -6)),
                    removal: .opacity)
    }
    /// New words in a row: a short blur, no move.
    static var labelSwap: AnyTransition {
        .asymmetric(insertion: .modifier(active: BlurIn(on: true, blur: 3, from: 0.2), identity: BlurIn(on: false, blur: 3, from: 0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
    /// The dot a step leaves: grows in from half size.
    static var settle: AnyTransition { .scale(scale: 0.5).combined(with: .opacity) }
}
