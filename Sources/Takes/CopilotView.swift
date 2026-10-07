import AppKit
import Charts
import SwiftUI

// The Comments board (2026-10-02): review the agent's comment drafts one card at a time, then
// see what waits to be posted, what went live, and what the agent learns from.

/// The sidebar way into the board, with how many drafts wait.
struct CommentsRow: View {
    @Environment(AppModel.self) var app
    @ObservedObject var store: CopilotStore
    @ObservedObject var runner: CopilotRunner
    var chat: ClaudeChat
    var post: ClaudeChat
    let selected: Bool
    let open: () -> Void

    var body: some View {
        SideRow(selected: selected) {
            NavLabel(icon: "text.bubble", title: "Comments", key: "⇧⌘M", active: selected) {
                if runner.running || chat.running || post.running {
                    ProgressView().controlSize(.mini)
                } else if !store.review.isEmpty {
                    Text("\(store.review.count)").font(Theme.mono(10.5, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(Theme.accent, in: Capsule())
                        .help("Comment drafts waiting for you")
                }
            }
        }
        .onTapGesture(perform: open)
        .help("LinkedIn comments the agent drafted for you (⇧⌘M)")
        .onAppear { store.scan(app.library.root) }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { n in
            if let paths = n.object as? [String], CopilotStore.matters(paths, root: app.library.root) {
                store.scanInBackground(app.library.root)
            }
        }
    }
}

/// The board with its chat: the panel shows the Finding or the Posting chat.
struct CommentsBoard: View {
    var hub: ChatHub
    let store: CopilotStore
    let root: URL

    var body: some View {
        ChatSlot(hub: hub, target: ChatTarget.comments(hub)) {
            CommentsView(store: store, runner: store.runner, chat: hub.comments, post: hub.commentsPost, hub: hub, root: root)
        }
        .overlay(alignment: .bottomTrailing) {
            BoardChatCorner(hub: hub, comments: true).padding(18)
        }
    }
}

struct CommentsView: View {
    @ObservedObject var store: CopilotStore
    @ObservedObject var runner: CopilotRunner
    /// Finding posts runs in `chat`, posting in `post`: the board's two chats, where the user
    /// watches and steers. Both can run at once.
    var chat: ClaudeChat
    var post: ClaudeChat
    var hub: ChatHub
    let root: URL
    @AppStorage("copilotTab") private var tab = "review"
    @AppStorage("copilotDrafts") private var drafts = 5
    /// The card on the Review tab. Approve or skip takes the card out, so the same place then
    /// shows the next one.
    @State private var reviewAt = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rule()
            Group {
                switch tab {
                case "approved": ApprovedList(store: store, busy: post.running, review: { tab = "review" }) { ask(CopilotAsk.post(store.approved.count), in: post, lane: "post") }
                case "posted": PostedList(store: store, approved: { tab = "approved" })
                case "skipped": SkippedList(store: store)
                case "library": CopilotLibrary(store: store)
                default: reviewPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .background(Theme.paper)
        .animation(Theme.motion, value: tab)
        .onAppear { store.scan(root) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // The widest set of tabs that fits; the rest go in the More menu.
            ViewThatFits(in: .horizontal) {
                tabs(shown: 5)
                tabs(shown: 3)
                tabs(shown: 2)
                tabs(shown: 1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            RunStatus(runner: runner)
            if post.running { working("Posting", lane: "post", post) }
            if chat.running { working("Finding", lane: "find", chat) } else { runButton }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var allTabs: [(id: String, title: String, count: Int?)] {
        [("review", "Review", store.review.count), ("approved", "Approved", store.approved.count),
         ("posted", "Posted", store.posted.count), ("skipped", "Skipped", store.skippedList.count),
         ("library", "Library", nil)]
    }

    /// A segmented track: the first `shown` tabs as segments, the others in a More menu. A tab
    /// picked from the menu takes the last segment, so the open tab always shows.
    private func tabs(shown: Int) -> some View {
        var visible = Array(allTabs.prefix(shown))
        let rest = Array(allTabs.dropFirst(shown))
        if let open = rest.first(where: { $0.id == tab }) { visible[visible.count - 1] = open }
        let hidden = allTabs.filter { t in !visible.contains { $0.id == t.id } }
        return HStack(spacing: 2) {
            ForEach(visible, id: \.id) { t in segment(t.id, t.title, t.count) }
            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden, id: \.id) { t in
                        Button { tab = t.id } label: {
                            Text(t.count.map { $0 > 0 ? "\(t.title)  \($0)" : t.title } ?? t.title)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 26)
                }
                .menuStyle(.button).buttonStyle(IconButtonStyle()).menuIndicator(.hidden).fixedSize()
                .help("More: \(hidden.map(\.title).joined(separator: ", "))")
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.hover))
        .fixedSize()
    }

    @Namespace private var tabPill

    private func segment(_ id: String, _ title: String, _ count: Int?) -> some View {
        let on = tab == id
        return Button { tab = id } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)").font(Theme.mono(10.5, .semibold))
                        .foregroundStyle(on ? Theme.accentInk : Theme.faint)
                }
            }
            .font(Theme.sans(12.5, on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.ink : Theme.muted)
            .padding(.horizontal, 11).frame(height: 26)
            .background {
                if on {
                    Capsule().fill(Theme.paper)
                        .shadow(color: Theme.ink.opacity(0.08), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "pill", in: tabPill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// One capsule: "Run now" on the left, how many posts a run looks for on the right.
    private var runButton: some View {
        HStack(spacing: 0) {
            Button { ask(CopilotAsk.find(drafts), in: chat, lane: "find") } label: {
                Label("Run now", systemImage: "play.fill").labelStyle(RunLabel())
                    .padding(.leading, 14).padding(.trailing, 10).frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Find posts in a background Chrome tab and draft comments. You watch it in the chat. Nothing gets posted.")
            Rectangle().fill(Theme.paper.opacity(0.35)).frame(width: 1, height: 16)
            Menu {
                Picker("Posts per run", selection: $drafts) {
                    ForEach([3, 5, 7, 10, 15], id: \.self) { Text("\($0) posts").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Text("\(drafts)").font(Theme.mono(11.5, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .padding(.leading, 9).padding(.trailing, 12).frame(height: 30)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("How many posts a run looks for")
        }
        .font(Theme.sans(13, .semibold))
        .foregroundStyle(Theme.paper)
        .background(Capsule().fill(Theme.accent))
        .fixedSize()
    }

    /// A new conversation for each run, so the chat shows only this run (the old one goes to
    /// the history under the clock).
    private func ask(_ text: String, in c: ClaudeChat, lane: String) {
        guard !c.running else { return }
        c.reset()
        c.send(text, title: "Comments", onStage: nil)
        hub.commentsLane = lane
        hub.open = true
    }

    /// A chat at work: a click shows it, Stop stops it.
    private func working(_ title: String, lane: String, _ c: ClaudeChat) -> some View {
        HStack(spacing: 6) {
            Button { hub.commentsLane = lane; hub.open = true } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(title) · watch")
                }
            }
            .buttonStyle(BracketButtonStyle())
            .help("Open this chat to see each step. Type there to steer it.")
            Button("Stop") { c.stop() }.buttonStyle(AccentButtonStyle(kind: .quiet))
        }
    }

    // MARK: Review

    @ViewBuilder private var reviewPane: some View {
        let list = store.review
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !store.pendingFeedback.isEmpty {
                    HStack(spacing: 8) {
                        Label("\(store.pendingFeedback.count) \(store.pendingFeedback.count == 1 ? "note waits" : "notes wait") in the Comments chat",
                              systemImage: "text.bubble")
                            .font(Theme.sans(12, .medium)).foregroundStyle(Theme.accentInk)
                        Spacer()
                        Button("Open chat") { hub.commentsLane = "find"; hub.open = true }
                            .buttonStyle(BracketButtonStyle())
                        Button("Send now") { store.sendFeedback(store.pendingFeedback) }
                            .buttonStyle(BracketButtonStyle())
                            .help("Takes writes a new draft for each note")
                    }
                }
                if !store.redrafting.isEmpty {
                    Label("\(store.redrafting.count) new \(store.redrafting.count == 1 ? "draft" : "drafts") on the way after your feedback",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.sans(12, .medium)).foregroundStyle(Theme.accentInk)
                }
                if let id = store.lastSkipped, let skipped = store.skippedList.first(where: { $0.id == id }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward").foregroundStyle(Theme.muted)
                        Text("Skipped \(skipped.post.author ?? "a post"). It waits in the Skipped tab.")
                            .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Undo") { store.unskip(id) }.buttonStyle(BracketButtonStyle())
                    }
                    .transition(.opacity)
                }
                if !list.isEmpty {
                    let at = min(reviewAt, list.count - 1), s = list[at]
                    ReviewCard(store: store, hub: hub, suggestion: s, position: at + 1, total: list.count,
                               go: { by in reviewAt = (at + by + list.count) % list.count })
                        .id("\(s.id)#\(s.drafts.count)")
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                } else {
                    ReviewEmpty(finding: chat.running, drafts: drafts, posted: store.posted.count,
                                run: { ask(CopilotAsk.find(drafts), in: chat, lane: "find") },
                                watch: { hub.commentsLane = "find"; hub.open = true })
                        .padding(.top, 36)
                }
            }
            .frame(maxWidth: 720 * TextSize.shared.factor, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .animation(Theme.spring, value: list.isEmpty ? nil : list[min(reviewAt, list.count - 1)].id)
        }
    }
}

/// Nothing to review (2026-10-04): three comment cards fanned out, what a run does in three steps,
/// and Run now. While Takes finds posts, the cards float, the first step turns on, and the button
/// opens the chat.
struct ReviewEmpty: View {
    let finding: Bool
    let drafts: Int
    var posted = 0
    let run: () -> Void
    let watch: () -> Void
    @State private var lift = false

    var body: some View {
        VStack(spacing: 0) {
            cards.padding(.bottom, 28)
            Text(finding ? "Takes is reading LinkedIn" : "No drafts to review")
                .font(Theme.display(24)).foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
            Text(finding
                 ? "It looks at your target list and your feed. Each good post gets a draft, and the drafts come here one by one."
                 : "Run now finds up to \(drafts) posts from your target list and your feed, and drafts a comment for each.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 8)
            steps.padding(.top, 26)
            Group {
                if finding {
                    Button(action: watch) {
                        Label("Watch it work", systemImage: "eye").font(Theme.sans(13, .semibold))
                            .padding(.horizontal, 18).frame(height: 34)
                            .background(Capsule().fill(Theme.hover))
                            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .help("Open the Finding chat. Type there to steer it.")
                } else {
                    Button(action: run) {
                        Label("Run now", systemImage: "play.fill").font(Theme.sans(13, .semibold))
                            .foregroundStyle(Theme.paper)
                            .padding(.horizontal, 20).frame(height: 34)
                            .background(Capsule().fill(Theme.accent))
                            .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
                            .contentShape(Capsule())
                    }
                    .help("Find posts in a background Chrome tab and draft comments. Nothing gets posted.")
                }
            }
            .buttonStyle(PressStyle())
            .padding(.top, 26)
            Label(posted > 0 ? "Nothing goes live until you approve it · \(posted) posted so far" : "Nothing goes live until you approve it",
                  systemImage: "lock")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: finding)
        .onChange(of: finding, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { lift = true }
            } else {
                withAnimation(Theme.spring) { lift = false }
            }
        }
    }

    private var cards: some View {
        EmptyCards(badge: finding ? nil : "checkmark", tint: Theme.live, lift: lift, glow: finding ? 0.22 : 0.14)
    }

    // MARK: The steps

    private var steps: some View {
        HStack(spacing: 0) {
            step(1, "magnifyingglass", "Find posts", "Your list and feed", on: finding)
            arrow
            step(2, "pencil.line", "Draft a comment", "In your voice", on: false)
            arrow
            step(3, "checkmark.seal", "You approve", "Edit, skip, or post", on: false)
        }
        .fixedSize()
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.faint.opacity(0.7)).padding(.horizontal, 10).padding(.bottom, 26)
    }

    private func step(_ n: Int, _ icon: String, _ title: String, _ detail: String, on: Bool) -> some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Theme.accent : Theme.accentSoft).frame(width: 34, height: 34)
                if on {
                    ProgressView().controlSize(.small).tint(Theme.paper)
                } else {
                    Image(systemName: icon).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.accentInk)
                }
            }
            VStack(spacing: 2) {
                Text(title).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.sans(11)).foregroundStyle(Theme.faint)
            }
        }
        .frame(width: 128)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n): \(title). \(detail)")
    }
}

/// Three comment cards fanned out over a soft glow, with a badge on the front one: the picture on
/// every empty tab of the board.
struct EmptyCards: View {
    var badge: String?
    var tint: Color = Theme.live
    var lift = false
    var glow: Double = 0.14

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.accent.opacity(glow), .clear], center: .center, startRadius: 0, endRadius: 170)
                .frame(width: 380, height: 200).scaleEffect(x: 1, y: 0.55).offset(y: 34)
            card(lines: [0.7, 0.5]).rotationEffect(.degrees(-9)).offset(x: -64, y: lift ? 2 : 10).opacity(0.6)
            card(lines: [0.8, 0.45]).rotationEffect(.degrees(8)).offset(x: 64, y: lift ? -2 : 8).opacity(0.75)
            card(lines: [0.9, 0.75, 0.4])
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Image(systemName: badge).font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Circle().fill(tint))
                            .shadow(color: tint.opacity(0.4), radius: 6, y: 2)
                            .offset(x: 8, y: 8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .offset(y: lift ? -8 : 0)
                .shadow(color: Theme.shadow, radius: 18, y: 10)
        }
        .frame(height: 150)
        .accessibilityHidden(true)
    }

    private func card(lines: [CGFloat]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle().fill(LinkedIn.blue.opacity(0.8)).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Theme.ink.opacity(0.55)).frame(width: 58, height: 5)
                    Capsule().fill(Theme.faint.opacity(0.5)).frame(width: 38, height: 4)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                Capsule().fill(Theme.faint.opacity(0.35)).frame(width: 136 * w, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 164, height: 112, alignment: .topLeading)
        .background(Theme.raised, in: shape)
        .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

/// An empty tab of the board: the cards, a title, one line on what comes here, and a way on.
struct BoardEmpty: View {
    let badge: String
    var tint: Color = Theme.accent
    let title: String
    let text: String
    var action: (title: String, icon: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            EmptyCards(badge: badge, tint: tint).padding(.bottom, 28)
            Text(title).font(Theme.display(24)).foregroundStyle(Theme.ink)
            Text(text)
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 8)
            if let action {
                Button(action: action.run) {
                    Label(action.title, systemImage: action.icon).font(Theme.sans(13, .semibold))
                        .padding(.horizontal, 18).frame(height: 34)
                        .background(Capsule().fill(Theme.hover))
                        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }
}

/// What the agent is doing, or what its last run said.
private struct RunStatus: View {
    @ObservedObject var runner: CopilotRunner

    var body: some View {
        Group {
            switch runner.state {
            case .idle: EmptyView()
            case .running(let since):
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Redrafting · \(Self.elapsed(since, ctx.date))")
                    }
                }
            case .done(let text, let at):
                Text("\(text) · \(at.formatted(.relative(presentation: .named)))").lineLimit(1)
            case .failed(let text, _):
                Label(text, systemImage: "exclamationmark.triangle").lineLimit(1).foregroundStyle(Theme.accentInk)
                    .help("The run's output is in _library/comments/runs/")
            }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        .frame(maxWidth: 360, alignment: .trailing)
    }

    static func elapsed(_ from: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - The card

private struct ReviewCard: View {
    @Environment(AppModel.self) private var app
    @ObservedObject var store: CopilotStore
    var hub: ChatHub
    let suggestion: Suggestion
    let position: Int
    let total: Int
    /// Back (-1) or on (+1) to another post; past the last one comes the first.
    var go: (Int) -> Void = { _ in }
    /// One text per variant, so an edit survives switching between them.
    @State private var texts: [String] = []
    @State private var pick = 0
    @State private var mode: Mode = .none
    @State private var note = ""
    @State private var wrongPost = false
    @FocusState private var editorFocused: Bool
    @FocusState private var noteFocused: Bool

    enum Mode { case none, decline, feedback }

    private var text: String { texts.indices.contains(pick) ? texts[pick] : "" }
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { if texts.indices.contains(pick) { texts[pick] = $0 } })
    }
    private func original(_ s: Suggestion, _ i: Int) -> String { s.options.indices.contains(i) ? s.options[i] : "" }

    var body: some View {
        let s = suggestion
        // No card around the card (2026-10-02): the post is the only box; the variants are
        // numbers above it, the actions sit under it.
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                // ⌘[ and ⌘]: the arrow keys move the cursor in the comment box (2026-10-02).
                HStack(spacing: 2) {
                    Button { go(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Previous post (⌘[)")
                    Button { go(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Next post (⌘])")
                }
                .buttonStyle(PressStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .disabled(total < 2)
                Text("\(position) of \(total) · \(meta(s))").font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer()
                if s.options.count > 1 { variantPicker(s) }
                if let u = s.post.url.flatMap(URL.init(string:)) {
                    Button("Open post") { NSWorkspace.shared.openSoon(u) }.buttonStyle(BracketButtonStyle())
                }
            }
            LinkedInThread(post: s.post, photo: store.root.flatMap { r in s.post.photo.map { CopilotStore.suggestions(r).appending(path: $0) } }) { commentBox }
            let note = s.drafts.count > 1 ? s.drafts[s.drafts.count - 2].feedback : nil
            if note != nil || text != original(s, pick) {
                HStack(spacing: 6) {
                    if let note {
                        Text("After your note: \u{201C}\(note)\u{201D}").font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer()
                    if text != original(s, pick) { Tag(text: "edited", accent: true) }
                }
            }
            switch mode {
            case .decline: declinePanel(s)
            case .feedback: feedbackPanel(s)
            case .none: actions(s)
            }
        }
        .padding(.vertical, 8)
        .onAppear { texts = s.options; pick = 0 }
        .animation(Theme.motion, value: mode)
    }

    /// Your comment under the post, as LinkedIn shows it. You edit it in place.
    private var commentBox: some View {
        LinkedInComment(focused: editorFocused) {
            TextEditor(text: textBinding)
                .font(LinkedIn.font(14))
                .foregroundStyle(LinkedIn.ink)
                .scrollContentBackground(.hidden)
                .lineSpacing(3)
                .focused($editorFocused)
                .padding(.horizontal, -5)
                .frame(minHeight: 60, maxHeight: 260)
        }
    }

    /// Three different comments: click a number (or ⌘1 to ⌘3) to see it under the post.
    private func variantPicker(_ s: Suggestion) -> some View {
        HStack(spacing: 4) {
            Text("Variant").font(Theme.sans(12)).foregroundStyle(Theme.faint).padding(.trailing, 4)
            ForEach(s.options.indices, id: \.self) { i in
                let on = pick == i
                let edited = texts.indices.contains(i) && texts[i] != original(s, i)
                Button { pick = i } label: {
                    Text("\(i + 1)").font(Theme.sans(12.5, .semibold)).monospacedDigit()
                        .foregroundStyle(on ? .white : Theme.muted)
                        .frame(width: 28, height: 28)
                        .background(on ? Theme.accent : Theme.hover, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if edited {
                                Circle().fill(Theme.warn).frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 1.5))
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .help("Variant \(i + 1) (⌘\(i + 1)): \(String((texts.indices.contains(i) ? texts[i] : s.options[i]).prefix(120)))")
            }
        }
        .animation(Theme.motion, value: pick)
    }

    private func meta(_ s: Suggestion) -> String {
        var parts = ["found \(s.created.formatted(.relative(presentation: .named)))"]
        if s.skipped != nil { parts.append("skipped before") }
        return parts.joined(separator: " · ")
    }

    // ⌘⌫ and ⌘→ move the cursor in the comment box: no card action may sit on them while you
    // type (2026-10-02: an arrow key meant for the text skipped the card).
    private func actions(_ s: Suggestion) -> some View {
        HStack(spacing: 8) {
            Button { store.approve(s, text: text, variant: pick) } label: {
                Label(s.options.count > 1 ? "Approve \(pick + 1)" : "Approve", systemImage: "checkmark")
            }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Approve the variant you see (⌘↩). If you changed the text, your version is saved next to it.")
            Button("Feedback") { editorFocused = false; mode = .feedback; noteFocused = true }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Tell the agent what to change; a new draft comes back (⇧⌘F). ⌘F finds on screen.")
            Button("Decline") { editorFocused = false; mode = .decline }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
                .keyboardShortcut(editorFocused ? nil : KeyboardShortcut(.delete, modifiers: .command))
                .help("Decline with a reason (⌘⌫ when you are not typing in the comment)")
            Spacer()
            Button("Skip") { store.skip(s) }
                .buttonStyle(BracketButtonStyle())
                .help("Decide later. The card moves to the Skipped tab and stays there until you send it back.")
        }
    }

    // A reason button declines at once, with the note if one is typed. A typed note alone
    // declines on Return as "other" (2026-10-05: The user typed a note, no reason fit, and could
    // not tell if the note went anywhere).
    private func declinePanel(_ s: Suggestion) -> some View {
        let reasons = DeclineReason.reasons(wrongPost: wrongPost)
        let typed = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $wrongPost) {
                Text("Bad comment").tag(false)
                Text("Wrong post").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Wrong post: you would not comment on this post at all. Bad comment: the post is fine, the draft is not.")
            HStack(spacing: 6) {
                ForEach(Array(reasons.enumerated()), id: \.element) { i, r in
                    Button { decline(s, r) } label: {
                        HStack(spacing: 4) {
                            Text("\(i + 1)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                            Text(r.rawValue)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                    .help(typed ? "Decline as \u{201C}\(r.rawValue)\u{201D}, with your note" : "Decline as \u{201C}\(r.rawValue)\u{201D}")
                    // Not while typing the note: a digit there is text.
                    .keyboardShortcut(noteFocused ? nil : KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: []))
                }
            }
            AskBox(placeholder: "Or say why and press Return to decline", text: $note, focus: $noteFocused,
                   send: { decline(s, .other) }, cancel: { mode = .none; note = "" }, autofocus: false)
            Text(typed ? "Return declines with this note. A reason button adds the reason to it." : "Pick a reason, or type why. Esc closes.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
        }
    }

    private func decline(_ s: Suggestion, _ r: DeclineReason) {
        if r == .other && note.trimmingCharacters(in: .whitespaces).isEmpty {
            noteFocused = true
            return
        }
        store.decline(s, wrongPost: wrongPost, reason: r, note: note)
        mode = .none
        note = ""
    }

    private func feedbackPanel(_ s: Suggestion) -> some View {
        AskBox(placeholder: "What should change? Shorter, ask a question instead…", text: $note,
               focus: $noteFocused, send: { send(s) }, cancel: { mode = .none; note = "" })
    }

    private func send(_ s: Suggestion) {
        guard !note.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.feedback(s, note: note, variant: s.options.count > 1 ? pick : nil, edit: text)
        mode = .none
        note = ""
        app.show(toast: "Note added. Send it from the Comments chat when you are done.")
    }
}

// MARK: - Approved

private struct ApprovedList: View {
    @ObservedObject var store: CopilotStore
    /// The chat is working: posting waits.
    let busy: Bool
    let review: () -> Void
    let postNow: () -> Void
    @State private var posting: String?
    @State private var link = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.approved.isEmpty {
                    BoardEmpty(badge: "paperplane.fill", title: "Nothing approved yet",
                               text: "Comments you approve wait here. Post now posts them in a background Chrome tab, one to two minutes apart.",
                               action: store.review.isEmpty ? nil : ("Review \(store.review.count) \(store.review.count == 1 ? "draft" : "drafts")", "arrow.left", review))
                } else {
                HStack(alignment: .center, spacing: 12) {
                    Text("Approved comments wait here. Post now sends an agent to post them in a background Chrome tab, one to two minutes apart. You watch it in the chat.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !store.approved.isEmpty {
                        Button { postNow() } label: {
                            Label("Post \(store.approved.count == 1 ? "it" : "all \(store.approved.count)") now", systemImage: "paperplane")
                        }
                        .buttonStyle(AccentButtonStyle(kind: .accent))
                        .disabled(busy)
                        .help(busy ? "Already posting. Watch it in the Posting chat." : "Post every approved comment, exactly as approved. Finding can run at the same time.")
                    }
                }
                ForEach(store.approved) { s in row(s) }
                }
            }
            .frame(maxWidth: 720 * TextSize.shared.factor, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ s: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(s.post.author ?? "Unknown").font(Theme.sans(13, .semibold))
                if s.decision?.kind == "edited" { Tag(text: "your edit", accent: true) }
                Spacer()
                if let u = s.post.url.flatMap(URL.init(string:)) {
                    Button("Open post") { NSWorkspace.shared.openSoon(u) }.buttonStyle(BracketButtonStyle())
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.text, forType: .string)
                }
                .buttonStyle(BracketButtonStyle())
                .help("Copy the comment")
                Button("Pull back") { store.pullBack(s) }.buttonStyle(BracketButtonStyle())
                    .help("Back to Review")
                Button("Mark posted") { posting = s.id; link = "" }.buttonStyle(BracketButtonStyle())
            }
            LinkedInComment(focused: false) {
                Text(s.text).font(LinkedIn.font(14)).foregroundStyle(LinkedIn.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.colorScheme, .light)
            if posting == s.id {
                HStack(spacing: 8) {
                    TextField("Link to your comment (optional)", text: $link).textFieldStyle(.roundedBorder)
                        .onSubmit { store.markPosted(s, url: link); posting = nil }
                    Button("Save") { store.markPosted(s, url: link); posting = nil }
                        .buttonStyle(AccentButtonStyle(kind: .solid))
                    Button("Cancel") { posting = nil }.buttonStyle(BracketButtonStyle())
                }
            }
        }
        .card(padding: 14)
    }
}

// MARK: - Skipped

struct SkippedList: View {
    @ObservedObject var store: CopilotStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.skippedList.isEmpty {
                    BoardEmpty(badge: "arrow.uturn.backward", tint: Theme.warn, title: "Nothing skipped",
                               text: "Skip a card in Review to decide later. It waits here until you send it back or decline it.")
                } else {
                    HStack {
                        SectionLabel(text: "skipped cards")
                        Spacer()
                        Text("\(store.skippedList.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 6)
                    Rule()
                    ForEach(store.skippedList) { s in
                        SkippedRow(store: store, s: s)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        Rule()
                    }
                }
            }
            .frame(maxWidth: 720 * TextSize.shared.factor, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One skipped card: who wrote the post, a line of it, then your draft. The buttons come up
/// under the pointer.
private struct SkippedRow: View {
    @ObservedObject var store: CopilotStore
    let s: Suggestion
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LinkedInAvatar(name: s.post.author ?? "?", size: 30, mine: false,
                           photo: store.root.flatMap { r in s.post.photo.map { CopilotStore.suggestions(r).appending(path: $0) } })
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(s.post.author ?? "Unknown").font(Theme.sans(13, .semibold)).lineLimit(1)
                    if let at = s.skipped {
                        Text(at.formatted(.relative(presentation: .named)))
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                if let t = s.post.text?.split(whereSeparator: \.isNewline).first {
                    Text(t).font(Theme.sans(12)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Text(s.text).font(Theme.sans(13)).foregroundStyle(Theme.ink.opacity(0.92))
                    .lineLimit(2).textSelection(.enabled)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if let u = s.post.url.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.openSoon(u) } label: {
                        Image(systemName: "arrow.up.right").frame(width: 26, height: 26)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Open the post on LinkedIn")
                }
                Button { withAnimation(Theme.spring) { store.decline(s, wrongPost: true, reason: .topic) } } label: {
                    Image(systemName: "xmark").frame(width: 26, height: 26)
                }
                .buttonStyle(IconButtonStyle())
                .help("Decline: wrong post, not my topic")
                Button { withAnimation(Theme.spring) { store.unskip(s.id) } } label: {
                    Label("Review", systemImage: "arrow.uturn.backward")
                        .font(Theme.sans(12, .medium))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Theme.accentSoft, in: Capsule())
                        .foregroundStyle(Theme.accentInk)
                }
                .buttonStyle(PressStyle())
                .padding(.leading, 4)
                .help("Send it back to Review")
            }
            .font(.system(size: 11.5, weight: .medium))
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.motion) { hover = h } }
    }
}

// MARK: - Posted

struct PostedList: View {
    @ObservedObject var store: CopilotStore
    var approved: () -> Void = {}
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.posted.isEmpty {
                    BoardEmpty(badge: "chart.line.uptrend.xyaxis", tint: Theme.live, title: "No comments posted yet",
                               text: "Each comment you post comes here, so you see how many go out and keep the streak going.",
                               action: store.approved.isEmpty ? nil : ("\(store.approved.count) approved, ready to post", "paperplane", approved))
                } else {
                    PostedStats(tally: PostedTally(store.posted)).padding(.bottom, 26)
                    HStack {
                        SectionLabel(text: "posted comments")
                        Spacer()
                        Text("\(store.posted.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 6)
                    Rule()
                    ForEach(Array(store.posted.enumerated()), id: \.element.id) { i, s in
                        PostedRow(store: store, s: s)
                            .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
                            .animation(Theme.spring.delay(0.25 + Double(min(i, 12)) * 0.03), value: shown)
                        Rule()
                    }
                }
            }
            .padding(24)
        }
        .onAppear { shown = true }
    }
}

/// One posted comment: its words, where it went and when; a soft ground under the pointer.
private struct PostedRow: View {
    @ObservedObject var store: CopilotStore
    let s: Suggestion
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.text).font(Theme.sans(13)).lineLimit(3).textSelection(.enabled)
                Text("on \(s.post.author ?? "a post") · \(s.posted?.at.map { $0.formatted(.relative(presentation: .named)) } ?? "")")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button { withAnimation(Theme.spring) { store.toggleBest(s) } } label: {
                    Image(systemName: s.best == true ? "star.fill" : "star")
                        .symbolEffect(.bounce, value: s.best == true)
                }
                .buttonStyle(.borderless).foregroundStyle(s.best == true ? Theme.accent : Theme.muted)
                .help("Mark as a best example: the agent studies these")
                if let u = (s.posted?.url ?? s.post.url).flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.openSoon(u) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                        .help("Open it on LinkedIn")
                }
            }
            .opacity(hover || s.best == true ? 1 : 0.55)
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.motion) { hover = h } }
    }
}

/// Core numbers, then one chart: each day's comments as bars (left axis) and the running total
/// as a line over them (right axis). Everything grows in when the tab opens; hover a day for its numbers.
private struct PostedStats: View {
    let tally: PostedTally
    @State private var grown = 0.0
    @State private var picked: Date?

    var body: some View {
        let t = tally
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PostedMetric(index: 0, icon: "paperplane.fill", tint: Theme.accent, label: "posted",
                             value: Double(t.total), note: "+\(t.thisWeek) in the last 7 days")
                PostedMetric(index: 1, icon: "calendar", tint: Theme.accent, label: "per day · 30 days",
                             value: t.perDay30, decimals: 1, note: "best day: \(t.bestDay)")
                PostedMetric(index: 2, icon: "flame.fill", tint: Theme.warn, label: "streak",
                             value: Double(t.streak), note: t.streak == 1 ? "day in a row" : "days in a row")
            }
            chart(t)
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) { grown = 1 } }
    }

    private func chart(_ t: PostedTally) -> some View {
        // The total shares the bars' room: each axis is rounded up so its middle line is a whole
        // number, and the total is scaled so its top meets the bars' top.
        let top = Self.roundUp(t.days.map(\.count).max() ?? 1)
        let scale = top / Self.roundUp(t.total)
        let n = Double(max(t.days.count - 1, 1))
        let day = picked.flatMap { p in t.days.first { Calendar.current.isDate($0.date, inSameDayAs: p) } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                SectionLabel(text: "comments posted")
                Spacer()
                if let day {
                    Text("\(day.date.formatted(.dateTime.month(.abbreviated).day())) · \(day.count) posted · \(day.total) in all")
                        .font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink)
                        .transition(.opacity)
                } else {
                    key(Theme.secondary.opacity(0.5), "per day", line: false)
                    key(Theme.accent, "total", line: true)
                }
            }
            .animation(Theme.motion, value: day?.date)
            Chart {
                ForEach(Array(t.days.enumerated()), id: \.element.id) { i, d in
                    // Each bar rises a moment after the one before it, left to right.
                    let rise = min(max(grown * 1.6 - Double(i) / n * 0.6, 0), 1)
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Per day", Double(d.count) * rise))
                        .foregroundStyle(d.date == day?.date ? Theme.accent.opacity(0.75)
                                         : i == t.days.count - 1 ? Theme.accent.opacity(0.35) : Theme.secondary.opacity(0.4))
                        .cornerRadius(3)
                }
                ForEach(t.days) { d in
                    AreaMark(x: .value("Day", noon(d.date)), y: .value("Total", Double(d.total) * scale * grown))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", noon(d.date)), y: .value("Total", Double(d.total) * scale * grown))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let day {
                    RuleMark(x: .value("Day", day.date, unit: .day))
                        .foregroundStyle(Theme.muted.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Day", noon(day.date)), y: .value("Total", Double(day.total) * scale))
                        .foregroundStyle(Theme.accent).symbolSize(70)
                } else if let last = t.days.last, grown > 0.98 {
                    PointMark(x: .value("Day", noon(last.date)), y: .value("Total", Double(last.total) * scale))
                        .foregroundStyle(Theme.accent).symbolSize(55)
                }
            }
            .chartYScale(domain: 0...(top * 1.08))
            .chartXSelection(value: $picked)
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks(top)) { v in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel { Text(v.as(Double.self).map { String(Int($0.rounded())) } ?? "").foregroundStyle(Theme.muted) }
                }
                AxisMarks(position: .trailing, values: ticks(top)) { v in
                    AxisValueLabel { Text(v.as(Double.self).map { String(Int(($0 / scale).rounded())) } ?? "").foregroundStyle(Theme.accent) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, t.days.count / 7))) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 190)
        }
        .font(Theme.mono(10))
        .card(padding: 16)
        .opacity(grown > 0 ? 1 : 0)
    }

    /// Three even steps up to the top.
    private func ticks(_ top: Double) -> [Double] { [0, top / 2, top] }

    /// Bars stand across their day; the line's points sit in the middle of it, over them.
    private func noon(_ day: Date) -> Date { day.addingTimeInterval(12 * 3600) }

    /// Up to an even number, then to 20, 40, 50 or a multiple of 50, so half of it is whole.
    static func roundUp(_ n: Int) -> Double {
        let n = max(n, 1)
        if n <= 10 { return Double(n + n % 2) }
        if n <= 20 { return 20 }
        if n <= 40 { return 40 }
        return Double((n + 49) / 50 * 50)
    }

    private func key(_ color: Color, _ text: String, line: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: line ? 12 : 7, height: line ? 2.5 : 9)
            Text(text).font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}

/// A number card: slides in after the one before it, counts up from zero, lifts under the pointer.
private struct PostedMetric: View {
    let index: Int
    let icon: String
    let tint: Color
    let label: String
    let value: Double
    var decimals = 0
    let note: String
    @State private var shown = 0.0
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(tint.opacity(0.12)))
                    .scaleEffect(hover ? 1.12 : 1)
                SectionLabel(text: label)
            }
            Text(String(format: "%.\(decimals)f", value * shown))
                .font(Theme.display(32)).foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: value * shown))
                .monospacedDigit()
            Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .offset(y: hover ? -2 : 0)
        .opacity(shown > 0 ? 1 : 0)
        .offset(y: shown > 0 ? 0 : 10)
        .onHover { h in withAnimation(Theme.spring) { hover = h } }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.9).delay(Double(index) * 0.07)) { shown = 1 }
        }
    }
}

// MARK: - Library

/// The files each draft run reads, as a list; the one picked opens beside it to read, edit and
/// comment on, like a file in the Assets library. Before (2026-10-04), the lessons filled the
/// tab and the target list and style guide opened in another app.
struct CopilotDoc: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String
    let url: URL

    /// Lessons in the library; the rest in your notes repo, where the agent reads them.
    @MainActor static func all(_ root: URL) -> [CopilotDoc] {
        let li = ClaudeChat.folder.appending(path: "reference-docs/communication/linkedin")
        return [
            CopilotDoc(id: "lessons", title: "Lessons", note: "Your rules, read first", url: CopilotStore.lessons(root)),
            CopilotDoc(id: "targets", title: "Target list", note: "Whose posts to find",
                       url: li.appending(path: "commenting-targets.md")),
            CopilotDoc(id: "style", title: "Style guide", note: "How you sound",
                       url: li.appending(path: "comment-style-guide.md")),
            CopilotDoc(id: "best", title: "Best comments", note: "Comments that did well",
                       url: li.appending(path: "comment-library.md")),
        ]
    }
}

/// About how much of the agent's context a text takes: Claude reads about 4 characters of
/// English as one token. Close enough to compare files; not a bill.
enum TokenCount {
    static func of(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    static func label(_ n: Int) -> String {
        n < 1000 ? "\(n)" : n < 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n / 1000)k"
    }
}

struct CopilotLibrary: View {
    @ObservedObject var store: CopilotStore
    @AppStorage("copilotLibraryPick") private var pick = "lessons"
    /// Tokens per file, read when the list shows and when a file is saved.
    @State private var tokens: [String: Int] = [:]

    private static let decisions = "decisions"

    var body: some View {
        HStack(spacing: 0) {
            if let root = store.root {
                list(root).frame(width: 260)
                Rule(vertical: true)
                Group {
                    if pick == Self.decisions {
                        CopilotDecisions(store: store)
                    } else if let d = CopilotDoc.all(root).first(where: { $0.id == pick }) ?? CopilotDoc.all(root).first {
                        CopilotDocView(doc: d, root: CopilotStore.folder(root)) { tokens[d.id] = $0 }
                            .id(d.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func list(_ root: URL) -> some View {
        let docs = CopilotDoc.all(root)
        let total = docs.compactMap { tokens[$0.id] }.reduce(0, +) + (tokens[Self.decisions] ?? 0)
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "what each run reads")
            Text("About \(TokenCount.label(total)) tokens of the agent's context.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                .padding(.bottom, 10)
            ForEach(docs) { d in
                row(d.id, icon: "doc.text", d.title, d.note, tokens[d.id])
            }
            row(Self.decisions, icon: "checklist", "Your decisions", "What you changed",
                tokens[Self.decisions])
            Spacer()
        }
        .padding(16)
        .task(id: store.items.count) {
            var t: [String: Int] = [:]
            for d in docs { t[d.id] = TokenCount.of((try? String(contentsOf: d.url, encoding: .utf8)) ?? "") }
            t[Self.decisions] = CopilotDecisions.tokens(store)
            tokens = t
        }
    }

    private func row(_ id: String, icon: String, _ title: String, _ note: String, _ count: Int?) -> some View {
        let on = pick == id
        return Button { withAnimation(Theme.motion) { pick = id } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(on ? Theme.accentInk : Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(on ? Theme.accentSoft : Theme.hover, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                    Text(note).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(TokenCount.label(count)).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        .help("About \(count) tokens")
                }
            }
            .padding(8)
            .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One file: its text to edit, ⌘S saves, select text to comment for Takes. The comments sit in
/// the library's comments folder; the Comments chat reads them with get_comments library 'comments'.
private struct CopilotDocView: View {
    @Environment(AppModel.self) var app
    let doc: CopilotDoc
    let root: URL
    let counted: (Int) -> Void
    @StateObject private var store = CommentStore()
    @State private var text = ""
    @State private var saved = ""
    @State private var stamp: Date?
    @State private var selection = ""
    @State private var draft: ReviewPlayer.Draft?
    @State private var focused: String?
    @State private var reveal: (quote: String, token: Int)?
    /// Read shows the markdown styled, with tables (2026-10-04); Edit is the plain text.
    @AppStorage("copilotDocReading") private var reading = true

    private var file: String { CommentStore.path(of: doc.url, in: root) }
    private var comments: [Comment] { store.on(file) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rule()
            ScriptCommentList(comments: comments, focused: focused) { c in
                withAnimation(Theme.motion) { draft = nil; focused = c.id }
                if let q = c.quote { reveal = (q, (reveal?.token ?? 0) + 1) }
            }
            Group {
                if reading {
                    MarkdownReader(text: text, size: 14.5, highlights: comments.filter(\.open).compactMap(\.quote),
                                   reveal: reveal, onSelect: { selection = $0 }, onComment: start)
                } else {
                    Prompter(text: $text, contentKey: doc.url.path, fontSize: 15, scrolling: false, speed: 0,
                             editable: true, resetToken: 0,
                             highlights: comments.filter(\.open).compactMap(\.quote), reveal: reveal,
                             onSelect: { selection = $0 }, onComment: start)
                }
            }
            .overlay(alignment: .bottomLeading) { card.padding(12) }
        }
        .onAppear { load(); store.load(root) }
        .onDisappear { if text != saved { save() } }
        .onFilesChanged(in: root) { store.load(root) }
        // The agent edits these files while you watch (a name added to the target list): show its
        // change, unless you are in the middle of your own.
        .task(id: doc.url) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if text == saved, Store.modified(doc.url) != stamp { load() }
            }
        }
        .onExitCommand { withAnimation(Theme.motion) { if draft != nil { draft = nil } else { focused = nil } } }
    }

    private func load() {
        let fresh = (try? String(contentsOf: doc.url, encoding: .utf8)) ?? ""
        stamp = Store.modified(doc.url)
        saved = fresh
        if fresh != text { text = fresh }
        counted(TokenCount.of(fresh))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: doc.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try text.write(to: doc.url, atomically: true, encoding: .utf8)
            saved = text
            stamp = Store.modified(doc.url)
            counted(TokenCount.of(text))
        } catch {
            app.show(toast: "Could not save \(doc.url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func start() {
        guard !selection.isEmpty else { return }
        withAnimation(Theme.motion) { focused = nil; draft = ReviewPlayer.Draft(quote: selection, timed: false) }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title).font(Theme.sans(14, .semibold))
                Text("\(doc.url.lastPathComponent) · about \(TokenCount.label(TokenCount.of(text))) tokens")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).help(doc.url.path)
            }
            Spacer()
            Picker("", selection: $reading) {
                Text("Read").tag(true)
                Text("Edit").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: reading) { selection = "" }
            .help("Read shows the formatting; Edit shows the markdown to change it")
            Button(action: start) { Label("Comment", systemImage: "text.bubble") }
                .buttonStyle(BracketButtonStyle())
                .disabled(selection.isEmpty)
                .help("Select text, then comment on it for Takes")
            if !reading || text != saved {
                Button("Save", action: save)
                    .buttonStyle(AccentButtonStyle(kind: .solid))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == saved)
                    .opacity(text == saved ? 0.4 : 1)
            }
            Button { NSWorkspace.shared.revealSoon([doc.url]) } label: {
                Image(systemName: "folder").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.muted)
            .help("Show in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var card: some View {
        if let d = draft {
            Composer(draft: Composer.bind($draft, d),
                     onSend: {
                         let t = (draft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                         guard !t.isEmpty, let q = draft?.quote else { return }
                         if let c = store.add(script: file, quote: q, text: t) { app.show(toast: "Comment \(c.id) saved for Takes") }
                         withAnimation(Theme.motion) { draft = nil }
                     },
                     onCancel: { withAnimation(Theme.motion) { draft = nil } },
                     onArea: {})
        } else if let id = focused, let i = comments.firstIndex(where: { $0.id == id }) {
            let c = comments[i]
            CommentCard(comment: c, number: i + 1,
                        onReply: { store.reply(id, $0) },
                        onResolve: { store.setResolved(id, c.open) },
                        onDelete: { store.delete(id); focused = nil },
                        onClose: { withAnimation(Theme.motion) { focused = nil } },
                        onJump: { _, _ in })
        }
    }
}

/// What the agent learns from your past decisions: the newest 10 of each kind.
private struct CopilotDecisions: View {
    @ObservedObject var store: CopilotStore

    /// The examples the agent gets, as text: each post's text and the comments around it.
    @MainActor static func tokens(_ store: CopilotStore) -> Int {
        let edited = store.items.filter { $0.decision?.kind == "edited" }.suffix(10)
        let approved = store.items.filter { $0.decision?.kind == "approved" }.suffix(10)
        let shown = Array(edited) + Array(approved) + Array(store.declined.suffix(10))
        let text = shown.map { s in
            [s.post.text, s.post.author, s.text, s.final, s.drafts.last?.text, s.decision?.note]
                .compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
        return TokenCount.of(text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("The agent studies these to learn what you change.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                examples("your edits", store.items.filter { $0.decision?.kind == "edited" }) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.drafts.last?.text ?? "").font(Theme.sans(12)).foregroundStyle(Theme.faint).strikethrough()
                        Text(s.final ?? "").font(Theme.sans(12.5))
                    }
                }
                examples("declined", store.declined) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Tag(text: s.decision?.kind == "wrong_post" ? "wrong post" : "bad comment")
                            if let r = s.decision?.reason { Tag(text: r, accent: true) }
                            if let n = s.decision?.note { Text(n).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
                        }
                        Text(s.text).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                }
                examples("approved as drafted", store.items.filter { $0.decision?.kind == "approved" }) { s in
                    Text(s.text).font(Theme.sans(12.5)).lineLimit(4)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
        }
    }

    private func examples<Row: View>(_ title: String, _ list: [Suggestion], @ViewBuilder row: @escaping (Suggestion) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "\(title) · \(list.count)")
            if list.isEmpty {
                Text("None yet.").font(Theme.sans(12)).foregroundStyle(Theme.faint)
            }
            ForEach(list.suffix(10).reversed()) { s in
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.post.author ?? "").font(Theme.sans(11, .medium)).foregroundStyle(Theme.muted)
                    row(s)
                }
                .builderBorder()
            }
        }
    }
}

// MARK: - LinkedIn look

/// Someone's post as the LinkedIn feed shows it, with your comment under it.
private struct LinkedInThread<Comment: View>: View {
    let post: CommentPost
    var photo: URL? = nil
    @ViewBuilder var comment: Comment
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 22)
            if let t = post.text, !t.isEmpty {
                textBlock(t).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 10)
            }
            if post.reactions != nil || post.comments != nil {
                counts.padding(.horizontal, 24).padding(.vertical, 10)
            }
            Rectangle().fill(LinkedIn.line).frame(height: 1).padding(.horizontal, 24)
            actions.padding(.horizontal, 14).padding(.vertical, 6)
            comment.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
        }
        .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.07)))
        .cardShadow(RoundedRectangle(cornerRadius: 14, style: .continuous), fill: LinkedIn.card, radius: 16, y: 6)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            LinkedInAvatar(name: post.author ?? "?", size: 48, mine: false, photo: photo)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author ?? "Unknown").font(LinkedIn.font(14, .semibold)).foregroundStyle(LinkedIn.ink)
                if let h = post.headline {
                    Text(h).font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted).lineLimit(2)
                }
                HStack(spacing: 3) {
                    if let p = post.posted { Text("\(p) •").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted) }
                    Image(systemName: "globe.americas.fill").font(.system(size: 11)).foregroundStyle(LinkedIn.muted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let u = post.authorURL.flatMap(URL.init(string:)) { NSWorkspace.shared.openSoon(u) } }
            .help("Open their profile")
            Spacer(minLength: 8)
            Text("+ Follow").font(LinkedIn.font(14, .semibold)).foregroundStyle(LinkedIn.blue).padding(.top, 2)
        }
    }

    @ViewBuilder private func textBlock(_ t: String) -> some View {
        if expanded {
            VStack(alignment: .trailing, spacing: 4) {
                Text(LinkedIn.styled(t.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .font(LinkedIn.font(14)).foregroundStyle(LinkedIn.ink).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("show less") { expanded = false }
                    .buttonStyle(.plain).font(LinkedIn.font(14)).foregroundStyle(LinkedIn.muted)
            }
        } else {
            FeedText(text: t, help: "Show the whole post") { expanded = true }
        }
    }

    private var counts: some View {
        HStack(spacing: 4) {
            if let r = post.reactions {
                HStack(spacing: -4) {
                    LinkedIn.reaction("hand.thumbsup.fill", LinkedIn.blue)
                    LinkedIn.reaction("heart.fill", Color(red: 0.87, green: 0.33, blue: 0.2))
                    LinkedIn.reaction("lightbulb.fill", Color(red: 0.96, green: 0.73, blue: 0.2))
                }
                Text(r.formatted()).font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
            }
            Spacer()
            if let c = post.comments {
                Text("\(c.formatted()) comments").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action("hand.thumbsup", "Like")
            action("text.bubble", "Comment")
            action("arrow.2.squarepath", "Repost")
            action("paperplane.fill", "Send")
        }
        .allowsHitTesting(false)
    }

    private func action(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15))
            Text(title).font(LinkedIn.font(13, .semibold))
        }
        .foregroundStyle(LinkedIn.muted)
        .frame(maxWidth: .infinity).padding(.vertical, 9)
    }
}

/// Your comment as LinkedIn shows it: your photo, then a grey bubble with your name, headline
/// and the text.
private struct LinkedInComment<Body_: View>: View {
    let focused: Bool
    @ViewBuilder var content: Body_
    @AppStorage("linkedinName") private var name = "You"
    @AppStorage("linkedinHeadline") private var headline = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LinkedInAvatar(name: name, size: 36, mine: true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(LinkedIn.font(13, .semibold)).foregroundStyle(LinkedIn.ink)
                        Spacer()
                        Text("Now").font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted)
                    }
                    Text(headline).font(LinkedIn.font(12)).foregroundStyle(LinkedIn.muted).lineLimit(1)
                    content.padding(.top, 8)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color(red: 0.95, green: 0.95, blue: 0.95), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? LinkedIn.blue.opacity(0.5) : .clear))
                HStack(spacing: 6) {
                    Text("Like").font(LinkedIn.font(12, .semibold))
                    Text("|").font(LinkedIn.font(12))
                    Text("Reply").font(LinkedIn.font(12, .semibold))
                }
                // Under the bubble, on the board's page in dark mode too: a grey that reads on both.
                .foregroundStyle(Color(white: 0.55))
                .padding(.leading, 8)
            }
        }
    }
}

/// A round photo: yours if you set one in the post tab, else initials.
private struct LinkedInAvatar: View {
    let name: String
    let size: CGFloat
    let mine: Bool
    /// Their LinkedIn photo, saved when the post was found.
    var photo: URL? = nil

    /// The photo file decoded once: this view redraws on every keystroke of the card's editor.
    private static let images = NSCache<NSURL, NSImage>()
    private static func image(_ url: URL) -> NSImage? {
        if let hit = images.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        images.setObject(img, forKey: url as NSURL)
        return img
    }

    var body: some View {
        Group {
            if let img = mine ? LinkedIn.photo : photo.flatMap(Self.image) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    (mine ? LinkedIn.blue.opacity(0.85) : Color(white: 0.82))
                    Text(initials).font(LinkedIn.font(size * 0.36, .semibold)).foregroundStyle(mine ? .white : LinkedIn.ink)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// Icon and title close together.
private struct RunLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title.lineLimit(1)
        }
    }
}
