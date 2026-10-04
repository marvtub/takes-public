import SwiftUI
import UIKit

// Comments on the script and the post, like on the Mac: select words and tap Comment, or comment
// on all of it. They land in the session's comments.json; Claude reads them and replies.

/// Text that can be selected for a comment. Quoted words of open comments are tinted.
struct CommentableText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let quotes: [String]
    var color = UIColor(Palette.ink)
    let comment: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.comment = comment
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let ns = text as NSString
        for q in quotes where !q.isEmpty {
            let r = ns.range(of: q)
            if r.location != NSNotFound { s.addAttribute(.backgroundColor, value: UIColor(Palette.accent).withAlphaComponent(0.22), range: r) }
        }
        if v.attributedText != s { v.attributedText = s }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width
        return CGSize(width: w, height: v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var comment: ((String) -> Void)?

        func textView(_ v: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let quote = (v.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return UIMenu(children: suggestedActions) }
            let add = UIAction(title: "Comment", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.comment?(quote)
            }
            return UIMenu(children: [add] + suggestedActions)
        }
    }
}

/// What a new comment is about: a quote, or nil for all of the text.
struct CommentDraft: Identifiable {
    let quote: String?
    var id: String { quote ?? "" }
}

extension CommentedText where Framed == AnyView, Below == EmptyView {
    init(sessionID: String, file: String, text: String, font: UIFont, what: String) {
        self.init(sessionID: sessionID, file: file, text: text, font: font, what: what, frame: { $0 }, below: { EmptyView() })
    }
}

/// The text with its comments below it, and the sheet to write one.
struct CommentedText<Framed: View, Below: View>: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let file: String
    let text: String
    let font: UIFont
    let what: String
    var color = UIColor(Palette.ink)
    /// Wraps the selectable text (the post's LinkedIn card).
    @ViewBuilder var frame: (AnyView) -> Framed
    /// Shown between the text and its comments.
    @ViewBuilder var below: () -> Below
    @State private var comments: [Comment] = []
    @State private var draft: CommentDraft?
    @State private var showResolved = false

    private var mine: [Comment] { comments.filter { $0.file == file } }
    private var open: [Comment] { mine.filter(\.open) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            frame(AnyView(CommentableText(text: text, font: font, quotes: open.compactMap(\.quote), color: color) { draft = CommentDraft(quote: $0) }))
            Button { draft = CommentDraft(quote: nil) } label: {
                Label("Comment on the whole \(what)", systemImage: "text.bubble")
            }
            .buttonStyle(.pill(.soft, small: true))
            Text("Select words to comment on them.").font(.inter(.caption)).foregroundStyle(Palette.faint)
            below()
            if !mine.isEmpty { list }
        }
        .task(id: file) { await load() }
        .sheet(item: $draft) { d in
            NewComment(quote: d.quote, what: what) { text in
                guard let c = await model.comment(sessionID, file: file, quote: d.quote, text: text) else { return false }
                comments.append(c)
                return true
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Comments").font(.nunito(.headline))
                Text("\(open.count) open").font(.inter(.caption)).foregroundStyle(Palette.muted)
                Spacer()
                if mine.count > open.count {
                    Button(showResolved ? "Hide resolved" : "Show resolved") { withAnimation(Brand.quick) { showResolved.toggle() } }
                        .font(.inter(.caption, .semibold)).foregroundStyle(Palette.accent).buttonStyle(.press)
                }
            }
            ForEach(mine.filter { $0.open || showResolved }) { c in
                CommentCard(comment: c, sessionID: sessionID) { await load() }
            }
        }
    }

    func load() async {
        if let c = await model.comments(sessionID) { comments = c }
    }
}

struct CommentCard: View {
    @EnvironmentObject var model: Model
    let comment: Comment
    let sessionID: String
    let changed: () async -> Void
    @State private var replying = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = comment.place {
                Label(p, systemImage: comment.rect == nil ? "film" : "viewfinder")
                    .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(Palette.accent)
            }
            if let q = comment.quote {
                Text("“\(q)”").font(.inter(.footnote)).italic().foregroundStyle(Palette.muted).lineLimit(3)
                    .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 2) }
            }
            Text(comment.text)
            ForEach(Array((comment.replies ?? []).enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.by == "claude" ? "Takes" : "You").font(.inter(.caption, .semibold)).foregroundStyle(Palette.muted)
                    Text(r.text).font(.inter(.subheadline))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if replying {
                HStack {
                    TextField("Reply", text: $reply, axis: .vertical).font(.inter(.callout))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Palette.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("Send") {
                        let t = reply
                        Task {
                            await model.reply(sessionID, comment: comment.id, text: t)
                            reply = ""; replying = false
                            await changed()
                        }
                    }
                    .buttonStyle(.pill(small: true))
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 16) {
                Text(comment.open ? "Open" : "Resolved").font(.inter(.caption, .semibold))
                    .foregroundStyle(comment.open ? Palette.accent : Palette.live)
                Spacer()
                Button("Reply") { withAnimation(Brand.spring) { replying.toggle() } }
                    .buttonStyle(.pill(.quiet, small: true))
                Button(comment.open ? "Resolve" : "Reopen") {
                    Task { await model.resolve(sessionID, comment: comment.id, comment.open); await changed() }
                }
                .buttonStyle(.pill(comment.open ? .soft : .quiet, small: true))
            }
        }
        .padding(14)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
        .opacity(comment.open ? 1 : 0.6)
    }
}

struct NewComment: View {
    let quote: String?
    let what: String
    /// On a video or picture: where the comment points ("0:03.2–0:06.0 · area").
    var place: String? = nil
    /// "Mark an area" or "Pick a range": closes the sheet to mark more.
    var more: [(String, String, () -> Void)] = []
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        BrandSheet(title: "Comment", close: { dismiss() }) {
            Button("Save") {
                saving = true
                Task {
                    if await save(text.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() } else { failed = true }
                    saving = false
                }
            }
            .buttonStyle(.pill(small: true))
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
        } content: {
            if let place {
                FormCard(title: "On") {
                    Text(place).font(.inter(.callout).monospacedDigit()).foregroundStyle(Palette.muted)
                    ForEach(more, id: \.0) { m in
                        Button { dismiss(); m.2() } label: { Label(m.0, systemImage: m.1) }
                            .buttonStyle(.pill(.soft, small: true))
                    }
                }
            } else {
                FormCard(title: quote == nil ? "The whole \(what)" : "On") {
                    if let quote { Text("“\(quote)”").font(.inter(.callout)).italic().foregroundStyle(Palette.muted).lineLimit(6) }
                    else { Text("No words selected: this comment is about all of it.").font(.inter(.callout)).foregroundStyle(Palette.muted) }
                }
            }
            FormCard(title: "Comment") {
                TextField("What should change?", text: $text, axis: .vertical).font(.inter(.callout)).lineLimit(3...10).focused($focused)
            }
            if failed { Text("Could not reach the Mac. Try again.").font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger) }
        }
        .onAppear { focused = true }
    }
}
