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

    enum Tab: String, CaseIterable { case chat = "Chat", files = "Files", script = "Script", board = "Board", post = "Post" }
    enum RecordMode: String, Identifiable { case prompter, camera; var id: String { rawValue } }

    /// The Mac's meta line: project · takes.
    private var meta: String {
        let n = detail?.files.filter { $0.folder == "takes" }.count ?? session.takes
        return "\(session.project) · \(n) take\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: session.title, subtitle: meta) {
                if tab == .chat { ContextRing(sessionID: session.id) }
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
                    case .script: ScriptView(sessionID: session.id, text: detail.script, reload: { await reload() })
                    case .board: BoardView(sessionID: session.id, detail: detail, show: { showing = $0 },
                                           record: { shooting = $0 }, reload: { await reload() }, toChat: { tab = .chat })
                    case .post: PostView(sessionID: session.id, post: detail.post, profile: detail.profile,
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
        .onDisappear { if model.chatID == session.id { model.chatID = nil } }
        .onReceive(model.live.$chat.map { $0?.messages.isEmpty == false }.removeDuplicates()) { if $0 && model.chatID == session.id { talked = true } }
        .fullScreenCover(item: $recording) { mode in
            switch mode {
            case .prompter:
                PrompterRecorder(script: detail?.script ?? "") { url in
                    recording = nil
                    if let url { model.outbox.take(url, name: "phone-take.mov", session: session.id, asTake: true, shot: nil) }
                }
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
            PrompterRecorder(script: shot.say) { url in
                shooting = nil
                if let url { model.outbox.take(url, name: "phone-take.mov", session: session.id, asTake: true, shot: shot.id) }
            }
        }
        .fullScreenCover(item: $showing) { f in
            Viewer(file: f, sessionID: session.id, onDone: { showing = nil; Task { await reload() } })
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
    @FocusState private var typing: Bool

    private var chat: Chat { live.id == session.id ? (live.chat ?? detail.chat) : detail.chat }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { m in
                            Bubble(message: m, files: detail.files, show: show, waiting: m.role == .user && model.outbox.ops.contains { $0.id == m.id })
                                .equatable().id(m.id)
                        }
                        if chat.running {
                            HStack(spacing: 8) { WorkingDots(); Text(chat.workingLine) }
                                .font(.inter(.footnote, .medium)).foregroundStyle(Palette.accent).id("working")
                                .transition(.opacity)
                        }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .task {
                    proxy.scrollTo("end", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("end", anchor: .bottom)
                }
                // Streamed text: follow it without an animation per update.
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .overlay { if empty { start } }
            }
            composer
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            picks = []
            for item in items { Task { await upload(item) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                if let id = model.uploads.send(u, name: u.lastPathComponent, to: session.id, asTake: false) { waiting.insert(id) }
            }
        }
        .onAppear {
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attached.isEmpty || !waiting.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
                Menu {
                    PhotosPicker(selection: $picks, matching: .any(of: [.images, .videos])) {
                        Label("Photos and videos", systemImage: "photo.on.rectangle")
                    }
                    Button { importing = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                        .frame(width: 38, height: 38)
                        .background(Palette.well, in: Circle())
                }
                .menuStyle(.button).buttonStyle(.press)
                .accessibilityLabel("Add files")
                // One button on the right, as in QuickSay (2026-10-03: "too messy"): the mic while
                // the box is empty, the arrow once there is something to send (it also stops a
                // recording and sends), the stop square while Claude works. Recording a take is
                // the button at the top right.
                Group {
                    if voice.recording {
                        recordingRow
                    } else {
                        TextField("Message Takes", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($typing)
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
        .onDisappear { voice.cancel() }
        .onChange(of: draft) { if draft.isEmpty && attached.isEmpty { spoke = false } }
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
        voice.recording || (waiting.isEmpty && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty))
    }

    /// The arrow while recording stops, adds the words and sends in one tap.
    private func send() {
        if voice.recording {
            Task {
                await toggleVoice()
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty { send() }
            }
            return
        }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attached.isEmpty {
            text += (text.isEmpty ? "I sent you these from my phone:" : "\n\nFrom my phone:") + "\n" + attached.joined(separator: "\n")
        }
        let before = (draft, attached, spoke)
        draft = ""
        attached = []
        Task {
            if !(await model.say(text, in: session.id, from: "Chat", voice: before.2)) { draft = before.0; attached = before.1; spoke = before.2 }
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
            HStack(spacing: 6) {
                Image(systemName: message.done ? "checkmark" : "gearshape").font(.inter(.caption2))
                Text(message.text).lineLimit(1)
            }
            .font(.caption.monospaced()).foregroundStyle(Palette.faint)
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

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var buf: [String] = []
        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.text(t)) }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if t.hasPrefix("/"), !t.contains(" ") || t.contains("/Movies/"), ["mp4", "mov", "png", "jpg", "jpeg", "m4a", "wav", "md", "gif", "webp", "heic"]
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
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func guess(_ path: String) -> RemoteFile {
        let ext = (path as NSString).pathExtension.lowercased()
        let kind = ["mp4", "mov"].contains(ext) ? "video" : ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) ? "image" : "other"
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
    private static let order = ["edits", "thumbnails", "takes", "stills", "uploads", "assets"]
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.order, id: \.self) { folder in
                    let list = detail.files.filter { $0.folder == folder }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(folder.prefix(1).uppercased() + folder.dropFirst()).font(.nunito(size: 18, relativeTo: .headline)).foregroundStyle(Palette.ink)
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(list) { f in Tile(file: f, sessionID: detail.session.id, open: open[sessionRel(f)] ?? 0, show: show, reload: { await reload() }) }
                            }
                        }
                    }
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

    /// The file's path inside the session, as comments.json names it.
    private func sessionRel(_ f: RemoteFile) -> String { f.rel(in: detail.session.id) ?? f.path }

    private func loadComments() async {
        guard let c = await model.comments(detail.session.id) else { return }
        open = Dictionary(c.filter(\.open).map { ($0.file, 1) }, uniquingKeysWith: +)
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
                        Image(systemName: "doc").font(.nunito(.title)).foregroundStyle(Palette.faint)
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
                if let d = file.duration { Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond))).font(.inter(.caption2)).monospacedDigit().foregroundStyle(Palette.faint) }
            }
        }
        .buttonStyle(Pressable(scale: 0.97))
        .contextMenu {
            if let n = file.take {
                Button { Task { await model.keeper(sessionID, take: n); await reload() } } label: {
                    Label(file.keeper == true ? "Remove the star" : "Star as keeper", systemImage: "star")
                }
            }
        }
    }
}

struct ScriptView: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let text: String
    let reload: () async -> Void
    @State private var editing = false

    var body: some View {
        ScrollView {
            if text.isEmpty {
                MascotEmpty(title: "No script yet", message: "Ask Takes to write one, or write it here.")
                    .padding(.top, 40)
            } else {
                CommentedText(sessionID: sessionID, file: "script.md", text: text, font: Self.font, what: "script")
                    .padding(20)
            }
        }
        .refreshable { await reload() }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button { editing = true } label: { Label(text.isEmpty ? "Write" : "Edit", systemImage: "pencil") }
                    .buttonStyle(.pill(.soft, small: true))
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
        .sheet(isPresented: $editing) {
            TextEditSheet(title: "Script", text: text, font: Font(Self.font), limit: nil) { new in
                try await model.save("script", sessionID, text: new, base: text)
                await reload()
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
    static let feed = Color(red: 0.957, green: 0.949, blue: 0.933)
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
    let profile: Profile?
    let show: (RemoteFile) -> Void
    let files: [RemoteFile]
    let reload: () async -> Void
    @State private var expanded = false
    @State private var editing = false
    /// "main", or the slug of the variant on show.
    @State private var draft = "main"
    @State private var busy = false
    @State private var failed: String?

    private var name: String { profile?.name ?? "You" }
    private var variants: [PostVariant] { post?.variants ?? [] }
    private var hooks: [PostHook] { post?.hooks ?? [] }
    private var variant: PostVariant? { variants.first { $0.slug == draft } }
    /// The text of the draft on show.
    private var text: String { variant?.text ?? post?.text ?? "" }
    private var file: String { variant.map { "posts/variants/\($0.slug).md" } ?? "posts/linkedin.md" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    let posted = post?.status == "posted"
                    Text((post?.status ?? "No post").capitalized).font(.inter(.caption, .semibold))
                        .foregroundStyle(posted ? Palette.live : Palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(posted ? Palette.liveSoft : Palette.well, in: Capsule())
                    if post != nil { Text("\(text.count) / 3000").font(.inter(.caption, .medium)).monospacedDigit().foregroundStyle(Palette.faint) }
                    Spacer()
                    Button { editing = true } label: { Label(post == nil ? "Write" : "Edit", systemImage: "pencil") }
                        .buttonStyle(.pill(.soft, small: true))
                }
                if !variants.isEmpty { drafts }
                if let failed { Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(.orange) }
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
            .padding(16)
        }
        .background(LinkedIn.feed)
        .refreshable { await reload() }
        .onChange(of: variants.map(\.slug)) { _, slugs in if draft != "main" && !slugs.contains(draft) { draft = "main" } }
        .sheet(isPresented: $editing) {
            TextEditSheet(title: variant?.name ?? "LinkedIn post", text: text, font: .system(size: 16), limit: 3000) { new in
                if let variant {
                    try await model.postDraft(sessionID, ["action": "save", "slug": variant.slug, "text": new, "base": variant.text])
                } else {
                    try await model.save("post", sessionID, text: new, base: post?.text ?? "")
                }
                await reload()
            }
        }
    }

    /// Main and the variants as tabs, as on the Mac. A variant can become the post that goes out.
    private var drafts: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("main", "Main", claude: false)
                    ForEach(variants) { chip($0.slug, $0.name, claude: $0.author == "claude") }
                }
            }
            if let variant {
                HStack(alignment: .firstTextBaseline) {
                    if !variant.note.isEmpty {
                        Text(variant.note).font(.footnote).foregroundStyle(LinkedIn.muted).lineLimit(3)
                    }
                    Spacer()
                    Button("Use as main") { act(["action": "promote", "slug": variant.slug]) }
                        .buttonStyle(.pill(small: true)).disabled(busy)
                }
            }
        }
    }

    private func chip(_ slug: String, _ label: String, claude: Bool) -> some View {
        let on = draft == slug
        return Button { withAnimation(.snappy) { draft = slug } } label: {
            HStack(spacing: 4) {
                if claude { Image(systemName: "sparkles").font(.inter(.caption2)) }
                Text(label).lineLimit(1)
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? LinkedIn.ink : LinkedIn.card, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : LinkedIn.line))
            .foregroundStyle(on ? LinkedIn.card : LinkedIn.ink)
        }
        .buttonStyle(.plain)
    }

    /// Claude's opening options. Tap one and it opens the draft on show.
    private var hookList: some View {
        let current = PostHook.opening(text)
        return VStack(alignment: .leading, spacing: 8) {
            Text("HOOKS").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(LinkedIn.muted)
                .padding(.top, 6)
            ForEach(hooks) { h in
                let on = h.text.trimmingCharacters(in: .whitespacesAndNewlines) == current
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
            }
        }
        .environment(\.colorScheme, .light)
    }

    private func act(_ body: [String: String]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.postDraft(sessionID, body)
                failed = nil
                if body["action"] == "promote" { draft = "main" }
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
                        Color.black.opacity(0.05).frame(height: 260).overlay { ProgressView() }
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
            RemoteImage(url: model.api.thumb(file.path, width: 900)) { $0.resizable().scaledToFill() } placeholder: { ProgressView().tint(.white) }
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
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
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
        try? AVAudioSession.sharedInstance().setCategory(muted ? .ambient : .playback, options: muted ? .mixWithOthers : [])
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
    @State private var player: AVPlayer?

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
                    Button { Task { await model.keeper(sessionID, take: n); onDone() } } label: {
                        dark(file.keeper == true ? "star.fill" : "star", "Star as keeper", tint: file.keeper == true ? .yellow : .white)
                    }
                    .buttonStyle(.press)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ZStack {
                Color.black
                if let rel = reviewPath {
                    MediaReview(file: file, rel: rel, sessionID: sessionID)
                } else if file.isVideo, let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else if file.isImage {
                    RemoteImage(url: model.api.thumb(file.path, width: 1600)) { $0.resizable().scaledToFit() } placeholder: { WorkingDots(color: .white) }
                } else {
                    Text(file.name).font(.inter(.body)).foregroundStyle(.white)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard file.isVideo, reviewPath == nil else { return }
            let p = AVPlayer(url: model.api.media(file.path))
            player = p
            try? AVAudioSession.sharedInstance().setCategory(.playback)
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
                            if !u.done { ProgressView(value: u.fraction).tint(Palette.accent) }
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
