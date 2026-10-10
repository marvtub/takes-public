import SwiftUI

/// How full Claude's context is, as on the Mac: a ring and a percentage in the chat's top bar,
/// "Compacting" while it compacts. A tap opens Conversation memory, with Compact now (2026-10-09:
/// the Mac's popover, not a system dialog).
struct ContextRing: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let sessionID: String
    let open: () -> Void

    var body: some View {
        if model.chatID == sessionID, let chat = live.chat, !chat.messages.isEmpty {
            let f = chat.context.map { $0.window > 0 ? min(Double($0.used) / Double($0.window), 1) : 0 } ?? 0
            let tint = f >= 0.7 ? Palette.accentInk : Palette.muted
            Button { Brand.select(); open() } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(Palette.border, lineWidth: 2)
                        Circle().trim(from: 0, to: f)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    Text(chat.compacting ? "Compacting" : chat.context == nil ? "–" : "\(Int((f * 100).rounded()))%")
                        .font(.inter(.caption, .semibold)).monospacedDigit().lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(tint)
                .padding(.horizontal, 10).frame(height: 32)
                .background(Palette.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border))
            }
            .buttonStyle(.press)
            .disabled(chat.compacting)
            .accessibilityLabel(chat.compacting ? "Compacting the conversation" : "Context \(Int((f * 100).rounded())) percent full")
        }
    }

    static func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// The Mac meter's popover: how full, what that means, and Compact.
struct MemoryCard: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let sessionID: String
    let close: () -> Void

    var body: some View {
        let chat = live.chat
        let c = chat?.context
        let f = c.map { $0.window > 0 ? min(Double($0.used) / Double($0.window), 1) : 0 } ?? 0
        let tint = f >= 0.7 ? Palette.accentInk : Palette.muted
        CardOverlay(close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Conversation memory").font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.border)
                        Capsule().fill(tint).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 5)
                Text(c.map { "\(Int((f * 100).rounded()))% full: \(ContextRing.short($0.used)) of \(ContextRing.short($0.window)) tokens." } ?? "The size shows after the next reply.")
                    .font(.inter(.subheadline, .medium)).monospacedDigit().foregroundStyle(Palette.ink)
                Text("This is the conversation itself, not work that runs. When it is full, Takes compacts it: it keeps a short summary and drops the details. Compact earlier to start a new topic with a clean slate.")
                    .font(.inter(.subheadline)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: close).buttonStyle(.pill(.quiet, small: true))
                    Button(chat?.running == true ? "Compact when Takes is done" : "Compact now") {
                        close()
                        Task { _ = await model.say("/compact", in: sessionID) }
                    }
                    .buttonStyle(.pill(.ink, small: true))
                    .disabled(chat?.messages.isEmpty != false)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// The Mac chat's tools: New conversation, Past conversations, Compact. Access and the folder stay
/// on the Mac.
struct ChatTools: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let sessionID: String
    @Binding var open: Bool
    let past: () -> Void

    var body: some View {
        let has = live.chat?.messages.isEmpty == false
        PanelRow(icon: "square.and.pencil", title: "New conversation", enabled: has) {
            close()
            Task {
                do {
                    let d = try await model.act("/api/chat/new", ["id": sessionID])
                    if let c = try? API.decoder.decode(Chat.self, from: d) { live.chat = c }
                    model.toast = "The last one is in Past conversations"
                } catch { model.toast = error.localizedDescription }
            }
        }
        PanelRow(icon: "clock.arrow.circlepath", title: "Past conversations…") { close(); past() }
        PanelRow(icon: "arrow.down.right.and.arrow.up.left", title: "Compact the conversation",
                 enabled: has && live.chat?.compacting != true) {
            close()
            Task { _ = await model.say("/compact", in: sessionID) }
        }
    }

    private func close() { withAnimation(Brand.quick) { open = false } }
}

struct PastChat: Codable, Hashable, Identifiable {
    var file: String
    var title: String
    var date: Date?
    var count: Int
    var id: String { file }
}

/// Past conversations, newest first: tap one to open it, the bin deletes it. The open one goes to
/// the list first, so nothing is lost.
struct PastChatsSheet: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let sessionID: String
    let close: () -> Void
    @State private var items: [PastChat]?
    @State private var failed: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: "Past conversations", cancel: "Done", close: close) { EmptyView() }
            if let items {
                if items.isEmpty {
                    MascotEmpty(title: "None yet", message: "\"New conversation\" keeps the old one here.").frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, p in row(p).arrive(min(i, 6)) }
                        }
                        .padding(8)
                    }
                }
            } else if let failed {
                MascotEmpty(title: "Can't load them", message: failed, mood: .sorry).frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let failed, items != nil { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger).padding() }
        }
        .background(Palette.paper.ignoresSafeArea())
        .task { await load() }
    }

    private func row(_ p: PastChat) -> some View {
        HStack(spacing: 8) {
            Button { resume(p) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(.inter(.callout, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(detail(p)).font(.inter(.footnote)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .disabled(live.chat?.running == true)
            .accessibilityLabel("Open \(p.title)")
            Button { forget(p) } label: {
                Image(systemName: "trash").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.faint).frame(width: 40, height: 44)
            }
            .buttonStyle(.press)
            .accessibilityLabel("Delete \(p.title)")
        }
    }

    private func detail(_ p: PastChat) -> String {
        let n = "\(p.count) message\(p.count == 1 ? "" : "s")"
        guard let d = p.date else { return n }
        return "\(d.formatted(.relative(presentation: .named))) · \(n)"
    }

    private func load() async {
        do {
            let d = try await model.act("/api/chat/history", ["id": sessionID], nil, method: "GET")
            items = try API.decoder.decode([PastChat].self, from: d)
        } catch { failed = error.localizedDescription }
    }

    private func resume(_ p: PastChat) {
        Task {
            do {
                let d = try await model.act("/api/chat/history", ["id": sessionID], ["action": "resume", "file": p.file])
                if let c = try? API.decoder.decode(Chat.self, from: d) { live.chat = c }
                close()
            } catch { failed = error.localizedDescription }
        }
    }

    private func forget(_ p: PastChat) {
        Brand.select()
        withAnimation(Brand.quick) { items?.removeAll { $0.id == p.id } }
        Task { if let e = await model.tryAct("/api/chat/history", ["id": sessionID], ["action": "forget", "file": p.file]) { failed = e } }
    }
}
