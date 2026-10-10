import SwiftUI

// The open-comments chip above the chat's message box, as on the Mac (Sources/Takes/OpenComments.swift,
// 2026-10-05 on the phone): tap it for the list. Each comment can go to Takes alone or be resolved;
// Fix all hands Takes every one.

extension Comment {
    /// Where the comment is, short: "v17 @ 0:12", "shot s4", "the script".
    var spot: String {
        if let shot { return "shot \(shot)" }
        if file == "script.md" { return "the script" }
        if file.hasPrefix("variants/") { return "a script variant" }
        if file.hasPrefix("posts/") { return "the post" }
        let name = (file as NSString).lastPathComponent
        let v = name.range(of: #"-v(\d+)\.[^.]+$"#, options: .regularExpression)
            .map { "v" + name[$0].dropFirst(2).prefix { $0.isNumber } } ?? name
        return start.map { "\(v) @ \(Comment.stamp($0))" } ?? v
    }

    /// The chat message that hands this one comment to Takes (the Mac's Comment.ask).
    var ask: String {
        let said = text.count > 300 ? String(text.prefix(300)) + "…" : text
        return "Fix my comment \(id) on \(spot): \"\(said.replacingOccurrences(of: "\n", with: " "))\". "
            + "Read it with get_comments (it has the frame), fix it in the newest version, "
            + "and reply_comment with resolve=true."
    }

    /// The Mac's ClaudeChat.commentsAsk.
    static let fixAll = "I left comments in Takes, some maybe on older versions. Read them with get_comments, "
        + "fix them in the newest version, and reply to each one (resolve=true when it is fixed)."
}

struct OpenCommentsChip: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let count: Int
    let send: (String) -> Void
    @State private var open: [Comment] = []
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                Text("\(count) open comment\(count == 1 ? "" : "s")")
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
            }
            .font(.inter(.caption, .medium)).foregroundStyle(Palette.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.accentSoft, in: Capsule())
        }
        .buttonStyle(.press)
        .accessibilityHint("Shows your open comments: send one to Takes or resolve it")
        .sheet(isPresented: $shown) { list.presentationDetents([.medium, .large]) }
        .task(id: count) { await load() }
    }

    private func load() async {
        if let c = await model.comments(sessionID) { open = c.filter(\.open) }
    }

    private var list: some View {
        NavigationStack {
            List {
                ForEach(open) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.spot).font(.inter(.caption, .semibold)).foregroundStyle(Palette.muted)
                        Text(c.text).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(4)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button { resolve(c) } label: { Label("Resolve", systemImage: "checkmark") }.tint(Palette.live)
                    }
                    .swipeActions(edge: .leading) {
                        Button { shown = false; send(c.ask) } label: { Label("Send", systemImage: "paperplane") }.tint(Palette.accent)
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if open.isEmpty { MascotEmpty(title: "No open comments", message: "All resolved.") } }
            .navigationTitle("Open comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fix all") { shown = false; send(Comment.fixAll) }.disabled(open.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { shown = false } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Swipe right to send one to Takes, left to resolve it.")
                    .font(.inter(.caption)).foregroundStyle(Palette.faint).padding(.bottom, 8)
            }
        }
    }

    private func resolve(_ c: Comment) {
        withAnimation(.snappy) { open.removeAll { $0.id == c.id } }
        Task { await model.resolve(sessionID, comment: c.id, true) }
    }
}
