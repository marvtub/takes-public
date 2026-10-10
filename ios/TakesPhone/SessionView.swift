import AVKit
import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SessionView: View {
    @EnvironmentObject var model: Model
    let session: Session
    @State private var detail: SessionDetail?
    @State private var tab = Tab.chat
    @State private var recording: RecordMode?
    @State private var showing: RemoteFile?
    @State private var failed: String?
    @State private var shooting: Shot?
    /// Something was said in the chat (the live chat streams outside this view).
    @State private var talked = false
    /// The More panel, and the cards it opens (2026-10-09).
    @State private var more = false
    @State private var confirm: Confirm?
    @State private var ask: NameAsk?
    /// The chat's memory card, tools panel and past conversations (2026-10-09).
    @State private var memory = false
    @State private var chatTools = false
    @State private var pastChats = false
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case chat = "Chat", files = "Files", script = "Script", board = "Board", post = "Post" }
    enum RecordMode: String, Identifiable { case prompter, camera; var id: String { rawValue } }

    /// The Mac's meta line: project · takes.
    private var meta: String {
        let n = detail.map { Set($0.files.compactMap(\.take)).count } ?? session.takes
        return "\(detail?.session.project ?? session.project) · \(n) take\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: detail?.session.title ?? session.title, subtitle: meta) {
                if tab == .chat {
                    ContextRing(sessionID: session.id) { memory = true }
                    // The Mac chat's tools: new, past conversations, compact.
                    Button { Brand.select(); withAnimation(Brand.quick) { chatTools.toggle() } } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.muted)
                            .frame(width: 36, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("Conversations")
                }
                // The Mac header's More: our own panel, not a system menu.
                Button { Brand.select(); withAnimation(Brand.quick) { more.toggle() }; Task { await model.loadProjects() } } label: {
                    RoundIcon(icon: "ellipsis", size: 40, label: "More")
                }
                .buttonStyle(.press)
                .disabled(detail == nil)
                // The Mac's red record dot. A tap records with the script; a long press uses the
                // Camera app (no system menu, 2026-10-04).
                Button { recording = .prompter } label: {
                    RoundIcon(icon: "circle.fill", tint: Palette.danger, size: 44, filled: true, label: "Record a take")
                }
                .buttonStyle(.press)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in Brand.tap(.medium); recording = .camera })
                .accessibilityAction(named: "Record with the Camera app") { recording = .camera }
            }
            // A new video shows only its chat: the tabs come once there is something in them.
            if !blank {
                Segments(items: Tab.allCases, selection: $tab, title: \.rawValue)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                if let detail {
                    switch tab {
                    case .chat: ChatView(session: session, detail: detail, show: { showing = $0 }, record: { recording = .prompter })
                    case .files: FilesView(detail: detail, show: { showing = $0 }, reload: { await reload() })
                    case .script: ScriptView(sessionID: session.id, detail: detail, reload: { await reload() })
                    case .board: BoardView(sessionID: session.id, detail: detail, show: { showing = $0 },
                                           record: { shooting = $0 }, reload: { await reload() }, toChat: { tab = .chat })
                    case .post: PostView(sessionID: session.id, post: detail.post, posts: detail.posts ?? [], sides: detail.sides ?? [], profile: detail.profile,
                                         show: { showing = $0 }, files: detail.files, reload: { await reload() })
                    }
                } else if let failed {
                    MascotEmpty(title: "Can't load the video", message: failed, mood: .sorry)
                        .frame(maxHeight: .infinity)
                } else {
                    WorkingDots().frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                // Talk or type to Claude from any tab, not only the chat.
                // The Board has its own note field per shot: one field on screen, not two (2026-10-04).
                if detail != nil && tab != .chat && tab != .board { QuickSay(sessionID: session.id, toChat: { tab = .chat }, from: tab.rawValue) }
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .overlay {
            if more {
                FloatingPanel(open: $more) {
                    SessionMore(session: session, detail: detail, open: $more, confirm: $confirm, ask: $ask,
                                left: { dismiss() }, reload: { await reload() })
                }
            }
        }
        .overlay {
            if chatTools {
                FloatingPanel(open: $chatTools) {
                    ChatTools(sessionID: model.resolve(session.id), open: $chatTools) { pastChats = true }
                }
            }
        }
        .overlay { if memory { MemoryCard(sessionID: session.id) { memory = false } } }
        .animation(Brand.quick, value: memory)
        .sheet(isPresented: $pastChats) { PastChatsSheet(sessionID: model.resolve(session.id)) { pastChats = false } }
        .asks(confirm: $confirm, name: $ask)
        .overlay(alignment: .bottom) { Toast(text: $model.toast) }
        .animation(Brand.quick, value: model.toast)
        .toolbar(.hidden, for: .navigationBar)
        .animation(Brand.spring, value: blank)
        .task {
            // Last time's copy first, then the Mac's.
            if detail == nil {
                let key = "session-" + session.id
                if let d = await Task.detached(priority: .userInitiated, operation: { Cache.load(SessionDetail.self, key) }).value,
                   detail == nil { detail = model.patch(d) }
            }
            await reload(read: true)
        }
        // Opened before the Mac answered (just after Face ID): load it as soon as it does.
        .onChange(of: model.connected) { _, on in if on { Task { await reload(read: true) } } }
        .onDisappear { if model.chatID == session.id { model.chatID = nil } }
        .onReceive(model.live.$chat.map { $0?.messages.isEmpty == false }.removeDuplicates()) { if $0 && model.chatID == session.id { talked = true } }
        .fullScreenCover(item: $recording) { mode in
            switch mode {
            case .prompter:
                PrompterRecorder(script: detail?.script ?? "", sessionID: session.id,
                                 send: { model.outbox.take($0, name: "phone-take.mov", session: session.id, asTake: true, shot: nil) },
                                 close: { recording = nil }, toChat: { recording = nil; tab = .chat })
            case .camera:
                CameraPicker { url in
                    recording = nil
                    if let url { model.outbox.take(url, name: "phone-take." + url.pathExtension.lowercased(), session: session.id, asTake: true, shot: nil) }
                }
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(item: $shooting) { shot in
            // A take for one storyboard shot: the prompter shows only its lines.
            PrompterRecorder(script: shot.say, sessionID: session.id,
                             send: { model.outbox.take($0, name: "phone-take.mov", session: session.id, asTake: true, shot: shot.id) },
                             close: { shooting = nil }, toChat: { shooting = nil; tab = .chat })
        }
        .fullScreenCover(item: $showing) { f in
            Viewer(file: f, sessionID: session.id, onDone: { showing = nil; Task { await reload() } },
                   toChat: { showing = nil; tab = .chat })
        }
        .safeAreaInset(edge: .bottom) { UploadsBar(uploads: model.uploads, outbox: model.outbox, sessionID: model.resolve(session.id)) }
        // A change reached the Mac, or a new one waits: show the session as it is now.
        .onReceive(model.outbox.$delivered.dropFirst()) { _ in Task { await reload() } }
        .onReceive(model.outbox.$ops.map(\.count).removeDuplicates().dropFirst()) { _ in Task { await reload() } }
    }

    /// Nothing said, written or recorded yet.
    private var blank: Bool {
        guard let detail else { return false }
        return !talked && detail.chat.messages.isEmpty && !detail.chat.running && detail.files.isEmpty
            && detail.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fetches the session again. Only the first load marks the chat read; the rest (polls,
    /// closing a file) change nothing when nothing changed.
    func reload(read: Bool = false) async {
        let key = "session-" + session.id
        do {
            guard model.connected else { throw URLError(.notConnectedToInternet) }
            let raw = try await model.api.detail(session.id)
            if failed != nil { failed = nil }
            Task.detached(priority: .utility) { Cache.save(raw, key) }
            let d = model.patch(raw)
            model.open(session.id, chat: d.chat, read: read)
            guard d != detail else { return }
            detail = d
        } catch {
            // Offline: the phone's copy, with the changes that wait on top.
            if let raw = await Task.detached(operation: { Cache.load(SessionDetail.self, key) }).value {
                let d = model.patch(raw)
                if model.chatID == session.id || model.chatID == nil { model.open(session.id, chat: d.chat, read: false) }
                if d != detail { detail = d }
            }
            if detail == nil { failed = error.localizedDescription }
        }
    }
}

// MARK: - Chat

/// Session and board chats share one scroll owner. Follow measured layout, not incoming text:
/// the keyboard, wrapping and working line can all change the bottom after an event arrives.
struct ChatTranscript<Content: View>: View {
    var latestRequest: Int
    @ViewBuilder var content: () -> Content
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = ChatScrollState()

    private struct Layout: Equatable {
        var content: CGSize
        var viewport: CGSize
        var distanceFromBottom: CGFloat
    }

    var body: some View {
        ScrollView {
            // Lazy height estimates can move the bottom past the actual messages during a
            // keyboard resize or a long streamed reply (2026-10-06). Measure real rows instead.
            VStack(alignment: .leading, spacing: 10) {
                content()
                Color.clear.frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            // Exactly the screen's width: a long chat measured 0.67 pt wider than the scroll view,
            // and the chat could be pulled sideways (2026-10-06).
            .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityIdentifier("chat-transcript")
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating:
                follow.userScrollStarted()
                follow.userScrolled(distanceFromBottom: distance(context.geometry))
            case .idle:
                if follow.browsing {
                    follow.userScrollEnded(distanceFromBottom: distance(context.geometry))
                }
            default: break
            }
        }
        .onScrollGeometryChange(for: Layout.self) { geometry in
            Layout(content: geometry.contentSize, viewport: geometry.containerSize,
                   distanceFromBottom: distance(geometry))
        } action: { old, new in
            let shouldFollow = follow.layoutChanged(distanceFromBottom: new.distanceFromBottom)
            guard old.content != new.content || old.viewport != new.viewport else { return }
            if shouldFollow { toLatest() }
        }
        .onChange(of: latestRequest) { _, _ in
            follow.latest()
            toLatest()
        }
        .overlay(alignment: .bottomTrailing) {
            if follow.showsLatest {
                Button {
                    follow.latest()
                    toLatest()
                } label: {
                    Label("Latest", systemImage: "arrow.down")
                        .font(.inter(.footnote, .medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Palette.paper, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border))
                }
                .buttonStyle(.press)
                .accessibilityLabel("Jump to latest message")
                .padding(12)
            }
        }
    }

    private func distance(_ geometry: ScrollGeometry) -> CGFloat {
        max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
    }

    private func toLatest() {
        // No competing animated scrolls while a reply streams or the keyboard moves.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
    }
}

struct ChatView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let session: Session
    let detail: SessionDetail
    let show: (RemoteFile) -> Void
    /// Opens the camera, with the script near the lens if there is one.
    let record: () -> Void
    @State private var draft = ""
    /// Some of the draft was dictated.
    @State private var spoke = false
    @State private var voice = VoiceNote()
    @State private var attached: [String] = []
    @State private var waiting: Set<Int> = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var choosingPhotos = false
    @FocusState private var typing: Bool
    @State private var latestRequest = 0
    /// The + panel (2026-10-09: Takes's own, not a system menu), and the session's files named with
    /// @ or picked there: each goes as its path on a line of its own, which Takes reads (ChatRefs).
    @State private var adding = false
    @State private var browsing = false
    @State private var refs: [String] = []

    private var chat: Chat { live.id == session.id ? (live.chat ?? detail.chat) : detail.chat }

    /// "@comments" in the box sends the open comments with the message, as on the Mac (2026-10-04):
    /// delete it to leave them out. An empty box starts with it while comments are open.
    static let commentsToken = "@comments"
    private static let commentsPattern = #"(?<!\S)@comments(?!\w)"#
    static func withoutToken(_ text: String) -> String {
        text.replacingOccurrences(of: commentsPattern + #"[ \t]?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Unsent text stays when you leave the chat or the app, as on the Mac.
    private var draftKey: String { "chatDraft." + session.id }

    private func offerComments() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.openComments > 0, typed.isEmpty { draft = Self.commentsToken + " " }
        else if detail.openComments == 0, typed == Self.commentsToken { draft = "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(latestRequest: latestRequest) {
                ChatItems(messages: chat.messages, running: chat.running) { m in
                    Bubble(message: m, files: detail.files, show: show, waiting: m.role == .user && model.outbox.ops.contains { $0.id == m.id })
                }
                if chat.running {
                    HStack(spacing: 8) { WorkingDots(); Text(chat.workingLine) }
                        .font(.inter(.footnote, .medium)).foregroundStyle(Palette.accent)
                }
            }
            .overlay { if empty { start } }
            composer
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            for item in items { Task { await upload(item) } }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $picks, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                if let id = model.uploads.send(u, name: u.lastPathComponent, to: session.id, asTake: false) { waiting.insert(id) }
            }
        }
        .onAppear {
            if draft.isEmpty, let kept = UserDefaults.standard.string(forKey: draftKey) { draft = kept }
            offerComments()
            if empty { typing = true }
            model.uploads.finished = { item in
                guard waiting.contains(item.id), let p = item.path else { return }
                waiting.remove(item.id)
                attached.append(p)
            }
        }
    }

    /// A new video: nothing said yet, no script, no files.
    private var empty: Bool {
        chat.messages.isEmpty && !chat.running && detail.files.isEmpty
            && detail.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a new video shows: talk to Claude, or just record.
    private var start: some View {
        MascotEmpty(title: "What is the video about?",
                    message: "Type or tap the mic. Takes helps with the idea and the script.") {
            Button(action: record) { Label("Just record", systemImage: "record.circle") }
                .buttonStyle(.pill(.record))
        }
    }

    /// "@" and what follows it at the end of the box, while typing a reference.
    private var atQuery: String? {
        guard let r = draft.range(of: #"(?:^|\s)@([\w.-]*)$"#, options: .regularExpression) else { return nil }
        return String(draft[r]).trimmingCharacters(in: .whitespaces).dropFirst().description
    }

    /// What an @ can name: the open comments, the storyboard's shots, the session's files.
    private var suggestions: [(id: String, icon: String, title: String, pick: () -> Void)] {
        guard let q = atQuery else { return [] }
        var out: [(String, String, String, () -> Void)] = []
        if detail.openComments > 0, q.isEmpty || "comments".hasPrefix(q.lowercased()) {
            out.append(("comments", "text.bubble", "comments · \(detail.openComments) open", { replaceAt(Self.commentsToken + " ") }))
        }
        for (i, shot) in (detail.storyboard ?? []).enumerated() where q.isEmpty || "shot\(i + 1)".hasPrefix(q.lowercased()) || shot.say.localizedCaseInsensitiveContains(q) {
            let say = shot.say.split(separator: "\n").first.map(String.init) ?? ""
            out.append(("shot-\(shot.id)", "rectangle.split.3x1", "Shot \(i + 1)\(say.isEmpty ? "" : ": \(say)")", {
                replaceAt("storyboard shot \(shot.id)\(say.isEmpty ? "" : " (“\(say)”)") ")
            }))
        }
        for f in detail.files where q.isEmpty || f.name.localizedCaseInsensitiveContains(q) {
            out.append((f.path, f.isVideo ? "film" : f.isImage ? "photo" : f.isAudio ? "waveform" : "doc", f.name, {
                replaceAt("")
                if !refs.contains(f.path) { refs.append(f.path) }
            }))
        }
        return Array(out.prefix(6)).map { (id: $0.0, icon: $0.1, title: $0.2, pick: $0.3) }
    }

    private func replaceAt(_ with: String) {
        Brand.select()
        if let r = draft.range(of: #"@[\w.-]*$"#, options: .regularExpression) { draft.replaceSubrange(r, with: with) }
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelRow(icon: "photo.on.rectangle", title: "Photos and videos") { adding = false; choosingPhotos = true }
                .accessibilityIdentifier("add-photos")
            PanelRow(icon: "folder", title: "Files") { adding = false; importing = true }
                .accessibilityIdentifier("add-files")
            if !detail.files.isEmpty {
                PanelGroup(icon: "at", title: "A file of this video", open: $browsing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(detail.files.prefix(40)) { f in
                                PanelChoice(title: f.name, checked: refs.contains(f.path)) {
                                    if let i = refs.firstIndex(of: f.path) { refs.remove(at: i) } else { refs.append(f.path) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .padding(6)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(suggestions, id: \.id) { s in PanelRow(icon: s.icon, title: s.title, action: s.pick) }
        }
        .padding(6)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if adding { addPanel }
            if !suggestions.isEmpty && typing { suggestionList }
            if detail.openComments > 0 && !voice.recording {
                OpenCommentsChip(sessionID: session.id, count: detail.openComments) { ask in
                    Task { _ = await model.say(ask, in: session.id, from: "Chat", tokens: true) }
                }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            if !attached.isEmpty || !waiting.isEmpty || !refs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(refs, id: \.self) { p in
                            HStack(spacing: 5) {
                                Image(systemName: "at")
                                Text((p as NSString).lastPathComponent).lineLimit(1)
                                Button { withAnimation(Brand.quick) { refs.removeAll { $0 == p } } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.press).accessibilityLabel("Leave out \((p as NSString).lastPathComponent)")
                            }
                            .font(.inter(.caption, .medium)).foregroundStyle(Palette.accentInk)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Palette.accentSoft, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                        }
                        ForEach(attached, id: \.self) { p in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                Text((p as NSString).lastPathComponent).lineLimit(1)
                                Button { withAnimation(Brand.quick) { attached.removeAll { $0 == p } } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.press)
                            }
                            .font(.inter(.caption, .medium)).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Palette.accentSoft, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                        }
                        if !waiting.isEmpty {
                            HStack(spacing: 6) { WorkingDots(); Text("Sending \(waiting.count)") }
                                .font(.inter(.caption, .medium)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                // The + opens Takes's own panel above the box; the pickers open from the view.
                Button { Brand.select(); withAnimation(Brand.quick) { adding.toggle(); browsing = false } } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        .rotationEffect(.degrees(adding ? 45 : 0))
                        .frame(width: 38, height: 38)
                        .background(Palette.well, in: Circle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Add files")
                // One button on the right, as in QuickSay (2026-10-03: "too messy"): the mic while
                // the box is empty, the arrow once there is something to send (it also stops a
                // recording and sends), the stop square while Claude works. Recording a take is
                // the button at the top right.
                Group {
                    if voice.recording {
                        recordingRow
                    } else {
                        TextField(chat.compacting ? "Queue a message: it goes after compacting" : "Message Takes", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($typing)
                            .accessibilityIdentifier("chat-input")
                    }
                }
                .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, voice.recording ? 2 : 9)
                .frame(minHeight: 40)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(typing ? Palette.accent.opacity(0.5) : Palette.border, lineWidth: typing ? 1.5 : 1))
                .animation(Brand.quick, value: typing)
                if chat.running && !canSend {
                    Button { Task { try? await model.api.stop(session.id) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).frame(width: 38, height: 38)
                            .background(Palette.ink, in: Circle()).foregroundStyle(Palette.paper)
                    }
                    .buttonStyle(.press)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Stop the reply")
                } else {
                    Button { if canSend { send() } else { Task { await toggleVoice() } } } label: {
                        Image(systemName: canSend ? "arrow.up" : "mic")
                            .font(.system(size: 16, weight: canSend ? .bold : .semibold)).frame(width: 38, height: 38)
                            .background(canSend ? Palette.accent : Palette.well, in: Circle())
                            .foregroundStyle(canSend ? Color.white : Palette.ink)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.press)
                    .disabled(!canSend && !waiting.isEmpty)
                    .animation(Brand.quick, value: canSend)
                    .accessibilityLabel(canSend ? "Send" : "Record a voice message")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .background(Palette.canvas)
        .animation(Brand.quick, value: attached)
        .animation(Brand.quick, value: refs)
        .animation(Brand.quick, value: atQuery)
        .onDisappear { voice.cancel() }
        .onChange(of: draft) {
            if draft.isEmpty && attached.isEmpty { spoke = false }
            let kept = Self.withoutToken(draft)
            if kept.isEmpty { UserDefaults.standard.removeObject(forKey: draftKey) } else { UserDefaults.standard.set(draft, forKey: draftKey) }
        }
        .onChange(of: detail.openComments) { _, _ in offerComments() }
    }

    /// While recording: discard on the left, the level bars and the time in place of the text.
    private var recordingRow: some View {
        HStack(spacing: 8) {
            Button { voice.cancel() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
                    .frame(width: 28, height: 34)
            }
            .accessibilityLabel("Discard recording")
            VoiceBars(levels: voice.levels).foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(voice.started ?? context.date))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.muted)
            }
        }
    }

    /// Stopping puts what was said into the message box, after anything already typed, to check.
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

    private var canSend: Bool {
        voice.recording || (waiting.isEmpty && (!Self.withoutToken(draft).isEmpty || !attached.isEmpty || !refs.isEmpty))
    }

    /// The arrow while recording stops, adds the words and sends in one tap.
    private func send() {
        if voice.recording {
            Task {
                await toggleVoice()
                if !Self.withoutToken(draft).isEmpty || !attached.isEmpty { send() }
            }
            return
        }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each named file on a line of its own: Takes reads the path, the chat shows a card.
        if !refs.isEmpty { text += (text.isEmpty ? "" : "\n\n") + refs.joined(separator: "\n") }
        if !attached.isEmpty {
            text += (text.isEmpty ? "I sent you these from my phone:" : "\n\nFrom my phone:") + "\n" + attached.joined(separator: "\n")
        }
        let before = (draft, attached, spoke)
        let named = refs
        latestRequest += 1
        draft = ""
        attached = []
        refs = []
        adding = false
        offerComments()
        Task {
            if !(await model.say(text, in: session.id, from: "Chat", voice: before.2, tokens: true)) { draft = before.0; attached = before.1; spoke = before.2; refs = named }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if isVideo, let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            if let id = model.uploads.send(movie.url, name: movie.url.lastPathComponent, to: session.id, asTake: false) { waiting.insert(id) }
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let tmp = FileManager.default.temporaryDirectory.appending(path: "outbox/photo-\(stamp)-\(UUID().uuidString.prefix(4)).\(ext)")
            try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: tmp)) != nil else { return }
            if let id = model.uploads.send(tmp, name: tmp.lastPathComponent, to: session.id, asTake: false) { waiting.insert(id) }
        }
    }
}

/// A video from Photos, copied to a file the upload can read.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appending(path: "outbox")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appending(path: received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// One chat message. A line of Claude's reply that is only a file path shows as a card, as on the Mac.
struct Bubble: View, Equatable {
    let message: Message
    let files: [RemoteFile]
    let show: (RemoteFile) -> Void
    /// Sent while the Mac was away: it waits on the phone.
    var waiting = false

    /// Same message, same files: no redraw (the closure never changes what it shows).
    nonisolated static func == (a: Bubble, b: Bubble) -> Bool { a.message == b.message && a.files == b.files && a.waiting == b.waiting }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                HStack {
                    Spacer(minLength: 48)
                    Text(CopilotFocus.shown(message.text)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Palette.ink.opacity(waiting ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 20, style: .continuous)).foregroundStyle(Palette.paper)
                        .textSelection(.enabled)
                }
                if waiting {
                    Label("Waits for the Mac", systemImage: "clock").font(.inter(.caption2)).foregroundStyle(Palette.muted)
                }
            }
        case .tool:
            ToolLine(text: message.text, done: message.done)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle").font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
        case .claude:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.pieces(message.text).enumerated()), id: \.offset) { _, p in
                    switch p {
                    case .text(let t):
                        Text(Self.markdown(t)).textSelection(.enabled)
                    case .file(let path):
                        FileCard(file: files.first { $0.path == path } ?? Self.guess(path), show: show)
                    }
                }
            }
        }
    }

    enum Piece { case text(String), file(String) }

    /// Parsed once per text: a chat that opens again, or redraws, does not split and parse every
    /// message again. Only a reply still streaming misses (2026-10-08).
    private final class Parsed { let pieces: [Piece]; init(_ p: [Piece]) { pieces = p } }
    private final class Marked { let text: AttributedString; init(_ t: AttributedString) { text = t } }
    nonisolated(unsafe) private static let parsed: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 600; return c }()
    nonisolated(unsafe) private static let marked: NSCache<NSString, Marked> = { let c = NSCache<NSString, Marked>(); c.countLimit = 1200; return c }()

    static func pieces(_ text: String) -> [Piece] {
        if let hit = parsed.object(forKey: text as NSString) { return hit.pieces }
        let out = split(text)
        parsed.setObject(Parsed(out), forKey: text as NSString)
        return out
    }

    private static func split(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var buf: [String] = []
        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(t)) }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if t.hasPrefix("/"), !t.contains(" ") || t.contains("/Movies/"), ["mp4", "mov", "png", "jpg", "jpeg", "m4a", "wav", "mp3", "aac", "md", "gif", "webp", "heic"]
                .contains((t as NSString).pathExtension.lowercased()) {
                flush()
                out.append(.file(t))
            } else {
                buf.append(line)
            }
        }
        flush()
        return out
    }

    static func markdown(_ s: String) -> AttributedString {
        if let hit = marked.object(forKey: s as NSString) { return hit.text }
        let t = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        marked.setObject(Marked(t), forKey: s as NSString)
        return t
    }

    static func guess(_ path: String) -> RemoteFile {
        let ext = (path as NSString).pathExtension.lowercased()
        let kind = ["mp4", "mov"].contains(ext) ? "video" : ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) ? "image"
            : ["wav", "mp3", "m4a", "aac", "aiff"].contains(ext) ? "audio" : "other"
        let parts = path.split(separator: "/")
        return RemoteFile(path: path, name: (path as NSString).lastPathComponent,
                          folder: parts.count > 1 ? String(parts[parts.count - 2]) : "", kind: kind, size: 0, modified: Date())
    }
}

struct FileCard: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let show: (RemoteFile) -> Void

    var body: some View {
        if file.isAudio {
            SoundCard(file: file)
        } else {
            card
        }
    }

    private var card: some View {
        Button { show(file) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if file.isVideo || file.isImage {
                    ZStack {
                        Palette.well
                        RemoteImage(url: model.api.thumb(file.path, width: 720)) { img in
                            img.resizable().scaledToFit()
                        } placeholder: { WorkingDots(color: Palette.faint) }
                        if file.isVideo {
                            Image(systemName: "play.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.accent)
                                .frame(width: 52, height: 52).background(.white, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        }
                    }
                    .frame(height: 260)  // fixed, so the chat does not jump while pictures load
                    .clipped()
                }
                HStack {
                    Image(systemName: file.isVideo ? "film" : file.isImage ? "photo" : "doc")
                    Text(file.name).lineLimit(1)
                    Spacer()
                    if let m = file.model { Text(m).font(.inter(.caption2)).foregroundStyle(Palette.faint).lineLimit(1) }
                }
                .font(.inter(.footnote, .medium)).foregroundStyle(Palette.ink)
                .padding(12)
            }
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
            .shadow(color: Palette.shadow.opacity(0.5), radius: 6, y: 2)
        }
        .buttonStyle(Pressable(scale: 0.98))
    }
}

// MARK: - Files, script, post

struct FilesView: View {
    @EnvironmentObject var model: Model
    let detail: SessionDetail
    let show: (RemoteFile) -> Void
    let reload: () async -> Void

    /// Open comments per file, for the badge on its tile.
    @State private var open: [String: Int] = [:]
    /// Sections showing all their files, not the first four.
    @State private var showAll: Set<String> = []
    /// Sections folded into a pile of small thumbnails, as on the Mac. One list for every session.
    @AppStorage("files.folded") private var foldedStore = ""
    private static let order = ["edits", "thumbnails", "takes", "stills", "generated", "uploads", "assets"]
    /// Files, B-roll or Sound: the Mac's Assets switch (2026-10-09).
    @AppStorage("filesPage") private var page = "files"
    static let firstFew = 4
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// The known folders first, then any other the Mac sends, A–Z.
    private var folders: [String] {
        let rest = Set(detail.files.map(\.folder)).subtracting(Self.order).sorted()
        return Self.order + rest
    }

    private var folded: Set<String> { Set(foldedStore.split(separator: "\n").map(String.init)) }

    private func fold(_ name: String) {
        var f = folded
        if f.contains(name) { f.remove(name) } else { f.insert(name) }
        withAnimation(.spring(duration: 0.35)) { foldedStore = f.sorted().joined(separator: "\n") }
    }

    var body: some View {
        VStack(spacing: 0) {
            Segments(items: ["files", "broll", "sound"], selection: $page, title: { ["files": "Files", "broll": "B-roll", "sound": "Sound"][$0] ?? $0 })
                .padding(.horizontal, 16).padding(.top, 10)
            switch page {
            case "broll": BrollPage(sessionID: detail.session.id).transition(.opacity)
            case "sound": SoundPage(sessionID: detail.session.id, detail: detail).transition(.opacity)
            default: files
            }
        }
    }

    private var files: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The style Takes edits this video in, as on the Mac's Assets tab.
                if let style = detail.style, !style.names.isEmpty {
                    StylePicker(sessionID: detail.session.id, project: detail.session.project, style: style).id(style)
                }
                ForEach(folders, id: \.self) { folder in
                    let list = detail.files.filter { $0.folder == folder }
                    if !list.isEmpty { section(folder, list) }
                }
                if detail.files.isEmpty {
                    MascotEmpty(title: "No files yet", message: "Record a take, or ask Takes for an edit.")
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .refreshable { await reload(); await loadComments() }
        .task(id: detail.files.count) { await loadComments() }
    }

    private func section(_ folder: String, _ list: [RemoteFile]) -> some View {
        let isFolded = folded.contains(folder)
        let all = showAll.contains(folder) || list.count <= Self.firstFew
        return VStack(alignment: .leading, spacing: 8) {
            Button { fold(folder) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                    Text(folder.prefix(1).uppercased() + folder.dropFirst()).font(.nunito(size: 18, relativeTo: .headline)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(list.count)").font(.inter(.caption, .medium)).monospacedDigit().foregroundStyle(Palette.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFolded ? "Open \(folder)" : "Fold \(folder)")
            if isFolded {
                FilePile(files: list) { fold(folder) }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(all ? list : Array(list.prefix(Self.firstFew))) { f in
                        Tile(file: f, sessionID: detail.session.id, open: open[sessionRel(f)] ?? 0, show: show, reload: { await reload() })
                    }
                }
                if list.count > Self.firstFew {
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            if showAll.contains(folder) { showAll.remove(folder) } else { showAll.insert(folder) }
                        }
                    } label: {
                        Label(showAll.contains(folder) ? "Show fewer" : "Show all \(list.count)",
                              systemImage: showAll.contains(folder) ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.pill(.soft, small: true))
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The file's path inside the session, as comments.json names it.
    private func sessionRel(_ f: RemoteFile) -> String { f.rel(in: detail.session.id) ?? f.path }

    private func loadComments() async {
        guard let c = await model.comments(detail.session.id) else { return }
        open = Dictionary(c.filter(\.open).map { ($0.file, 1) }, uniquingKeysWith: +)
    }
}

/// A folded section: small thumbnails in a loose pile. A tap opens the section again.
struct FilePile: View {
    @EnvironmentObject var model: Model
    let files: [RemoteFile]
    let open: () -> Void
    static let most = 8

    var body: some View {
        let few = Array(files.prefix(Self.most))
        Button(action: open) {
            HStack(spacing: 12) {
                HStack(spacing: -26) {
                    ForEach(Array(few.enumerated()), id: \.element.id) { i, f in
                        thumb(f)
                            .rotationEffect(.degrees([-5, 3, -2, 4, -3, 2, -4, 3][i % 8]))
                            .offset(y: [0, -2, 1, -1, 2, 0, -2, 1][i % 8])
                            .zIndex(Double(few.count - i))
                    }
                }
                if files.count > few.count {
                    Text("+\(files.count - few.count)").font(.inter(.caption, .semibold)).foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func thumb(_ f: RemoteFile) -> some View {
        Palette.well
            .frame(width: 48, height: 60)
            .overlay {
                if f.isVideo || f.isImage {
                    RemoteImage(url: model.api.thumb(f.path, width: 160)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Image(systemName: f.isAudio ? "waveform" : "doc").font(.system(size: 14)).foregroundStyle(Palette.faint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.paper, lineWidth: 1.5))
            .shadow(color: Palette.shadow.opacity(0.6), radius: 3, y: 2)
    }
}

struct Tile: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let sessionID: String
    /// Open comments on this file.
    var open = 0
    let show: (RemoteFile) -> Void
    let reload: () async -> Void

    var body: some View {
        Button { show(file) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Palette.well
                    if file.isVideo || file.isImage {
                        RemoteImage(url: model.api.thumb(file.path, width: 400)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    } else {
                        Image(systemName: file.isAudio ? "waveform" : "doc").font(.nunito(.title)).foregroundStyle(Palette.faint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if file.keeper == true {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).padding(6)
                    }
                    if open > 0 {
                        Label("\(open)", systemImage: "text.bubble.fill")
                            .font(.inter(.caption2, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Palette.accent, in: Capsule())
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .accessibilityLabel("\(open) open comment\(open == 1 ? "" : "s")")
                    }
                }
                .frame(height: 120).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(file.name).font(.inter(.caption, .medium)).lineLimit(1).foregroundStyle(Palette.ink)
                if let m = file.model { Text(m).font(.inter(.caption2)).lineLimit(1).foregroundStyle(Palette.faint) }
                if let d = file.duration { Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond))).font(.inter(.caption2)).monospacedDigit().foregroundStyle(Palette.faint) }
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
    }
}

struct ScriptView: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let detail: SessionDetail
    let reload: () async -> Void
    @State private var editing = false
    /// "main" or the variant on show, as the Mac's draft bar.
    @AppStorage private var draft: String
    @State private var history = false
    @State private var confirm: Confirm?
    @State private var ask: NameAsk?
    @State private var failed: String?
    @State private var busy = false
    /// A + was tapped: the new variant shows once it arrives, as on the Mac.
    @State private var made = false

    init(sessionID: String, detail: SessionDetail, reload: @escaping () async -> Void) {
        self.sessionID = sessionID
        self.detail = detail
        self.reload = reload
        _draft = AppStorage(wrappedValue: "main", "scriptDraft." + sessionID)
    }

    private var variants: [PostVariant] { detail.scriptVariants ?? [] }
    private var variant: PostVariant? { variants.first { $0.slug == draft } }
    private var text: String { variant?.text ?? detail.script }
    private var file: String { variant.map { "variants/\($0.slug).md" } ?? "script.md" }
    private var hooks: [PostHook] { detail.scriptHooks ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if detail.scriptVariants != nil { draftBar.arrive(0) }
                if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(Palette.danger) }
                if text.isEmpty {
                    MascotEmpty(title: "No script yet", message: "Ask Takes to write one, or write it here.")
                        .padding(.top, 30)
                } else {
                    CommentedText(sessionID: sessionID, file: file, text: text, font: Self.font, what: "script")
                        .id(draft)
                        .arrive(1)
                }
                if !hooks.isEmpty && !text.isEmpty { hookList.arrive(2) }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .refreshable { await reload() }
        .onChange(of: variants.map(\.slug), initial: true) { old, slugs in
            if made, let new = slugs.first(where: { !old.contains($0) }) { draft = new; made = false }
            if draft != "main" && !slugs.contains(draft) { draft = "main" }
        }
        .asks(confirm: $confirm, name: $ask)
        .sheet(isPresented: $editing) {
            TextEditSheet(title: variant?.name ?? "Script", text: text, font: Font(Self.font), limit: nil) { new in
                if let variant {
                    try await model.scriptDraft(sessionID, ["action": "save", "slug": variant.slug, "text": new, "base": variant.text])
                } else {
                    try await model.save("script", sessionID, text: new, base: detail.script)
                }
                // The sheet closes once the Mac has the text, not after a full reload too (2026-10-08).
                Task { await reload() }
            }
        }
        .sheet(isPresented: $history) {
            HistorySheet(title: "Script history", subtitle: detail.session.title,
                         empty: "Takes saves a version while you edit, before each take, and whenever the chat changes the script.",
                         load: {
                             let data = try await model.act("/api/script/history", ["id": sessionID], nil, method: "GET")
                             return try API.decoder.decode([Version].self, from: data)
                         },
                         restore: { v in
                             if let e = await model.tryAct("/api/script/draft", ["id": sessionID], ["action": "restore", "path": v.path]) { return e }
                             draft = v.draft == "main" || variants.contains { $0.slug == v.draft } ? v.draft : "main"
                             await reload()
                             return nil
                         }, close: { history = false })
        }
    }

    /// The Mac's DraftBar (Actions.swift), with the favorite and the Edit button.
    private var draftBar: some View {
        DraftBar(variants: variants, draft: $draft, favorite: detail.scriptFavorite ?? "", history: detail.scriptHistory ?? 0,
                 busy: busy, canNew: !text.isEmpty, new: { act(["action": "new", "from": draft]) }, showHistory: { history = true },
                 edit: (text.isEmpty ? "Write" : "Edit", { editing = true }),
                 rename: { v in
                     ask = NameAsk(title: "Rename the variant", name: v.name) { n in
                         if let e = await model.tryAct("/api/script/draft", ["id": sessionID], ["action": "rename", "slug": v.slug, "name": n]) { return e }
                         await reload()
                         return nil
                     }
                 },
                 delete: { v in
                     confirm = Confirm(title: "Delete “\(v.name)”?", message: "Takes keeps its text in the script history.", button: "Delete") {
                         if let e = await model.tryAct("/api/script/draft", ["id": sessionID], ["action": "delete", "slug": v.slug]) { return e }
                         draft = "main"
                         await reload()
                         return nil
                     }
                 },
                 promote: { v in act(["action": "promote", "slug": v.slug]) },
                 toggleFavorite: { slug in act(["action": "favorite", "slug": slug]) })
    }

    /// The script's opening options (hooks.json), as the Mac's hook picker on the Script tab.
    private var hookList: some View {
        let current = PostHook.opening(text)
        return VStack(alignment: .leading, spacing: 8) {
            Text("HOOKS").font(.inter(.caption, .semibold)).tracking(0.8).foregroundStyle(Palette.muted).padding(.top, 6)
            ForEach(hooks) { h in
                let on = h.text.trimmingCharacters(in: .whitespacesAndNewlines) == current
                Button { if !on { act(["action": "hook", "hook": h.id, "draft": draft]) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Palette.accent : Palette.faint).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.text).font(.inter(.callout)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                            if let n = h.note, !n.isEmpty { Text(n).font(.inter(.footnote)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Palette.accent : Palette.border))
                }
                .buttonStyle(.plain).disabled(busy)
                .accessibilityLabel(on ? "Hook in use: \(h.text)" : "Use hook: \(h.text)")
            }
        }
    }

    private func act(_ body: [String: String]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.scriptDraft(sessionID, body)
                failed = nil
                if body["action"] == "promote" { draft = "main" }
                if body["action"] == "new" { made = true }
                await reload()
            } catch {
                failed = error.localizedDescription
            }
        }
    }

    static let font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif)!, size: 0)
}

/// Edit the script or the post as plain text. Save sends it to the Mac, which keeps the old text
/// in history. If it changed on the Mac meanwhile, the Mac refuses and the sheet stays open.
struct TextEditSheet: View {
    let title: String
    let text: String
    let font: Font
    let limit: Int?
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var saving = false
    @State private var failed: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetBar(title: title, close: { dismiss() }) {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    failed = nil
                    Task {
                        do { try await save(draft); dismiss() } catch { failed = error.localizedDescription }
                        saving = false
                    }
                }
                .buttonStyle(.pill(small: true))
                .disabled(saving || draft == text || (limit.map { draft.count > $0 } ?? false))
            }
            if let failed {
                Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            TextEditor(text: $draft)
                .focused($focused)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            if let limit {
                Text("\(draft.count) / \(limit)").font(.inter(.caption, .medium)).monospacedDigit()
                    .foregroundStyle(draft.count > limit ? Palette.danger : Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .interactiveDismissDisabled(draft != text)
        // No focus at once: the cursor would jump to the end. Tap where the change goes.
        .onAppear { draft = text; focused = true }
    }
}

// MARK: - LinkedIn preview

/// LinkedIn's light feed colors and type, as on the Mac's post tab.
enum LinkedIn {
    static let card = Color.white
    static let ink = Color.black.opacity(0.9)
    static let muted = Color.black.opacity(0.6)
    static let line = Color.black.opacity(0.08)
    static let blue = Color(red: 0.039, green: 0.4, blue: 0.761)
    static let uiInk = UIColor.black.withAlphaComponent(0.9)
    static let body = UIFont.systemFont(ofSize: 15)

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    static func count(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(n)" }
}

struct LinkedInAvatar: View {
    @EnvironmentObject var model: Model
    let name: String
    let photo: Bool
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.86, green: 0.84, blue: 0.80))
            Text(LinkedIn.initials(name)).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(LinkedIn.muted)
            if photo {
                RemoteImage(url: model.api.profilePhoto) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
}

/// The header of a feed post: photo, name, headline, when.
struct LinkedInHeader: View {
    let name: String
    let headline: String
    let photo: Bool
    let when: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LinkedInAvatar(name: name, photo: photo)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(LinkedIn.ink)
                    Text("• You").font(.system(size: 14)).foregroundStyle(LinkedIn.muted)
                }
                Text(headline).font(.system(size: 12)).foregroundStyle(LinkedIn.muted).lineLimit(1)
                HStack(spacing: 3) {
                    Text("\(when) •").font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                    Image(systemName: "globe.americas.fill").font(.system(size: 10)).foregroundStyle(LinkedIn.muted)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(LinkedIn.muted).padding(.top, 4)
        }
    }
}

/// The post text cut after three lines with "…more", as the feed does. Tap to open it all.
struct FeedText<Open: View>: View {
    let text: String
    @Binding var expanded: Bool
    @ViewBuilder var open: () -> Open

    var body: some View {
        if expanded {
            open()
        } else {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded = true } } label: {
                Text(text).font(.system(size: 15)).foregroundStyle(LinkedIn.ink).lineSpacing(3)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // "…more" sits on the end of the third line, over a fade, as in the feed.
                    .overlay(alignment: .bottomTrailing) {
                        if text.count > 120 || text.contains("\n") {
                            Text("…more").font(.system(size: 15)).foregroundStyle(LinkedIn.muted)
                                .padding(.leading, 28)
                                .background(LinearGradient(stops: [.init(color: LinkedIn.card.opacity(0), location: 0),
                                                                   .init(color: LinkedIn.card, location: 0.45)],
                                                           startPoint: .leading, endPoint: .trailing))
                        }
                    }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Like, Comment, Repost, Send.
struct LinkedInActions: View {
    /// Icon and word side by side, one short line.
    var compact = false
    var body: some View {
        HStack(spacing: 0) {
            ForEach([("hand.thumbsup", "Like"), ("text.bubble", "Comment"), ("arrow.2.squarepath", "Repost"), ("paperplane.fill", "Send")], id: \.1) { icon, label in
                Group {
                    if compact {
                        HStack(spacing: 4) {
                            Image(systemName: icon).font(.system(size: 13))
                            Text(label).font(.system(size: 12, weight: .semibold))
                        }
                    } else {
                        VStack(spacing: 3) {
                            Image(systemName: icon).font(.system(size: 17))
                            Text(label).font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
                .foregroundStyle(LinkedIn.muted)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, compact ? 8 : 6)
        .accessibilityHidden(true)
    }
}

/// The session's LinkedIn post as it will look in the feed, with comments below and an edit button.
struct PostView: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let post: Post?
    /// Every platform's post, LinkedIn first (2026-10-05). Empty from an older Mac.
    let posts: [PlatformPost]
    /// Posts on the sides the Mac's plugins add (2026-10-07).
    let sides: [SidePost]
    let profile: Profile?
    let show: (RemoteFile) -> Void
    let files: [RemoteFile]
    let reload: () async -> Void
    /// The platform on show: linkedin, x, youtube, vertical. Remembered, as the Mac's post tab does.
    @AppStorage("postPlatform") private var platform = "linkedin"
    @State private var expanded = false
    @State private var editing = false
    /// "main", or the slug of the variant on show.
    @State private var draft = "main"
    @State private var busy = false
    /// The hook just tapped, until the reload shows it.
    @State private var picked: String?
    /// The post's saved versions (2026-10-09), as the Mac's Post history sheet.
    @State private var history = false
    /// The schedule panel, and the cards the draft bar opens (2026-10-09).
    @State private var scheduling = false
    @State private var confirm: Confirm?
    @State private var ask: NameAsk?
    /// A + was tapped: the new variant shows once it arrives.
    @State private var made = false
    @State private var failed: String?

    private var name: String { profile?.name ?? "You" }
    /// Every platform has variants and hooks, as on the Mac (2026-10-09).
    private var variants: [PostVariant] { other.map { $0.variants ?? [] } ?? post?.variants ?? [] }
    private var hooks: [PostHook] { other.map { $0.hooks ?? [] } ?? post?.hooks ?? [] }
    private var variant: PostVariant? { variants.first { $0.slug == draft } }
    /// The text of the draft on show.
    private var text: String { variant?.text ?? other?.text ?? post?.text ?? "" }
    /// The platform's own post with its plan; nil from a Mac before 2026-10-05.
    private var planned: PlatformPost? { other ?? posts.first { $0.platform == "linkedin" } }
    private var file: String { variant.map { "posts/variants/\($0.slug).md" } ?? "posts/linkedin.md" }
    /// The other platforms' posts. LinkedIn shows even with no post: it is where a post starts.
    private var others: [PlatformPost] { posts.filter { $0.platform != "linkedin" } }
    private var other: PlatformPost? { platform == "linkedin" ? nil : others.first { $0.platform == platform } }
    /// The sides with a post, in the Mac's order.
    private var sideIDs: [(id: String, name: String)] {
        var seen = Set<String>()
        return sides.compactMap { seen.insert($0.side).inserted ? ($0.side, $0.name) : nil }
    }
    private var sideOn: [SidePost] { sides.filter { $0.side == platform } }
    private var coverNow: String? { other?.cover ?? (platform == "linkedin" ? (posts.first { $0.platform == "linkedin" }?.cover ?? post?.cover) : nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !others.isEmpty || !sides.isEmpty { platforms }
                if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(.orange) }
                if !sideOn.isEmpty {
                    LaunchPhone.pane(sessionID: sessionID, posts: sideOn, reload: reload)
                } else {
                    if let other, other.platform == "article", Features.blog {
                        // The blog's own page, as the Mac's Article side (admin, Features.blog).
                        ArticlePhone.pane(sessionID: sessionID, post: other, reload: reload)
                    } else if let other { platformPost(other) } else { linkedIn }
                    if (post != nil || other != nil) && other?.platform != "article" { covers }
                }
            }
            .padding(16)
        }
        // The app's own page, light or dark: a fixed beige page put light text (chips, status,
        // Cover) on beige in dark mode (2026-10-08). The LinkedIn card stays white, as in the feed.
        .background(Palette.canvas)
        .refreshable { await reload() }
        .onChange(of: variants.map(\.slug)) { old, slugs in
            if made, let new = slugs.first(where: { !old.contains($0) }) { draft = new; made = false }
            if draft != "main" && !slugs.contains(draft) { draft = "main" }
        }
        .onChange(of: platform) { draft = "main"; made = false }
        .asks(confirm: $confirm, name: $ask)
        .sheet(isPresented: $scheduling) {
            if let planned { ScheduleSheet(sessionID: sessionID, post: planned) { scheduling = false; Task { await reload() } } }
        }
        .onChange(of: others.map(\.platform) + sideIDs.map(\.id), initial: true) { _, have in if platform != "linkedin" && !have.contains(platform) { platform = "linkedin" } }
        .sheet(isPresented: $history) { historySheet }
        .sheet(isPresented: $editing) {
            if let other {
                TextEditSheet(title: variant?.name ?? "\(other.name) post", text: text, font: .system(size: 16), limit: other.limit) { new in
                    if let variant {
                        try await model.postDraft(sessionID, platform: other.platform, ["action": "save", "slug": variant.slug, "text": new, "base": variant.text])
                    } else {
                        try await model.save("post", sessionID, text: new, base: other.text, platform: other.platform)
                    }
                    Task { await reload() }
                }
            } else {
                TextEditSheet(title: variant?.name ?? "LinkedIn post", text: text, font: .system(size: 16), limit: 3000) { new in
                    if let variant {
                        try await model.postDraft(sessionID, ["action": "save", "slug": variant.slug, "text": new, "base": variant.text])
                    } else {
                        try await model.save("post", sessionID, text: new, base: post?.text ?? "")
                    }
                    Task { await reload() }
                }
            }
        }
    }

    /// LinkedIn, X, YouTube, Vertical: the Mac's post tab switch.
    private var platforms: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                platformChip("linkedin", "LinkedIn")
                ForEach(others) { platformChip($0.platform, $0.name) }
                ForEach(sideIDs, id: \.id) { platformChip($0.id, $0.name) }
            }
        }
    }

    private func platformChip(_ id: String, _ label: String) -> some View {
        let on = platform == id
        return Button { Brand.select(); withAnimation(.snappy) { platform = id; expanded = false } } label: {
            Text(label).font(.inter(.subheadline, on ? .semibold : .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(on ? Palette.ink : Palette.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : Palette.border))
                .foregroundStyle(on ? Palette.paper : Palette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The Mac header's Schedule (StatusControl), the length, and Edit.
    private func statusRow(_ status: String?, count: Int?, limit: Int, write: Bool) -> some View {
        HStack {
            if let planned, status != nil {
                SchedulePill(post: planned) { scheduling = true }
            } else {
                let posted = status == "posted"
                Text((status ?? "No post").capitalized).font(.inter(.caption, .semibold))
                    .foregroundStyle(posted ? Palette.live : Palette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(posted ? Palette.liveSoft : Palette.well, in: Capsule())
            }
            if let count { Text("\(count) / \(limit)").font(.inter(.caption, .medium)).monospacedDigit().foregroundStyle(Palette.faint) }
            Spacer()
            Button { editing = true } label: { Label(write ? "Write" : "Edit", systemImage: "pencil") }
                .buttonStyle(.pill(.soft, small: true))
        }
    }

    private var historyCount: Int { other?.history ?? posts.first { $0.platform == "linkedin" }?.history ?? post?.history ?? 0 }

    private var historySheet: some View {
        let p = platform
        let name = other?.name ?? "LinkedIn"
        return HistorySheet(title: "Post history", subtitle: name,
                            empty: "Takes saves a version whenever the chat changes the post, and while you edit it.",
                            load: {
                                let data = try await model.act("/api/post/history", ["id": sessionID, "platform": p], nil, method: "GET")
                                return try API.decoder.decode([Version].self, from: data)
                            },
                            restore: { v in
                                var q = ["id": sessionID]
                                if p != "linkedin" { q["platform"] = p }
                                if let e = await model.tryAct("/api/post/draft", q, ["action": "restore", "path": v.path]) { return e }
                                await reload()
                                return nil
                            }, close: { history = false })
    }

    /// X, YouTube or Vertical: the cover (or the video), the title and the text, with variants,
    /// hooks and history as on the Mac (2026-10-09).
    private func platformPost(_ p: PlatformPost) -> some View {
        let vertical = p.platform == "vertical"
        let picture = p.cover ?? p.media
        return VStack(alignment: .leading, spacing: 14) {
            statusRow(p.status, count: text.count, limit: p.limit, write: false)
            drafts
            VStack(alignment: .leading, spacing: 10) {
                if let picture {
                    let f = files.first { $0.path == picture } ?? Bubble.guess(picture)
                    Button { show(f) } label: {
                        RemoteImage(url: model.api.thumb(picture, width: 900)) { $0.resizable().scaledToFill() } placeholder: { Color.black.opacity(0.06) }
                            .aspectRatio(vertical ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: vertical ? 220 : .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                if !p.title.isEmpty {
                    Text(p.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text).font(.system(size: 15)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .id(draft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            if vertical, let places = p.places, !places.isEmpty {
                HStack(spacing: 6) {
                    Text("Goes to").font(.inter(.footnote)).foregroundStyle(Palette.muted)
                    ForEach(places, id: \.self) { pl in
                        Text(["tiktok": "TikTok", "reels": "Reels", "shorts": "Shorts"][pl] ?? pl)
                            .font(.inter(.footnote, .medium)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10).frame(height: 26).background(Palette.well, in: Capsule())
                    }
                }
            }
            if !hooks.isEmpty { hookList }
        }
    }

    /// The thumbnails as covers for the post on show, as on the Mac's Post tab (2026-10-05).
    private var covers: some View {
        let thumbs = files.filter(\.canBeCover).sorted { $0.modified > $1.modified }
        return VStack(alignment: .leading, spacing: 8) {
            Text("COVER").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Palette.muted)
            if thumbs.isEmpty {
                Text("No thumbnails yet. Ask Takes to make one.").font(.inter(.footnote)).foregroundStyle(Palette.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(thumbs) { t in
                            let on = coverNow.map { Self.same($0, t.path) } ?? false
                            Button { useCover(t) } label: {
                                RemoteImage(url: model.api.thumb(t.path, width: 300)) { $0.resizable().scaledToFill() } placeholder: { Palette.well }
                                    .frame(width: 112, height: 63)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? Palette.accent : Palette.border, lineWidth: on ? 2 : 1))
                                    .overlay(alignment: .topTrailing) {
                                        if on {
                                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                                                .frame(width: 17, height: 17).background(Palette.accent, in: Circle()).padding(4)
                                        }
                                    }
                            }
                            .buttonStyle(.press)
                            .disabled(busy || on)
                            .accessibilityLabel(on ? "Cover in use: \(t.name)" : "Use \(t.name) as the cover")
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    /// The cover file is a copy Takes made from the thumbnail, so compare names without the folder.
    private static func same(_ a: String, _ b: String) -> Bool {
        a == b || (a as NSString).lastPathComponent == (b as NSString).lastPathComponent
    }

    private func useCover(_ t: RemoteFile) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.cover(t.path, platform: platform)
                failed = nil
                Brand.select()
                // The Mac makes the cover video in a few seconds.
                try? await Task.sleep(for: .seconds(2))
                await reload()
            } catch {
                failed = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var linkedIn: some View {
                statusRow(post?.status, count: post == nil ? nil : text.count, limit: 3000, write: post == nil)
                if post != nil { drafts }
                if let post {
                    CommentedText(sessionID: sessionID, file: file, text: text, font: LinkedIn.body,
                                  what: "post", color: LinkedIn.uiInk) { shown in
                        card(post, text: shown)
                    } below: { EmptyView() }
                    .id(draft)
                    if !hooks.isEmpty { hookList }
                } else {
                    MascotEmpty(title: "No post yet", message: "Ask Takes to write the LinkedIn post, or write it here.")
                        .padding(.top, 30)
                }
    }

    /// The Mac's PostDraftBar: Main and the variants, +, history, Use as Main.
    private var drafts: some View {
        let path = ["id": sessionID].merging(platform == "linkedin" ? [:] : ["platform": platform]) { a, _ in a }
        return DraftBar(variants: variants, draft: $draft, history: historyCount, busy: busy,
                        new: { act(["action": "new", "from": draft]) }, showHistory: { history = true },
                        rename: { v in
                            ask = NameAsk(title: "Rename the variant", name: v.name) { n in
                                if let e = await model.tryAct("/api/post/draft", path, ["action": "rename", "slug": v.slug, "name": n]) { return e }
                                await reload()
                                return nil
                            }
                        },
                        delete: { v in
                            confirm = Confirm(title: "Delete “\(v.name)”?", message: "Takes keeps its text in the post history.", button: "Delete") {
                                if let e = await model.tryAct("/api/post/draft", path, ["action": "delete", "slug": v.slug]) { return e }
                                draft = "main"
                                await reload()
                                return nil
                            }
                        },
                        promote: { v in act(["action": "promote", "slug": v.slug]) })
    }

    /// Claude's opening options. Tap one and it opens the draft on show.
    private var hookList: some View {
        let current = PostHook.opening(text)
        return VStack(alignment: .leading, spacing: 8) {
            Text("HOOKS").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Palette.muted)
                .padding(.top, 6)
            ForEach(hooks) { h in
                let on = picked.map { $0 == h.id } ?? (h.text.trimmingCharacters(in: .whitespacesAndNewlines) == current)
                Button { if !on { act(["action": "hook", "hook": h.id, "draft": draft]) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Palette.accent : LinkedIn.muted).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.text).font(.system(size: 15)).foregroundStyle(LinkedIn.ink)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            if let n = h.note, !n.isEmpty {
                                Text(n).font(.footnote).foregroundStyle(LinkedIn.muted)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinkedIn.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Palette.accent : LinkedIn.line))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(on ? "Hook in use: \(h.text)" : "Use hook: \(h.text)")
                .environment(\.colorScheme, .light)
            }
        }
    }

    private func act(_ body: [String: String]) {
        busy = true
        // The tapped hook gets its check at once; the reloaded post takes over after.
        if body["action"] == "hook" { picked = body["hook"]; Brand.select() }
        Task {
            defer { busy = false; picked = nil }
            do {
                try await model.postDraft(sessionID, platform: platform, body)
                failed = nil
                if body["action"] == "promote" { draft = "main" }
                if body["action"] == "new" { made = true }
                await reload()
            } catch {
                failed = error.localizedDescription
            }
        }
    }

    private func card(_ post: Post, text: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LinkedInHeader(name: name, headline: profile?.headline ?? "", photo: profile?.photo ?? false, when: post.status == "posted" ? "Posted" : "Now")
                .padding(.horizontal, 12).padding(.top, 12)
            FeedText(text: self.text, expanded: $expanded) { text }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            if let m = post.media { media(files.first { $0.path == m } ?? Bubble.guess(m)) }
            Rectangle().fill(LinkedIn.line).frame(height: 1).padding(.horizontal, 12).padding(.top, 8)
            LinkedInActions().padding(.horizontal, 4)
            if let first = post.firstComment { firstComment(first) }
        }
        .background(LinkedIn.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LinkedIn.line))
        .environment(\.colorScheme, .light)
    }

    private func media(_ f: RemoteFile) -> some View {
        Group {
            if f.isVideo {
                InlineVideo(file: f) { show(f) }
            } else {
                Button { show(f) } label: {
                    RemoteImage(url: model.api.thumb(f.path, width: 900)) { $0.resizable().scaledToFit() } placeholder: {
                        Color.black.opacity(0.05).frame(height: 260)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func firstComment(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            LinkedInAvatar(name: name, photo: profile?.photo ?? false, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text("• Author").font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
                }
                Text(text).font(.system(size: 14)).foregroundStyle(LinkedIn.ink)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

// MARK: - Inline video

/// The post's video as the LinkedIn feed plays it: muted, looping, edge to edge, at its own shape
/// (between 16:9 and 4:5, cropped to fill). Time left at the bottom left, sound on and off at the
/// bottom right, a thin progress line. Tap it for the full screen player.
struct InlineVideo: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let expand: () -> Void
    @StateObject private var p = InlinePlayer()

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: model.api.thumb(file.path, width: 900)) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                .opacity(p.playing ? 0 : 1)
            PlayerLayer(player: p.player).opacity(p.playing ? 1 : 0)
        }
        .aspectRatio(p.shape, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { p.pause(); expand() }
        .overlay(alignment: .bottomLeading) {
            if let left = p.left {
                Text(left).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { p.toggleSound() } label: {
                Image(systemName: p.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(.black.opacity(0.6), in: Circle())
            }
            .padding(8)
            .accessibilityLabel(p.muted ? "Sound on" : "Sound off")
        }
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Rectangle().fill(LinkedIn.blue).frame(width: g.size.width * p.progress)
            }
            .frame(height: 3)
            .opacity(p.playing ? 1 : 0)
        }
        .overlay {
            if p.failed || (p.playing && p.paused) {
                Image(systemName: "play.fill").font(.system(size: 22)).foregroundStyle(.white)
                    .padding(18).background(.black.opacity(0.55), in: Circle())
            }
        }
        .onAppear { p.start(model.api.media(file.path), known: file.duration) }
        .onDisappear { p.pause() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video \(file.name)")
    }
}

/// A muted, looping player for one feed video. Muted, it mixes with your music; sound on takes over.
@MainActor
final class InlinePlayer: ObservableObject {
    let player = AVQueuePlayer()
    @Published var playing = false
    @Published var muted = true
    @Published var progress: CGFloat = 0
    @Published var left: String?
    @Published var failed = false
    @Published var paused = false
    /// Width over height, kept between 4:5 (portrait) and 16:9.
    @Published var shape: CGFloat = 16 / 9
    private var looper: AVPlayerLooper?
    private var clock: Any?
    private var watch: NSKeyValueObservation?
    private var url: URL?

    func start(_ url: URL, known: Double?) {
        if self.url == url { if looper != nil { resume() }; return }
        self.url = url
        if let known { left = Self.time(known) }
        player.isMuted = true
        AVAudioSession.sharedInstance().use(.ambient, .mixWithOthers)
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        watch = player.observe(\.timeControlStatus) { [weak self] pl, _ in
            let on = pl.timeControlStatus == .playing
            Task { @MainActor in
                self?.paused = !on && pl.timeControlStatus == .paused
                if on { withAnimation(.easeOut(duration: 0.2)) { self?.playing = true } }
            }
        }
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = CGFloat(t.seconds / d)
                self.left = Self.time(max(0, d - t.seconds))
            }
        }
        Task {
            let asset = AVURLAsset(url: url)
            do {
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (size, turn) = try await track.load(.naturalSize, .preferredTransform)
                    let r = size.applying(turn)
                    let w = abs(r.width), h = abs(r.height)
                    if w > 0, h > 0 { shape = min(16 / 9, max(4 / 5, w / h)) }
                }
            } catch { failed = true }
        }
        player.play()
    }

    func resume() { player.play() }
    func pause() { player.pause() }

    func toggleSound() {
        muted.toggle()
        player.isMuted = muted
        // Sound on: the player takes the audio, as it would in the full screen player.
        AVAudioSession.sharedInstance().use(muted ? .ambient : .playback, muted ? .mixWithOthers : [])
        if !muted { try? AVAudioSession.sharedInstance().setActive(true) }
        player.play()
    }

    deinit {
        if let clock { player.removeTimeObserver(clock) }
    }

    nonisolated static func time(_ s: Double) -> String {
        let n = Int(s.rounded())
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}

/// An AVPlayerLayer that fills its frame.
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    final class View: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> View {
        let v = View()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: View, context: Context) {}
}

// MARK: - Viewer

struct Viewer: View {
    @EnvironmentObject var model: Model
    let file: RemoteFile
    let sessionID: String
    let onDone: () -> Void
    /// Change Image… and Make Final go on in the session's chat (2026-10-09).
    var toChat: (() -> Void)? = nil
    @State private var player: AVPlayer?
    /// The star as tapped here: it turns at once, and the viewer stays open (2026-10-08).
    @State private var starred: Bool?
    /// The file's panel and what it opens (2026-10-09).
    @State private var more = false
    @State private var confirm: Confirm?
    @State private var ask: NameAsk?
    @State private var voice = false

    /// A video or picture of this session opens in the review player, with comments as on the Mac.
    private var reviewPath: String? {
        guard file.isVideo || file.isImage else { return nil }
        return file.rel(in: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Dark round buttons over the black, in place of a system bar.
            HStack(spacing: 10) {
                Button(action: onDone) { dark("xmark", "Close") }.buttonStyle(.press)
                Text(file.name).font(.inter(.footnote, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    .frame(maxWidth: .infinity)
                if let n = file.take {
                    let on = starred ?? (file.keeper == true)
                    Button {
                        starred = !on
                        Brand.tap(.medium)
                        Task { await model.keeper(sessionID, take: n) }
                    } label: {
                        dark(on ? "star.fill" : "star", on ? "Remove the star" : "Star as keeper", tint: on ? .yellow : .white)
                    }
                    .buttonStyle(.press)
                }
                Button { Brand.select(); withAnimation(Brand.quick) { more.toggle() } } label: { dark("ellipsis", "More") }
                    .buttonStyle(.press)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ZStack {
                Color.black
                if let rel = reviewPath {
                    MediaReview(file: file, rel: rel, sessionID: sessionID)
                } else if file.isVideo || file.isAudio, let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else if file.isImage {
                    RemoteImage(url: model.api.thumb(file.path, width: 1600)) { $0.resizable().scaledToFit() } placeholder: { WorkingDots(color: .white) }
                } else {
                    Text(file.name).font(.inter(.body)).foregroundStyle(.white)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if more {
                FloatingPanel(open: $more) {
                    FileMore(file: file, sessionID: sessionID, open: $more, confirm: $confirm, ask: $ask, voice: $voice, done: onDone, toChat: toChat)
                }
            }
        }
        .asks(confirm: $confirm, name: $ask)
        .environment(\.colorScheme, .dark)
        // After the dark: the Voice panel is paper, as on the Mac.
        .sheet(isPresented: $voice) { VoiceSheet(file: file, sessionID: sessionID) { voice = false } }
        .onAppear {
            guard file.isVideo || file.isAudio, reviewPath == nil else { return }
            let p = AVPlayer(url: model.api.media(file.path))
            player = p
            AVAudioSession.sharedInstance().use(.playback)
            p.play()  // the user tapped this file himself
        }
        .onDisappear { player?.pause() }
    }

    private func dark(_ icon: String, _ label: String, tint: Color = .white) -> some View {
        Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 40, height: 40).background(.white.opacity(0.14), in: Circle())
            .contentShape(Circle()).accessibilityLabel(label)
    }
}

// MARK: - Uploads

/// Takes on their way to the Mac, and anything that failed. Files for the chat show in the composer.
struct UploadsBar: View {
    @ObservedObject var uploads: Uploads
    @ObservedObject var outbox: Outbox
    let sessionID: String

    var body: some View {
        let mine = uploads.items.filter { $0.session == sessionID && ($0.asTake || $0.failed != nil) }
        // Takes kept on the phone that are not on their way right now.
        let kept = outbox.ops(.take, in: sessionID).filter { op in !mine.contains { $0.op == op.id && !$0.done } }
        // Takes kept offline: one quiet line, not a card (2026-10-04).
        if !kept.isEmpty {
            let refused = kept.contains { $0.refused != nil }
            HStack(spacing: 6) {
                Image(systemName: refused ? "exclamationmark.circle" : "arrow.up.circle")
                Text(refused ? "The Mac said no to a take. Open the list on the home screen."
                     : kept.count == 1 ? "1 take waits for the Mac" : "\(kept.count) takes wait for the Mac")
                    .lineLimit(1)
            }
            .font(.inter(.caption)).foregroundStyle(refused ? Palette.warn : Palette.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 4)
        }
        if !mine.isEmpty {
            VStack(spacing: 6) {
                ForEach(mine) { u in
                    HStack(spacing: 10) {
                        Image(systemName: u.failed != nil ? "exclamationmark.triangle" : u.done ? "checkmark.circle.fill" : "arrow.up.circle")
                            .foregroundStyle(u.failed != nil ? .red : u.done ? Palette.live : Palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(u.failed ?? (u.done ? (u.asTake ? "Take sent to the Mac" : "Sent") : u.asTake ? "Sending the take…" : "Sending \(u.name)…"))
                                .font(.inter(.footnote)).lineLimit(2)
                            if !u.done { Bar(value: u.fraction) }
                        }
                        Spacer()
                        if u.done {
                            Button { uploads.items.removeAll { $0.id == u.id } } label: { Image(systemName: "xmark") }
                                .font(.inter(.footnote)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .font(.inter(.footnote, .medium))
            .padding(14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
            .shadow(color: Palette.shadow, radius: 10, y: 4)
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }
}
