import Charts
import SwiftUI

// The LinkedIn comment copilot from the Mac's Comments board, for the phone (2026-10-02).
// Review the drafts, approve, edit, give a note for a redraft, skip or decline. Start a run that
// finds posts, or post the approved comments, and watch either chat. The runs work on the Mac,
// in its Chrome; the phone only asks. Nothing is posted without the Post button here or on the Mac.

struct CopilotView: View {
    @EnvironmentObject var model: Model
    @AppStorage("copilotTab") private var tab = "review"
    @State private var data: Copilot?
    @State private var failed: String?
    @State private var watching: String?
    @State private var confirmPost = false
    /// The draft on top of the Review deck and the variant he looks at: the message bar's context.
    @State private var focus: CopilotFocus?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenHeader(title: "") {
                        // No system menus (2026-10-04): a tap opens the finding chat, a long press the posting chat.
                        Button { watching = "board:comments" } label: { RoundIcon(icon: "bubble.left.and.text.bubble.right", label: "Chats") }
                            .buttonStyle(.press)
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in Brand.tap(.medium); watching = "board:comments-post" })
                            .accessibilityAction(named: "Posting chat") { watching = "board:comments-post" }
                    } trailing: {
                        Button { Task { await find(5) } } label: {
                            Label("Find posts", systemImage: "sparkle.magnifyingglass")
                                .font(.inter(.subheadline, .semibold)).labelStyle(PillLabel())
                                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 34)
                                .background(Palette.accent, in: Capsule())
                        }
                        .buttonStyle(.press)
                        .disabled(data?.finding ?? false)
                    }
                    .padding(.horizontal, -16).padding(.top, -16)
                    CopilotTabs(tab: $tab, tabs: [
                        ("review", "Review", data.map { $0.review.count + $0.redraft.count } ?? 0, true),
                        ("approved", "Approved", data?.approved.count ?? 0, true),
                        ("posted", "Posted", data?.posted.count ?? 0, false),
                        ("skipped", "Skipped", data?.skipped.count ?? 0, false),
                    ])
                    running
                    if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote, .medium)).foregroundStyle(Palette.warn) }
                    if let data {
                        switch tab {
                        case "approved": approved(data)
                        case "posted": PostedTab(items: data.posted)
                        case "skipped": list(data.skipped, empty: "Nothing skipped.") { SkippedCard(s: $0, act: act) }
                        default: review(data)
                        }
                    } else if failed == nil {
                        WorkingDots().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                let f = tab == "review" ? focus : nil
                QuickSay(sessionID: "board:comments", toChat: { watching = "board:comments" }, from: "Comments",
                         placeholder: "Tell Takes about the comments…", wrap: { CopilotFocus.message($0, focus: f, tab: tab) })
            }
            .refreshable { await load() }
            .withTabBar()
            .navigationDestination(item: $watching) { id in
                BoardChatView(id: id, title: id == "board:comments-post" ? "Posting" : "Finding")
            }
            .task {
                if data == nil, let raw = Cache.loadData("copilot"), let c = try? API.decoder.decode(Copilot.self, from: raw) { data = model.patch(c) }
                await load()
            }
            .onChange(of: model.copilotTick) { _, _ in Task { await load() } }
        }
        .environment(\.linkedInMe, data?.profile)
    }

    @ViewBuilder private var running: some View {
        if let d = data {
            if d.finding { status("Finding posts…", lane: "board:comments") }
            if d.posting { status("Posting comments…", lane: "board:comments-post") }
            if d.redrafting && tab != "review" {
                HStack(spacing: 8) { WorkingDots(); Text("Redrafting from your notes") }
                    .font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func status(_ text: String, lane: String) -> some View {
        Button { watching = lane } label: {
            HStack(spacing: 10) {
                WorkingDots()
                Text(text).foregroundStyle(Palette.ink)
                Spacer()
                Text("Watch").font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.accent)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
            }
            .font(.inter(.subheadline, .medium))
            .padding(14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
        }
        .buttonStyle(Pressable(scale: 0.98))
    }

    // MARK: Tabs

    @ViewBuilder private func review(_ d: Copilot) -> some View {
        if d.review.isEmpty && d.redraft.isEmpty {
            MascotEmpty(title: "No drafts to review",
                        message: "Find posts: Takes reads LinkedIn in the Mac's Chrome and drafts three comments for each post.") {
                Button { Task { await find(5) } } label: { Label("Find 5 posts", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(.pill()).disabled(d.finding)
            }
        }
        if !d.redraft.isEmpty {
            HStack(spacing: 8) {
                WorkingDots()
                Text("\(d.redraft.count) redrafting from your notes. They come back here.")
            }
            .font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
        }
        if !d.review.isEmpty { ReviewDeck(items: d.review, act: act, focus: $focus) }
    }

    @ViewBuilder private func approved(_ d: Copilot) -> some View {
        if !d.approved.isEmpty {
            Button { confirmPost = true } label: {
                Label(d.posting ? "Posting…" : "Post \(d.approved.count) on LinkedIn", systemImage: "paperplane.fill")
            }
            .buttonStyle(.pill(wide: true))
            .disabled(d.posting)
            .confirmationDialog("Post \(d.approved.count) \(d.approved.count == 1 ? "comment" : "comments")?", isPresented: $confirmPost, titleVisibility: .visible) {
                Button("Post on LinkedIn") { Task { await post() } }
            } message: {
                Text("Takes posts each one from the Mac's Chrome, exactly as approved. You can watch it in the Posting chat.")
            }
        }
        list(d.approved, empty: "Nothing approved yet.") { ApprovedCard(s: $0, act: act) }
    }

    @ViewBuilder private func list<Card: View>(_ items: [Suggestion], empty: String, card: @escaping (Suggestion) -> Card) -> some View {
        if items.isEmpty {
            MascotEmpty(title: empty)
        }
        ForEach(items) { card($0) }
    }

    // MARK: Calls

    private func load() async {
        do {
            guard model.connected else { throw URLError(.notConnectedToInternet) }
            let raw = try await model.api.copilotData()
            data = model.patch(try API.decoder.decode(Copilot.self, from: raw))
            Cache.saveData(raw, "copilot")
            failed = nil
        } catch {
            // Offline: the last copy, with the decisions that wait on top.
            if let raw = Cache.loadData("copilot"), let c = try? API.decoder.decode(Copilot.self, from: raw) {
                data = model.patch(c)
            } else {
                failed = error.localizedDescription
            }
        }
    }

    /// A decision on one card. The Mac writes it; the list reloads.
    private func act(_ s: Suggestion, _ action: String, _ extra: [String: Any]) async {
        do {
            try await model.decide(s.id, action, extra)
            failed = nil
        } catch {
            failed = error.localizedDescription
        }
        await load()
    }

    private func find(_ n: Int) async {
        do {
            try await model.api.runCopilot("find", count: n)
            watching = "board:comments"
        } catch { failed = error.localizedDescription }
        await load()
    }

    private func post() async {
        do {
            try await model.api.runCopilot("post")
            watching = "board:comments-post"
        } catch { failed = error.localizedDescription }
        await load()
    }
}

typealias CopilotAct = (Suggestion, String, [String: Any]) async -> Void

/// What the message bar on the Comments tab is about: the draft on top of the deck. The message
/// goes to the Finding chat with it in front; the chat's system prompt (CopilotAsk.context on the
/// Mac) decides from what he says whether it is about this draft or about all of them.
struct CopilotFocus: Equatable {
    var id: String
    var author: String?
    var url: String?
    var variant: Int
    var variants: Int
    var text: String

    /// The context goes after the message, behind a marker; the chats show only the message.
    static let marker = "\n\n[On screen on my phone: "

    static func message(_ text: String, focus: CopilotFocus?, tab: String) -> String {
        guard let f = focus else { return text + marker + "the Comments board, \(tab) tab]" }
        let quote = f.text.count > 140 ? String(f.text.prefix(140)) + "…" : f.text
        return text + marker + "the draft for \(f.author ?? "a post")'s post, suggestion \(f.id)"
            + (f.variants > 1 ? ", variant \(f.variant + 1) of \(f.variants)" : "") + ": \"\(quote)\"]"
    }

    /// A message as the chat shows it: without the phone's context, and without the open comments
    /// the Mac sends with a typed message (ClaudeChat.commentsMark).
    static func shown(_ text: String) -> String {
        var t = text
        for mark in [marker, "\n\n[@comments: open comments in Takes on this session"] {
            if let r = t.range(of: mark, options: .backwards) { t = String(t[..<r.lowerBound]) }
        }
        return t
    }
}

// MARK: - Cards

/// Review, Approved, Posted, Skipped. Each count sits in a circle; the ones that need you are filled.
struct CopilotTabs: View {
    @Binding var tab: String
    /// id, name, count, and whether the count asks for you.
    let tabs: [(String, String, Int, Bool)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { id, name, n, loud in
                let on = tab == id
                Button {
                    guard !on else { return }
                    Brand.select()
                    withAnimation(Brand.spring) { tab = id }
                } label: {
                    HStack(spacing: 5) {
                        Text(name).font(.inter(.footnote, on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        if n > 0 {
                            Text("\(n)").font(.inter(.caption2, .bold)).monospacedDigit()
                                .foregroundStyle(loud ? .white : on ? Palette.ink : Palette.muted)
                                .frame(minWidth: 18, minHeight: 18).padding(.horizontal, n > 9 ? 4 : 0)
                                .background(loud ? Palette.accent : on ? Palette.well : Palette.border, in: Capsule())
                        }
                    }
                    .foregroundStyle(on ? Palette.ink : Palette.muted)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background {
                        if on {
                            Capsule().fill(Palette.paper).shadow(color: Palette.shadow, radius: 4, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(n > 0 ? "\(name) \(n)" : name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.well, in: Capsule())
    }
}

extension EnvironmentValues {
    /// You on LinkedIn: your name and photo on the comment drafts.
    @Entry var linkedInMe: Profile?
}

/// The post the comment is for, as the LinkedIn feed shows it: author, text ("…more"), reactions,
/// and the Like, Comment, Repost, Send row.
struct SuggestedPost: View {
    @EnvironmentObject var model: Model
    let s: Suggestion
    /// Put on the clipboard when you open the post, ready to paste as your comment.
    var comment: String?
    @State private var open = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle().fill(Color(red: 0.86, green: 0.84, blue: 0.80))
                    Text(LinkedIn.initials(s.post.author ?? "?")).font(.system(size: 17, weight: .semibold)).foregroundStyle(LinkedIn.muted)
                    if s.post.photo != nil {
                        RemoteImage(url: model.api.copilotPhoto(s.id)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                }
                .frame(width: 48, height: 48).clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.post.author ?? "Someone").font(.system(size: 14, weight: .semibold)).foregroundStyle(LinkedIn.ink)
                    if let h = s.post.headline { Text(h).font(.system(size: 12)).foregroundStyle(LinkedIn.muted).lineLimit(1) }
                    HStack(spacing: 3) {
                        if let p = s.post.posted { Text("\(p) •") }
                        Image(systemName: "globe.americas.fill").font(.system(size: 10))
                    }
                    .font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                }
                Spacer(minLength: 4)
                if let u = s.post.url, let url = URL(string: u) {
                    Button {
                        if let comment { Clip.copy(comment) }
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(LinkedIn.blue)
                            .frame(width: 32, height: 32)
                            .background(LinkedIn.blue.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel(comment == nil ? "Open the post" : "Copy the comment and open the post")
                }
            }
            if let t = s.post.text, !t.isEmpty {
                FeedText(text: t, expanded: $open) {
                    Text(t).font(.system(size: 15)).foregroundStyle(LinkedIn.ink).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open = false } }
                }
                .padding(.top, 10)
            }
            if s.post.reactions != nil || s.post.comments != nil {
                HStack(spacing: 4) {
                    if let r = s.post.reactions, r > 0 {
                        Reactions()
                        Text(LinkedIn.count(r))
                    }
                    Spacer()
                    if let c = s.post.comments, c > 0 { Text("\(LinkedIn.count(c)) \(c == 1 ? "comment" : "comments")") }
                }
                .font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                .padding(.top, 10)
            }
            Rectangle().fill(LinkedIn.line).frame(height: 1).padding(.top, 8)
            LinkedInActions(compact: true)
        }
        .environment(\.colorScheme, .light)
    }
}

/// Like, love and celebrate, overlapping, as under a LinkedIn post.
struct Reactions: View {
    var body: some View {
        HStack(spacing: -4) {
            icon("hand.thumbsup.fill", Color(red: 0.22, green: 0.51, blue: 0.85))
            icon("heart.fill", Color(red: 0.87, green: 0.33, blue: 0.24))
            icon("hands.clap.fill", Color(red: 0.27, green: 0.6, blue: 0.33))
        }
        .accessibilityHidden(true)
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 16, height: 16).background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}

/// A white LinkedIn card.
private struct CardFrame<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(14)
            .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinkedIn.line))
            .environment(\.colorScheme, .light)
    }
}

/// Your comment, as LinkedIn shows it under the post: your photo, a grey box with your name.
/// Tap it to copy it.
struct CommentBubble: View {
    let text: String
    /// Under it: "Like · 3 | Reply · 1 reply", once it is posted.
    var likes: Int?
    var replies: Int?
    var seen: Int?
    @Environment(\.linkedInMe) private var me
    @State private var copied = false

    var body: some View {
        let name = me?.name ?? "You"
        HStack(alignment: .top, spacing: 8) {
            LinkedInAvatar(name: name, photo: me?.photo ?? false, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(LinkedIn.ink)
                        Text("• You").font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                    }
                    if let h = me?.headline, !h.isEmpty {
                        Text(h).font(.system(size: 11)).foregroundStyle(LinkedIn.muted).lineLimit(1)
                    }
                    Text(text).font(.system(size: 14)).foregroundStyle(LinkedIn.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .padding(10)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(copied ? LinkedIn.blue : .clear, lineWidth: 1.5))
                HStack(spacing: 6) {
                    Text(likes.map { $0 > 0 ? "Like · \($0)" : "Like" } ?? "Like")
                    Text("|").foregroundStyle(LinkedIn.line)
                    Text(replies.map { $0 > 0 ? "Reply · \($0) \($0 == 1 ? "reply" : "replies")" : "Reply" } ?? "Reply")
                    if let seen, seen > 0 { Text("· \(LinkedIn.count(seen)) seen").fontWeight(.regular) }
                    Spacer()
                    Label(copied ? "Copied" : "Tap to copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? LinkedIn.blue : LinkedIn.muted.opacity(0.7))
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(LinkedIn.muted)
                .padding(.leading, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Clip.copy(text)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
        }
        .accessibilityHint("Copies the comment")
        .environment(\.colorScheme, .light)
    }
}

enum Clip {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// One draft at a time, like a deck: swipe right to approve the draft you see, left to skip.
/// Edit, note and decline sit in one menu. Undo brings the last one back.
struct ReviewDeck: View {
    let items: [Suggestion]
    let act: CopilotAct
    @Binding var focus: CopilotFocus?
    /// Gone from the deck before the Mac answers.
    @State private var gone: Set<String> = []
    @State private var drag: CGSize = .zero
    @State private var variant = 0
    @State private var editing = false
    @State private var noting = false
    @State private var last: (s: Suggestion, undo: String, label: String)?

    private var deck: [Suggestion] { items.filter { !gone.contains($0.id) } }
    private var top: Suggestion? { deck.first }
    private func options(_ s: Suggestion) -> [String] { s.options }
    private func text(_ s: Suggestion) -> String {
        let o = options(s)
        return o.indices.contains(variant) ? o[variant] : s.text
    }

    private var current: CopilotFocus? {
        top.map { s in
            CopilotFocus(id: s.id, author: s.post.author, url: s.post.url, variant: variant,
                         variants: options(s).count, text: text(s))
        }
    }

    static let wrongPost = ["not my topic", "wrong person", "other"]
    static let badComment = ["off-voice", "sounds AI", "too generic", "too long", "wrong facts", "other"]

    var body: some View {
        VStack(spacing: 14) {
            if let last {
                // Up here: the floating tab bar covers the bottom of the screen.
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.live)
                    Text(last.label).font(.inter(.subheadline, .medium))
                    Spacer()
                    Button("Undo") { undo() }.buttonStyle(.pill(.soft, small: true))
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(Palette.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let s = top {
                card(s)
                    .id(s.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
                buttons(s)
            } else {
                MascotEmpty(title: "All reviewed", message: "Nice. The approved ones wait under Approved.")
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in gone.formIntersection(ids) }
        .onChange(of: current, initial: true) { _, f in focus = f }
        .onDisappear { focus = nil }
        .sheet(isPresented: $editing) {
            if let s = top {
                TextSheet(title: "Edit and approve", text: text(s), button: "Approve", hint: nil) { t in
                    decide(s, "approve", ["text": t, "variant": variant], undo: "pullback", label: "Approved")
                }
            }
        }
        .sheet(isPresented: $noting) {
            if let s = top {
                TextSheet(title: "Note for a redraft", text: "", button: "Send",
                          hint: "What should change? Takes on the Mac writes three new drafts from it.") { t in
                    decide(s, "feedback", ["text": t, "variant": variant], undo: nil, label: "Sent for a redraft")
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func card(_ s: Suggestion) -> some View {
        let dx = drag.width
        return VStack(alignment: .leading, spacing: 10) {
            SuggestedPost(s: s, comment: text(s))
            if options(s).count > 1 { drafts(s) }
            CommentBubble(text: text(s))
        }
        .padding(14)
        .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinkedIn.line))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .environment(\.colorScheme, .light)
        .overlay(alignment: .topLeading) { stamp("APPROVE", .green).opacity(Double(max(0, dx) / 100)).padding(18) }
        .overlay(alignment: .topTrailing) { stamp("SKIP", .orange).opacity(Double(max(0, -dx) / 100)).padding(18) }
        .offset(x: dx, y: drag.height * 0.15)
        .rotationEffect(.degrees(Double(dx) / 25), anchor: .bottom)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    // Only sideways: up and down still scroll the page.
                    if abs(g.translation.width) > abs(g.translation.height) * 1.3 { drag = g.translation }
                }
                .onEnded { g in
                    // Far enough, or a flick: both the drag and where it was heading count.
                    let side = abs(g.translation.width) > abs(g.translation.height) * 1.3
                    let x = g.translation.width, to = g.predictedEndTranslation.width
                    if side && x > 90 && to > 180 { approve(s) } else if side && x < -90 && to < -180 { skip(s) }
                    else { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = .zero } }
                })
    }

    /// Draft 1, 2, 3 as small chips.
    private func drafts(_ s: Suggestion) -> some View {
        HStack(spacing: 6) {
            Text("Drafts").font(.caption.weight(.semibold)).foregroundStyle(LinkedIn.muted)
            ForEach(options(s).indices, id: \.self) { i in
                let on = variant == i
                Button { Brand.select(); withAnimation(Brand.quick) { variant = i } } label: {
                    Text("\(i + 1)").font(.inter(.footnote, .semibold).monospacedDigit())
                        .frame(width: 30, height: 26)
                        .background(on ? LinkedIn.ink : .clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? .clear : LinkedIn.line))
                        .foregroundStyle(on ? .white : LinkedIn.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Draft \(i + 1)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.leading, 40)
    }

    private func stamp(_ text: String, _ color: Color) -> some View {
        Text(text).font(.nunito(.title3)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(text == "SKIP" ? 12 : -12))
    }

    private func buttons(_ s: Suggestion) -> some View {
        HStack {
            Menu {
                Button { editing = true } label: { Label("Edit, then approve", systemImage: "pencil") }
                Button { noting = true } label: { Label("Note for a redraft", systemImage: "text.bubble") }
                Divider()
                Menu {
                    ForEach(Self.wrongPost, id: \.self) { r in
                        Button(r) { decide(s, "decline", ["wrongPost": true, "reason": r], undo: nil, label: "Declined") }
                    }
                } label: { Label("Wrong post", systemImage: "hand.thumbsdown") }
                Menu {
                    ForEach(Self.badComment, id: \.self) { r in
                        Button(r) { decide(s, "decline", ["wrongPost": false, "reason": r], undo: nil, label: "Declined") }
                    }
                } label: { Label("Bad comment", systemImage: "hand.thumbsdown") }
            } label: {
                RoundIcon(icon: "ellipsis", tint: Palette.muted, size: 46, label: "More")
            }
            .menuStyle(.button).buttonStyle(.press)
            .accessibilityLabel("More: edit, note, decline")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func approve(_ s: Suggestion) {
        fly(1)
        decide(s, "approve", ["text": text(s), "variant": variant], undo: "pullback", label: "Approved")
    }

    private func skip(_ s: Suggestion) {
        fly(-1)
        decide(s, "skip", [:], undo: "unskip", label: "Skipped")
    }

    private func fly(_ side: CGFloat) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.18)) { drag = CGSize(width: side * 600, height: 40) }
    }

    /// Takes the card off the deck at once; the Mac writes the decision.
    private func decide(_ s: Suggestion, _ action: String, _ extra: [String: Any], undo: String?, label: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                gone.insert(s.id)
                drag = .zero
                variant = 0
                last = undo.map { (s, $0, label) }
            }
            let shown = last?.s.id
            await act(s, action, extra)
            try? await Task.sleep(for: .seconds(5))
            if last?.s.id == shown { withAnimation { last = nil } }
        }
    }

    private func undo() {
        guard let l = last else { return }
        withAnimation { last = nil; gone.remove(l.s.id) }
        Task { await act(l.s, l.undo, [:]) }
    }
}

struct ApprovedCard: View {
    let s: Suggestion
    let act: CopilotAct
    @State private var marking = false

    var body: some View {
        CardFrame {
            SuggestedPost(s: s, comment: s.text)
            CommentBubble(text: s.text)
            HStack {
                Button("Back to review") { Task { await act(s, "pullback", [:]) } }
                    .buttonStyle(.pill(.quiet, small: true))
                Spacer()
                Button("I posted it") { marking = true }
                    .buttonStyle(.pill(.soft, small: true))
            }
        }
        .sheet(isPresented: $marking) {
            TextSheet(title: "Posted it yourself?", text: "", button: "Mark posted",
                      hint: "The link to your comment, if you have it. It can stay empty.", allowEmpty: true) { url in
                await act(s, "posted", ["url": url])
            }
            .presentationDetents([.medium])
        }
    }
}

struct SkippedCard: View {
    let s: Suggestion
    let act: CopilotAct

    var body: some View {
        CardFrame {
            SuggestedPost(s: s, comment: s.text)
            CommentBubble(text: s.text)
            HStack {
                if let at = s.skipped {
                    Text("Skipped \(at.formatted(.relative(presentation: .named)))").font(.inter(.caption)).foregroundStyle(Palette.faint)
                }
                Spacer()
                Button("Back to review") { Task { await act(s, "unskip", [:]) } }.buttonStyle(.pill(.quiet, small: true))
            }
        }
    }
}

/// A text to write or change, then one button.
struct TextSheet: View {
    let title: String
    let text: String
    let button: String
    let hint: String?
    var allowEmpty = false
    let save: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        BrandSheet(title: title, close: { dismiss() }) {
            Button(button) {
                saving = true
                Task { await save(draft.trimmingCharacters(in: .whitespacesAndNewlines)); saving = false; dismiss() }
            }
            .buttonStyle(.pill(small: true))
            .disabled(saving || (!allowEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        } content: {
            FormCard {
                TextField("", text: $draft, axis: .vertical).font(.inter(.callout)).lineLimit(3...16).focused($focused)
            }
            if let hint { Text(hint).font(.inter(.footnote)).foregroundStyle(Palette.muted).padding(.horizontal, 4) }
        }
        .onAppear { draft = text; focused = true }
    }
}

// MARK: - Posted

/// The numbers on top of the Posted tab, as on the Mac: comments per day from the first one to today.
struct PostedTally {
    struct Day: Identifiable { var date: Date; var count: Int; var total: Int; var id: Date { date } }
    var days: [Day] = []
    var total = 0, thisWeek = 0, streak = 0, seen = 0, likes = 0, replies = 0, measured = 0

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
        var day = min(cal.startOfDay(for: first), cal.date(byAdding: .day, value: -13, to: today)!)
        var running = 0
        while day <= today {
            let n = counts[day] ?? 0
            running += n
            days.append(Day(date: day, count: n, total: running))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        thisWeek = days.suffix(7).reduce(0) { $0 + $1.count }
        var tail = days[...]
        if tail.last?.count == 0 { tail = tail.dropLast() }
        streak = tail.reversed().prefix { $0.count > 0 }.count
    }
}

struct PostedTab: View {
    let items: [Suggestion]
    @Environment(\.openURL) private var openURL

    var body: some View {
        let t = PostedTally(items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                tile("\(t.total)", "posted", "+\(t.thisWeek) in 7 days")
                tile("\(t.streak)", "streak", t.streak == 1 ? "day" : "days in a row")
                tile(LinkedIn.count(t.seen), "seen", t.measured < t.total ? "\(t.measured) of \(t.total) measured" : "\(t.likes) likes")
            }
            if !t.days.isEmpty {
                Chart(t.days.suffix(30)) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Comments", d.count))
                        .foregroundStyle(Palette.accent)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 110)
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
            }
            if items.isEmpty {
                Text("No comments posted yet.").foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.top, 30)
            }
            ForEach(items) { s in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble.fill").foregroundStyle(LinkedIn.blue)
                        Text("On \(s.post.author ?? "a post")'s post").fontWeight(.semibold).foregroundStyle(LinkedIn.ink).lineLimit(1)
                        if let at = s.posted?.at { Text("· \(at.formatted(.relative(presentation: .named)))").lineLimit(1) }
                        Spacer()
                        if let u = s.posted?.url ?? s.post.url, let url = URL(string: u) {
                            Button { openURL(url) } label: {
                                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold)).foregroundStyle(LinkedIn.blue)
                                    .frame(width: 26, height: 26).background(LinkedIn.blue.opacity(0.1), in: Circle())
                            }
                            .accessibilityLabel("Open the comment")
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                    CommentBubble(text: s.text, likes: s.latest?.likes ?? 0, replies: s.latest?.replies ?? 0, seen: s.latest?.impressions)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinkedIn.line))
                .environment(\.colorScheme, .light)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.nunito(size: 26, heavy: true, relativeTo: .title2)).monospacedDigit().foregroundStyle(Palette.ink)
            Text(label).font(.inter(.caption, .semibold)).foregroundStyle(Palette.muted)
            Text(note).font(.inter(.caption2)).foregroundStyle(Palette.faint).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
    }
}

// MARK: - The board's chats

/// The Finding or the Posting chat: watch the run and steer it with a message.
struct BoardChatView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let id: String
    let title: String
    var empty = "Nothing here yet. Find posts starts a run."
    @State private var draft = ""
    /// Some of the draft was dictated.
    @State private var spoke = false
    @State private var voice = VoiceNote()
    @FocusState private var typing: Bool

    private var chat: Chat? { live.id == id ? live.chat : nil }
    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title, subtitle: "On your Mac") { ContextRing(sessionID: id) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let chat, chat.messages.isEmpty {
                            MascotEmpty(title: "Nothing here yet", message: empty)
                        }
                        ForEach(chat?.messages ?? []) { m in
                            Bubble(message: m, files: [], show: { _ in }).equatable().id(m.id)
                        }
                        if let chat, chat.running {
                            HStack(spacing: 8) { WorkingDots(); Text(chat.workingLine) }
                                .font(.inter(.footnote, .medium)).foregroundStyle(Palette.accent)
                        }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat?.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat?.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if voice.recording {
                        HStack(spacing: 8) {
                            Button { voice.cancel() } label: {
                                Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
                                    .frame(width: 28, height: 34)
                            }
                            .accessibilityLabel("Discard recording")
                            VoiceBars(levels: voice.levels).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                        }
                    } else {
                        TextField(chat?.running == true ? "Steer it" : "Message Takes", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($typing)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, voice.recording ? 2 : 9)
                .frame(minHeight: 40)
                .overlay(alignment: .trailing) {
                    Button { Task { await toggleVoice() } } label: {
                        Image(systemName: voice.recording ? "stop.circle.fill" : "mic")
                            .font(.system(size: voice.recording ? 24 : 17)).foregroundStyle(voice.recording ? Palette.accent : Palette.muted)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.press)
                    .padding(.trailing, 2)
                    .accessibilityLabel(voice.recording ? "Stop recording" : "Record a voice message")
                }
                .padding(.trailing, 32)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border))
                if chat?.running == true && !hasText && !voice.recording {
                    Button { Task { try? await model.api.stop(id) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).frame(width: 38, height: 38)
                            .background(Palette.ink, in: Circle()).foregroundStyle(Palette.paper)
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Stop the reply")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).frame(width: 38, height: 38)
                            .background(hasText || voice.recording ? Palette.accent : Palette.well, in: Circle())
                            .foregroundStyle(hasText || voice.recording ? Color.white : Palette.faint)
                    }
                    .buttonStyle(.press)
                    .disabled(!hasText && !voice.recording)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.canvas)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let c = try? await model.api.chat(id) { model.open(id, chat: c) }
        }
        .onDisappear {
            voice.cancel()
            if model.chatID == id { model.chatID = nil }
        }
    }

    /// Stopping puts what was said into the box, after anything typed, to check.
    private func toggleVoice() async {
        guard voice.recording else {
            typing = false
            await voice.start()
            if let e = voice.error { model.error = e }
            return
        }
        let said = await voice.stop()
        guard !said.isEmpty else { return }
        let have = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = have.isEmpty ? said : have + " " + said
        spoke = true
    }

    /// While Claude works, the message steers the run. The arrow while recording stops and sends.
    private func send() {
        Task {
            if voice.recording { await toggleVoice() }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let dictated = spoke
            draft = ""
            spoke = false
            let from = id.hasPrefix("board:comments") ? "Comments" : id.hasPrefix("board:performance") ? "Performance" : nil
            if !(await model.say(text, in: id, from: from, voice: dictated)) { draft = text; spoke = dictated }
        }
    }
}
