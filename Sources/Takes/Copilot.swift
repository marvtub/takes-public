import AppKit
import SwiftUI

// LinkedIn comment copilot (2026-10-02). An agent finds posts worth a comment and drafts one
// for each; the user approves, edits, gives feedback or declines on the Comments board. Every
// decision is kept, so the next drafts learn from it. Nothing is posted without his yes.
//
// <root>/_library/comments/
//   suggestions/<id>.json   one per suggested comment (written by the takes MCP server and here)
//   lessons.md              the rules in the user's words; every draft run reads it
//   runs/                   the output of each agent run, for when something goes wrong
// The MCP server (mcp/takes_mcp.py, "comment copilot") writes the same format.

struct CommentPost: Decodable, Hashable {
    var url: String?
    var author: String?
    var authorURL: String?
    var headline: String?
    var text: String?
    var posted: String?
    var comments: Int?
    var reactions: Int?
    /// The author's photo, a file next to the suggestion (suggestions/<id>.jpg).
    var photo: String?

    enum CodingKeys: String, CodingKey {
        case url, author, headline, text, posted, comments, reactions, photo
        case authorURL = "author_url"
    }
}

struct CommentDraft: Decodable, Hashable {
    /// The first variant (or the only draft, before variants).
    var text: String
    /// Three different comments for the post (2026-10-02). The user picks one.
    var variants: [String]?
    var at: Date?
    var by: String?
    /// The user's note on this draft. The next draft answers it.
    var feedback: String?
    /// The variant he looked at when he wrote the note.
    var feedbackVariant: Int?

    enum CodingKeys: String, CodingKey {
        case text, variants, at, by, feedback
        case feedbackVariant = "feedback_variant"
    }
}

struct CommentDecision: Decodable, Hashable {
    /// approved, edited, wrong_post, bad_comment
    var kind: String
    var reason: String?
    var note: String?
    /// Which variant he approved (0, 1 or 2).
    var variant: Int?
    var at: Date?
}

struct CommentStat: Decodable, Hashable {
    var at: Date
    var impressions: Int?
    var likes: Int?
    var replies: Int?
}

struct Suggestion: Decodable, Identifiable, Hashable {
    var id: String
    var created: Date
    /// review, feedback (a note not sent yet), redraft, approved, posted, declined
    var status: String
    var post: CommentPost
    var angle: String?
    var drafts: [CommentDraft]
    var final: String?
    var decision: CommentDecision?
    var skipped: Date?
    var posted: PostedComment?
    var stats: [CommentStat]?
    var best: Bool?

    struct PostedComment: Decodable, Hashable {
        var url: String?
        var at: Date?
    }

    /// The text the user approved, else the newest draft.
    var text: String { final ?? drafts.last?.text ?? "" }
    /// The newest draft's variants, or the draft alone.
    var options: [String] { drafts.last.map { $0.variants ?? [$0.text] } ?? [] }
    var latest: CommentStat? { stats?.last }
}

/// The numbers on top of the Posted tab: one entry per day from the first posted comment to today.
struct PostedTally: Equatable {
    struct Day: Equatable, Identifiable {
        var date: Date
        var count: Int
        var total: Int
        var id: Date { date }
    }
    var days: [Day] = []
    var total = 0
    var thisWeek = 0
    var perDay30 = 0.0
    var bestDay = 0
    var streak = 0
    var seen = 0
    var likes = 0
    var replies = 0
    /// Posted comments that have their 48h numbers.
    var measured = 0

    init(_ posted: [Suggestion], now: Date = .now, calendar cal: Calendar = .current) {
        let dates = posted.map { $0.posted?.at ?? $0.created }
        total = posted.count
        for s in posted {
            guard let l = s.latest else { continue }
            measured += 1
            seen += l.impressions ?? 0; likes += l.likes ?? 0; replies += l.replies ?? 0
        }
        guard let first = dates.min() else { return }
        let today = cal.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for d in dates { counts[cal.startOfDay(for: d), default: 0] += 1 }
        // At least two weeks on the axis, so one day is not one fat bar.
        var day = min(cal.startOfDay(for: first), cal.date(byAdding: .day, value: -13, to: today)!)
        var running = 0
        while day <= today {
            let n = counts[day] ?? 0
            running += n
            days.append(Day(date: day, count: n, total: running))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        thisWeek = days.suffix(7).reduce(0) { $0 + $1.count }
        perDay30 = Double(days.suffix(30).reduce(0) { $0 + $1.count }) / Double(min(30, days.count))
        bestDay = days.map(\.count).max() ?? 0
        // Today without a comment yet does not break the streak.
        var tail = days[...]
        if tail.last?.count == 0 { tail = tail.dropLast() }
        streak = tail.reversed().prefix { $0.count > 0 }.count
    }
}

/// Why a draft was declined. The order is the number key on the card (1 to 8).
enum DeclineReason: String, CaseIterable {
    case offVoice = "off-voice", soundsAI = "sounds AI", generic = "too generic", long = "too long"
    case facts = "wrong facts", topic = "not my topic", person = "wrong person", other = "other"

    /// The reasons that fit each kind, as on the phone: "too long" says nothing about a wrong post.
    static func reasons(wrongPost: Bool) -> [DeclineReason] {
        wrongPost ? [.topic, .person, .other] : [.offVoice, .soundsAI, .generic, .long, .facts, .other]
    }
}

@MainActor
final class CopilotStore: ObservableObject {
    @Published private(set) var items: [Suggestion] = []
    let runner = CopilotRunner()
    private(set) var root: URL?
    /// Feedback goes to the Finding chat as a message, so the user watches the redraft there
    /// (2026-10-03; it ran in a hidden run before). AppModel sets it; tests leave it out.
    var askChat: ((String) -> Void)?

    nonisolated static func folder(_ root: URL) -> URL { root.appending(path: "_library/comments") }
    nonisolated static func suggestions(_ root: URL) -> URL { folder(root).appending(path: "suggestions") }
    nonisolated static func lessons(_ root: URL) -> URL { folder(root).appending(path: "lessons.md") }

    /// FSEvents names folders: a suggestion shows up as <root>/_library/comments/suggestions.
    static func matters(_ paths: [String], root: URL) -> Bool {
        let dir = suggestions(root).standardizedFileURL.path
        return paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(dir) }
    }

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    nonisolated(unsafe) static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func scan(_ root: URL) {
        self.root = root
        let found = Self.read(root)
        if found != items { items = found }
        runner.store = self
    }

    /// The same scan off the main thread, for file changes: it decodes every suggestion.
    func scanInBackground(_ root: URL) {
        self.root = root
        runner.store = self
        Task.detached(priority: .utility) {
            let found = Self.read(root)
            await MainActor.run { if found != self.items { self.items = found } }
        }
    }

    nonisolated static func read(_ root: URL) -> [Suggestion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: suggestions(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Suggestion.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    // MARK: Lists

    /// Waiting for the user. A skipped card leaves the line for the Skipped tab (2026-10-02: they
    /// kept coming back) until he sends it back.
    var review: [Suggestion] { items.filter { $0.status == "review" && $0.skipped == nil } }
    /// Skipped, newest skip first.
    var skippedList: [Suggestion] {
        items.filter { $0.status == "review" && $0.skipped != nil }.sorted { $0.skipped! > $1.skipped! }
    }
    var redrafting: [Suggestion] { items.filter { $0.status == "redraft" } }
    /// Notes the user wrote but did not send yet. They wait in the Comments chat as a pill.
    var pendingFeedback: [Suggestion] { items.filter { $0.status == "feedback" } }
    var approved: [Suggestion] { items.filter { $0.status == "approved" } }
    var posted: [Suggestion] { items.filter { $0.status == "posted" }.sorted { ($0.posted?.at ?? $0.created) > ($1.posted?.at ?? $1.created) } }
    var declined: [Suggestion] { items.filter { $0.status == "declined" } }

    // MARK: Decisions

    /// Approve a variant as is, or with the user's edit: then the variant and his text stay side by side.
    func approve(_ s: Suggestion, text: String, variant: Int = 0) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let options = s.options
        let base = options.indices.contains(variant) ? options[variant] : (s.drafts.last?.text ?? "")
        let edited = t != base.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSkipped = nil
        update(s.id) { d in
            d["status"] = "approved"
            d["final"] = t
            var dec: [String: Any] = ["kind": edited ? "edited" : "approved", "at": Self.now()]
            if options.count > 1 { dec["variant"] = variant }
            d["decision"] = dec
            d["skipped"] = nil
        }
    }

    /// `wrongPost`: he would not comment on this post at all. Else the comment was the problem.
    func decline(_ s: Suggestion, wrongPost: Bool, reason: DeclineReason, note: String = "") {
        lastSkipped = nil
        update(s.id) { d in
            d["status"] = "declined"
            var dec: [String: Any] = ["kind": wrongPost ? "wrong_post" : "bad_comment", "reason": reason.rawValue, "at": Self.now()]
            let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { dec["note"] = n }
            d["decision"] = dec
        }
    }

    /// The note goes on the newest draft; the agent writes the next one.
    /// `variant`: the one he looked at when he wrote the note.
    /// A note waits in the Comments chat until the user sends it (2026-10-06: each note started
    /// the agent at once and broke his review flow). `send`: the phone still sends at once.
    func feedback(_ s: Suggestion, note: String, variant: Int? = nil, send: Bool = false) {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        lastSkipped = nil
        update(s.id) { d in
            d["status"] = send ? "redraft" : "feedback"
            var drafts = d["drafts"] as? [[String: Any]] ?? []
            if var last = drafts.popLast() {
                last["feedback"] = n
                if let variant, (last["variants"] as? [Any])?.indices.contains(variant) == true {
                    last["feedback_variant"] = variant
                } else {
                    last["feedback_variant"] = nil
                }
                drafts.append(last)
            }
            d["drafts"] = drafts
        }
        if send { askChat?(CopilotAsk.redraft(s, note: n, variant: variant)) }
    }

    /// Send waiting notes to the chat in one message.
    func sendFeedback(_ list: [Suggestion]) {
        let notes = list.compactMap { s -> (Suggestion, String, Int?)? in
            guard s.status == "feedback", let n = s.drafts.last?.feedback else { return nil }
            return (s, n, s.drafts.last?.feedbackVariant)
        }
        guard !notes.isEmpty else { return }
        for (s, _, _) in notes { update(s.id) { $0["status"] = "redraft" } }
        askChat?(notes.count == 1 ? CopilotAsk.redraft(notes[0].0, note: notes[0].1, variant: notes[0].2)
                                  : CopilotAsk.redraft(notes))
    }

    /// Take a waiting note back: the draft returns to Review as it was.
    func dropFeedback(_ s: Suggestion) {
        update(s.id) { d in
            d["status"] = "review"
            var drafts = d["drafts"] as? [[String: Any]] ?? []
            if var last = drafts.popLast() {
                last["feedback"] = nil
                last["feedback_variant"] = nil
                drafts.append(last)
            }
            d["drafts"] = drafts
        }
    }

    /// The card the user skipped last, so he can take it back.
    @Published private(set) var lastSkipped: String?

    func skip(_ s: Suggestion) {
        update(s.id) { $0["skipped"] = Self.now() }
        lastSkipped = s.id
    }

    /// Undo a skip, or send a skipped card back to Review.
    func unskip(_ id: String) {
        update(id) { $0["skipped"] = nil }
        lastSkipped = nil
    }

    /// An approved comment goes back to review.
    func pullBack(_ s: Suggestion) {
        update(s.id) { d in
            d["status"] = "review"
            d["final"] = nil
            d["decision"] = nil
        }
    }

    /// The user posted it himself (until the routine posts for him).
    func markPosted(_ s: Suggestion, url: String) {
        update(s.id) { d in
            d["status"] = "posted"
            var p: [String: Any] = ["at": Self.now()]
            let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty { p["url"] = u }
            d["posted"] = p
        }
    }

    func toggleBest(_ s: Suggestion) { update(s.id) { $0["best"] = !(s.best ?? false) } }

    /// Edits the file as a dictionary, so fields this app does not know survive.
    private func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        guard let root else { return }
        let url = Self.suggestions(root).appending(path: id + ".json")
        guard let data = try? Data(contentsOf: url),
              var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        change(&d)
        guard let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: url, options: .atomic)
        scan(root)
    }

    nonisolated static func now() -> String { stamp.string(from: Date()) }

    // MARK: Lessons

    func lessons() -> String {
        guard let root else { return "" }
        return (try? String(contentsOf: Self.lessons(root), encoding: .utf8)) ?? ""
    }

    func saveLessons(_ text: String) {
        guard let root else { return }
        try? FileManager.default.createDirectory(at: Self.folder(root), withIntermediateDirectories: true)
        try? text.write(to: Self.lessons(root), atomically: true, encoding: .utf8)
    }
}

// MARK: - The agent run

/// Runs Claude Code headless to redraft after feedback. Nobody watches it, so it gets only the
/// comment tools and Read: no browser, no shell, no file edits. Finding posts and posting run in
/// the Comments chat instead, where the user watches and steers (CopilotAsk).
@MainActor
final class CopilotRunner: ObservableObject {
    enum State: Equatable {
        case idle
        case running(Date)
        case done(String, Date)
        case failed(String, Date)
    }

    @Published private(set) var state: State = .idle
    weak var store: CopilotStore?
    private var process: Process?
    private var redraftWaiting = false
    private var timeout: Task<Void, Never>?

    var running: Bool { if case .running = state { return true } else { return false } }

    static let takesTools = ["get_comment_context", "add_comment_suggestion", "redraft_comment",
                             "list_comment_suggestions"].map { "mcp__takes__" + $0 }

    static func arguments(system: String) -> [String] {
        ["-p", "--output-format", "json", "--permission-mode", "dontAsk", "--tools", "Read",
         "--append-system-prompt", system, "--allowedTools", "Read"] + takesTools
    }

    func redraft() {
        guard !running else { redraftWaiting = true; return }
        start(ask: "Write the new drafts the user asked for.", system: Self.redraftPrompt)
    }

    func stop() { process?.terminate() }

    private func start(ask: String, system: String) {
        guard let claude = Namer.claudePath else {
            state = .failed("Can't find the claude command.", Date())
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = Self.arguments(system: system)
        p.currentDirectoryURL = ClaudeChat.folder
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        // Read on a background queue: a long run fills the pipe buffer otherwise.
        let collected = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData) }
        let log = store?.root.map { CopilotStore.folder($0).appending(path: "runs") }
        p.terminationHandler = { proc in
            output.fileHandleForReading.readabilityHandler = nil
            collected.append(output.fileHandleForReading.readDataToEndOfFile())
            let data = collected.data, status = proc.terminationStatus
            DispatchQueue.main.async { [weak self] in self?.finish(data: data, status: status, log: log) }
        }
        do { try p.run() } catch {
            state = .failed("Couldn't start the chat: \(error.localizedDescription)", Date())
            return
        }
        process = p
        state = .running(Date())
        input.fileHandleForWriting.write(Data(ask.utf8))
        try? input.fileHandleForWriting.close()
        let limit: Duration = .seconds(4 * 60)
        timeout = Task { [weak p] in
            // The suspending clock stops while the Mac sleeps: a closed lid does not use up the 4 minutes.
            try? await Task.sleep(for: limit, clock: .suspending)
            if !Task.isCancelled, p?.isRunning == true { p?.terminate() }
        }
    }

    private func finish(data: Data, status: Int32, log: URL?) {
        timeout?.cancel()
        process = nil
        if let log {
            try? FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
            let name = "\(CopilotStore.now().replacingOccurrences(of: ":", with: "-"))-redraft.json"
            try? data.write(to: log.appending(path: name))
        }
        let (text, error) = Self.result(data)
        if status == 0 && !error {
            state = .done(text ?? "Done.", Date())
        } else {
            state = .failed(text ?? "The chat stopped (exit \(status)).", Date())
        }
        if let root = store?.root { store?.scan(root) }
        // Feedback that came in during this run.
        let again = redraftWaiting
        redraftWaiting = false
        if again, store?.redrafting.isEmpty == false { redraft() }
    }

    /// The last line of Claude's reply from `--output-format json`, and whether it is an error.
    nonisolated static func result(_ data: Data) -> (String?, Bool) {
        let s = String(decoding: data, as: UTF8.self)
        // stderr shares the pipe: the JSON object is the last line that parses.
        for line in s.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let text = (obj["result"] as? String)?
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            return (text, obj["is_error"] as? Bool ?? false)
        }
        let tail = s.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (tail.map(String.init), true)
    }

    static let redraftPrompt = """
        The user gave feedback on LinkedIn comment drafts in his Takes app. Call get_comment_context. \
        For each item in waiting_for_redraft, read the newest draft's variants and feedback note and \
        write 3 new variants that follow it, each a different shape, keeping to lessons.md and the \
        style guide it names. Save each with redraft_comment. Do not use the browser. End with one short line.
        """
}

// MARK: - Asks for the Comments chat

/// Finding posts and posting approved comments run in the Comments board's chat (2026-10-02):
/// The user sees each step as it happens and can steer it with a message. The buttons send a short
/// ask; the how lives in the chat's system prompt (`context`).
enum CopilotAsk {
    static func find(_ count: Int) -> String {
        "Find up to \(count) LinkedIn posts worth a comment and draft one comment for each."
    }

    static func redraft(_ s: Suggestion, note: String, variant: Int?) -> String {
        "Feedback on the draft for \(about(s, variant)): \"\(note)\" Write a new draft that follows it and save it with redraft_comment."
    }

    /// Several notes sent at once from the chat's feedback pill.
    static func redraft(_ notes: [(Suggestion, String, Int?)]) -> String {
        "Feedback on \(notes.count) drafts. Write a new draft for each that follows its note and save it with redraft_comment:\n"
            + notes.map { "- \(about($0.0, $0.2)): \"\($0.1)\"" }.joined(separator: "\n")
    }

    private static func about(_ s: Suggestion, _ variant: Int?) -> String {
        let whose = s.post.author.map { "\($0)'s post" } ?? "the post \(s.post.url ?? s.id)"
        let which = variant.map { " (I looked at variant \($0 + 1))" } ?? ""
        return whose + which
    }

    /// Notes not sent yet go after a typed message, so the chat knows them (as open video comments do).
    static let feedbackMark = "\n\n[Feedback notes I wrote on the Comments board and did not send yet: "

    static func withFeedback(_ text: String, _ pending: [Suggestion]) -> String {
        let notes = pending.compactMap { s -> String? in
            guard let n = s.drafts.last?.feedback else { return nil }
            return "\(s.id) (\(about(s, s.drafts.last?.feedbackVariant))): \"\(n)\""
        }
        guard !notes.isEmpty else { return text }
        return text + feedbackMark + notes.joined(separator: "; ")
            + ". I may mean one of them. Redraft one only when I ask: redraft_comment takes it.]"
    }

    /// The iPhone puts what is on its screen after the message, behind this marker (CopilotFocus).
    /// The chat shows the message without it.
    static func shown(_ text: String) -> String {
        var t = text
        // The open comments sent with a message (ClaudeChat.withComments) are for Claude too.
        for mark in ["\n\n[On screen on my phone: ", ClaudeChat.commentsMark, feedbackMark] {
            if let r = t.range(of: mark, options: .backwards) { t = String(t[..<r.lowerBound]) }
        }
        return t
    }

    static func post(_ count: Int) -> String {
        "Post my \(count) approved \(count == 1 ? "comment" : "comments") on LinkedIn now. This is my yes for each one, exactly as approved."
    }

    static let context = """
        The user is talking to you from the Comments board inside his Takes app: his LinkedIn \
        comment copilot. It shows comment drafts from ~/Movies/Takes/_library/comments/suggestions/ \
        and redraws by itself. Use the takes tools get_comment_context, list_comment_suggestions, \
        add_comment_suggestion, redraft_comment and set_comment_posted; lessons.md in that folder \
        holds his rules. He reads your replies in a narrow panel: keep them short, no tables, no \
        headings. He watches while you work: before each step write one short line on what you do \
        next (for example "Reading Justin Welsh's recent posts"). A message that starts with "I \
        interrupted you" steers the task you were on: follow it, then go on with that task.

        A message from his phone ends with "[On screen on my phone: the draft for …]": the draft \
        and variant he looks at. Read what he says to decide what it is about. About this \
        draft ("make it shorter", "I like the second one"): write 3 new variants with \
        redraft_comment. About the drafts in general ("all of these", "every draft", his voice, a \
        habit he sees across them): redraft every draft in review with redraft_comment, and if it \
        is a lasting rule, add it to lessons.md. A question: answer it. Say in one line which you did.

        \(ClaudeChat.browserRules)

        Finding posts (when he asks for drafts): four scouts read LinkedIn in parallel, you draft.
        1. Call get_comment_context. Read lessons, rules, targets and examples (edited_by_user \
        shows what he changes: study it most). Read the style guide file it names.
        2. If waiting_for_redraft lists drafts, first write a new draft for each that follows its \
        feedback note, and save it with redraft_comment.
        3. Start every scout in scouts at once: one Agent call each, all in one message, \
        subagent_type general-purpose, model sonnet, descriptions "Feed scout", "List scout", \
        "Search scout" and "Commenter scout". Each prompt is exactly its brief from scouts in the \
        context. Say "Four scouts are reading LinkedIn" first. You do not use the browser at all \
        while they run, and you never touch their tabs.
        4. Merge what they return. Drop duplicates and any post that breaks a rule. Rank the rest: \
        what the user can add first (a real story, counterpoint or question beats agreement), then \
        how well the author fits, then fresh posts with few comments. Draft only the best ones, up \
        to the number he asked for: a weak post is not worth a draft, even if that means fewer.
        5. For each post you draft: one angle line (what the user can add), then 3 variants of the \
        comment, following lessons.md and the style guide. Each variant a different shape (a short \
        story from his work, a pointed question, a counterpoint, a concrete tip) and length; \
        variant_picks shows which shapes he picks. Save it with add_comment_suggestion: the post's \
        own URL, post_text exactly as the scout returned it (its empty lines too), author_photo from the scout, and source "feed", "list", "search" or "commenters" (the scout that found it). If the slop gate refuses \
        a variant, rewrite it once; refused again, drop the post.
        6. End with one short line: how many drafts you added from how many candidates, anything \
        that stopped a scout, and the scouts' new_targets and quiet people (names only) for his \
        target list. Never edit the target list yourself.

        Posting (only when he asks in this chat, for example with the Post approved button): his \
        message is the yes for the comments that are approved at that moment, exactly as \
        approved, and for nothing else. Never post a draft that is not approved. Another chat may \
        be finding posts in its own tab at the same time: leave tabs you did not create alone.
        1. list_comment_suggestions with status approved. Post each one's text character for \
        character: never add a mention, tag, hashtag, emoji or sign-off. Keep its line breaks.
        2. Open the post URL. Check it is the same post (same author). Read the comments first: \
        if his comment is already there, do not post it again, only record it (step 4).
        3. Open the post's comment box, put the text in, read the box back and compare it with \
        the approved text, then click the box's Comment button once. Never click it twice: if you \
        are not sure it went through, reload the post and look before you do anything else.
        4. When the comment shows under the post, call set_comment_posted with the suggestion id \
        and the comment's link: the post URL with ?commentUrn= and the comment's urn:li:comment \
        from the page, else the post URL.
        5. Wait 60 to 120 seconds between two comments. Post at most 15 a day: count the posted \
        ones from the last 24 hours. Stop at the first error message LinkedIn shows.
        6. End with one line per comment: posted, or why not.
        """
}

/// Bytes from a pipe, gathered off the main thread.
final class OutputBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
