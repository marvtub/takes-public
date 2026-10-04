import SwiftUI

// The open-comments chip above the chat's message box (2026-10-04). It says where the comments
// are ("v17"), and a click lists them: each one can be opened at its moment, sent to Takes alone,
// or resolved. Before, the chip only sent them all, and a comment on an older version of an edit
// stayed out of sight while the user watched the newest one.

extension Comment {
    /// Where the comment is, short: "v17 @ 0:12", "shot s4", "the script".
    var place: String {
        if let shot { return "shot \(shot)" }
        if file == "script.md" { return "the script" }
        if file.hasPrefix("variants/") { return "a script variant" }
        let name = URL(fileURLWithPath: file).lastPathComponent
        let v = StyleLib.split(name).version.map { "v\($0)" } ?? name
        return start.map { "\(v) @ \(Comment.stamp($0))" } ?? v
    }

    /// The version alone, for the chip: "v17", or the place when there is no version.
    var version: String {
        guard shot == nil else { return "the storyboard" }
        return StyleLib.split(URL(fileURLWithPath: file).lastPathComponent).version.map { "v\($0)" } ?? place
    }

    /// The chat message that hands this one comment to Takes.
    var ask: String {
        let said = text.count > 300 ? String(text.prefix(300)) + "…" : text
        return "Fix my comment \(id) on \(place): \"\(said.replacingOccurrences(of: "\n", with: " "))\". "
            + "Read it with get_comments (it has the frame), fix it in the newest version, "
            + "and reply_comment with resolve=true."
    }
}

enum OpenCommentsLabel {
    /// "1 open comment · v17", "3 open comments · v17" when they share a version, else just the count.
    static func text(_ open: [Comment], count: Int) -> String {
        let n = "\(count) open comment\(count == 1 ? "" : "s")"
        let versions = Set(open.map(\.version))
        guard versions.count == 1, let v = versions.first, open.count == count else { return n }
        return "\(n) · \(v)"
    }
}

struct OpenCommentsChip: View {
    @Environment(AppModel.self) var app
    let session: URL
    let count: Int
    let send: (String) -> Void
    @State private var open: [Comment] = []
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                Text(OpenCommentsLabel.text(open, count: count))
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold))
            }
            .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(PressStyle())
        .help("See your open comments: open one, send it to Takes or resolve it")
        .popover(isPresented: $shown, arrowEdge: .top) { list }
        .onAppear(perform: load)
        .onChange(of: count) { _, _ in load() }
    }

    private func load() {
        open = CommentStore.read(session).comments.filter(\.open)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Open comments").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    shown = false
                    send(ClaudeChat.commentsAsk)
                } label: {
                    Text("Fix all").font(Theme.sans(11.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .help("Takes reads all your open comments, fixes them and replies to each one")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(open) { c in
                        row(c)
                        if c.id != open.last?.id { Divider().padding(.leading, 14) }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 340)
        .background(Theme.paper)
    }

    private func row(_ c: Comment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.place).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.muted)
                Text(c.text).font(Theme.sans(12.5)).foregroundStyle(Theme.ink).lineLimit(3)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if canJump(c) {
                    icon("arrow.up.forward.square", "Open \(c.place)") { jump(c) }
                }
                icon("paperplane", "Send this comment to Takes") { shown = false; send(c.ask) }
                icon("checkmark.circle", "Resolve") { resolve(c) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    private func canJump(_ c: Comment) -> Bool {
        if c.shot != nil || c.file == "script.md" || c.file.hasPrefix("variants/") { return true }
        let k = Asset.kind(of: session.appending(path: c.file))
        return k == .video || k == .image
    }

    /// Opens the comment's file at its moment, on the tab that shows it.
    private func jump(_ c: Comment) {
        shown = false
        if c.shot != nil {
            SessionMode.set(.storyboard)
        } else if c.file == "script.md" || c.file.hasPrefix("variants/") {
            SessionMode.set(.record)
        } else {
            SessionMode.set(.assets)
            app.jump(to: session.appending(path: c.file), at: c.start)
        }
    }

    private func resolve(_ c: Comment) {
        CommentStore.change(session) { f in
            if let i = f.comments.firstIndex(where: { $0.id == c.id }) { f.comments[i].status = "resolved" }
        }
        withAnimation(Theme.motion) { open.removeAll { $0.id == c.id } }
        if open.isEmpty { shown = false }
    }
}
