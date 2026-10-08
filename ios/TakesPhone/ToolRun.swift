import SwiftUI

/// What the chat draws: a message, or a run of tool calls in a row. Runs of three or more fold up,
/// as on the Mac (ChatItem in Chat.swift). Before, the phone listed every step (2026-10-06).
enum ChatItem: Identifiable, Hashable {
    case message(Message)
    case tools([Message])

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .tools(let t): return t[0].id
        }
    }

    static let foldAt = 3

    static func group(_ messages: [Message]) -> [ChatItem] {
        var items: [ChatItem] = []
        var run: [Message] = []
        func flush() {
            if run.count >= foldAt { items.append(.tools(run)) } else { items += run.map(ChatItem.message) }
            run = []
        }
        for m in messages {
            if m.role == .tool { run.append(m) } else { flush(); items.append(.message(m)) }
        }
        flush()
        return items
    }

    /// One line for a finished run: "6 steps · Bash, Read".
    static func summary(_ tools: [Message]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for t in tools {
            let name = t.text.components(separatedBy: " · ").first ?? t.text
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let names = order.enumerated().sorted { (counts[$0.1]!, -$0.0) > (counts[$1.1]!, -$1.0) }.map(\.1)
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(tools.count) steps · \(shown)"
    }
}

/// The messages of a chat with tool runs folded. The session chat and the Copilot chat use it.
/// Only the newest `page` items are drawn: the chat is a plain stack (2026-10-06), so a long
/// history cost layout on every open and every streamed word. Older ones come a page at a time,
/// and the chat stays on the message you read (2026-10-08).
struct ChatItems: View {
    let messages: [Message]
    let running: Bool
    let bubble: (Message) -> Bubble
    static let page = 80
    @State private var shown = Self.page

    var body: some View {
        let all = ChatItem.group(messages)
        let items = all.count > shown ? Array(all.suffix(shown)) : all
        if items.count < all.count, let top = items.first?.id {
            ScrollViewReader { proxy in
                Button {
                    shown += Self.page
                    // Keep the message that was on top where it was.
                    DispatchQueue.main.async { proxy.scrollTo(top, anchor: .top) }
                } label: {
                    Text("Show earlier messages").font(.inter(.footnote, .medium)).foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.press)
            }
        }
        ForEach(items) { item in
            switch item {
            case .message(let m): bubble(m).equatable().id(m.id)
            case .tools(let t): ToolRun(tools: t, active: running && item.id == items.last?.id).id(item.id)
            }
        }
    }
}

/// One tool call: a turning ring while it runs, a tick when done.
struct ToolLine: View {
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ToolSpinner().transition(.opacity)
                }
            }
            .frame(width: 14, height: 14)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.caption.monospaced()).foregroundStyle(Palette.faint)
        .animation(Brand.quick, value: done)
    }
}

/// Three or more tool calls in a row. While they run, only the newest shows under a count of the
/// earlier ones; once done, one line. A tap opens the full list.
struct ToolRun: View {
    let tools: [Message]
    /// The run Takes is still adding to.
    let active: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Brand.quick) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 14, height: 14)
                    Text(label).lineLimit(1).truncationMode(.tail)
                }
                .font(.caption.monospaced()).foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel(open ? "Hide the steps" : "Show every step")
            .accessibilityValue(label)
            if open {
                ForEach(tools) { ToolLine(text: $0.text, done: $0.done) }
            } else if running, let last = tools.last {
                ToolLine(text: last.text, done: last.done).id(last.id)
                    .transition(.opacity)
            }
        }
        .animation(Brand.quick, value: tools.count)
    }

    private var running: Bool { active || tools.contains { !$0.done } }

    private var label: String {
        if open { return "\(tools.count) steps" }
        return running ? "\(tools.count - 1) earlier steps" : ChatItem.summary(tools)
    }
}

/// A thin ring that turns, as on the Mac. Driven by the clock (see WorkingDots for why).
private struct ToolSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.7)
                .stroke(Palette.faint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
    }
}
