import CoreText
import SwiftUI

// The Styles board from the Mac (2026-10-08: "the styles feature is missing from ios"): every
// style with its preview and the videos that use it, then one style's guide, colours, type and
// parts. Comments on a part go to Takes as on the Mac. A video picks its style on its Files tab.

struct StylesView: View {
    @EnvironmentObject var model: Model
    @State private var list: StyleList?
    @State private var failed: String?
    @State private var chatOpen = false
    @State private var asking = false
    @State private var opened: StyleTarget?
    /// A style whose Trash was tapped once: the second tap moves it.
    @State private var trashing: String?
    @State private var problem: String?

    static let chatID = "board:styles"
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            ScreenHeader(title: "Styles", subtitle: "Each video picks its style on its Files tab.") {
                Button { chatOpen = true } label: { RoundIcon(icon: "bubble.left.and.text.bubble.right", label: "Styles chat") }
                    .buttonStyle(.press)
            } trailing: {
                Button { asking = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        Text("New style")
                    }
                    .font(.inter(.subheadline, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Palette.accent, in: Capsule())
                }
                .buttonStyle(.press)
            }
            VStack(alignment: .leading, spacing: 22) {
                if model.stylesRunning { working }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(Palette.danger)
                        .onTapGesture { self.problem = nil }
                }
                if let list {
                    if list.styles.isEmpty {
                        MascotEmpty(title: "No styles yet", message: "Tap New style and give Takes an example: a link, or words for the look.")
                            .padding(.top, 30)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(list.styles) { card($0) }
                        }
                    }
                    if !list.projects.isEmpty { projects(list.projects) }
                } else if let failed {
                    MascotEmpty(title: "Can't load the styles", message: failed, mood: .sorry)
                } else {
                    WorkingDots().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(16)
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .withTabBar()
        .navigationDestination(isPresented: $chatOpen) {
            BoardChatView(id: Self.chatID, title: "Styles",
                          empty: "Takes makes new styles, renders their previews and fixes the parts you comment on.")
        }
        .navigationDestination(item: $opened) { StyleView(target: $0) }
        .sheet(isPresented: $asking) {
            NewStyleSheet { example in
                let ok = await model.say(Self.makeAsk(example), in: Self.chatID, from: "Styles")
                if ok { model.stylesRunning = true; chatOpen = true }
                return ok
            }
            .presentationDetents([.medium])
        }
        .onChange(of: model.stylesTick) { _, _ in Task { await load() } }
        .onChange(of: model.connected) { _, on in if on { Task { await load() } } }
        .task {
            if list == nil, let raw = Cache.loadData("styles") { list = try? API.decoder.decode(StyleList.self, from: raw) }
            await load()
        }
    }

    private func load() async {
        do {
            let raw = try await model.api.stylesData()
            let fresh = try API.decoder.decode(StyleList.self, from: raw)
            if fresh != list { list = fresh }
            Task.detached(priority: .utility) { Cache.saveData(raw, "styles") }
            failed = nil
        } catch {
            if list == nil { failed = error.localizedDescription }
        }
    }

    private var working: some View {
        Button { chatOpen = true } label: {
            HStack(spacing: 10) {
                WorkingDots()
                Text("Takes is working on your styles").font(.inter(.subheadline, .medium))
                Spacer()
                Text("Watch").font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.accent)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
            }
            .foregroundStyle(Palette.ink)
            .padding(14)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.98))
    }

    // MARK: Cards

    /// A style: its preview, its name, and the videos that use it, as the Mac's gallery card.
    private func card(_ c: StyleCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Brand.select(); opened = .style(c.name) } label: {
                ZStack(alignment: .topTrailing) {
                    Color.clear.aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .overlay {
                            if let p = c.poster ?? c.video {
                                RemoteImage(url: model.api.thumb(p, width: 600)) { $0.resizable().scaledToFill() }
                                    placeholder: { Palette.well }
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Palette.faint)
                                    Text("No preview").font(.inter(.caption)).foregroundStyle(Palette.faint)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Palette.paper)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                    if c.openComments > 0 { CountBadge(n: c.openComments).padding(8) }
                }
            }
            .buttonStyle(Pressable(scale: 0.97))
            .accessibilityLabel("\(c.name) style")
            HStack(spacing: 6) {
                Text(c.name).font(.nunito(size: 17, relativeTo: .headline)).foregroundStyle(Palette.ink).lineLimit(1)
                if c.isNew {
                    Text("New").font(.inter(.caption2, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Palette.accent, in: Capsule())
                }
            }
            Text(c.usedBy.isEmpty ? "Not used yet" : "In \(c.usedBy.count) video\(c.usedBy.count == 1 ? "" : "s")")
                .font(.inter(.caption)).foregroundStyle(Palette.faint)
            if c.video == nil && c.poster == nil {
                Button("Make a preview") { ask(Self.previewAsk(c.name)) }.buttonStyle(.pill(.soft, small: true))
            }
            if c.isNew {
                HStack(spacing: 6) {
                    Button("Keep") { change(c.name, "keep") }.buttonStyle(.pill(.soft, small: true))
                    Button(trashing == c.name ? "Tap again" : "Trash") {
                        if trashing == c.name { change(c.name, "trash") } else {
                            Brand.tap(.light)
                            trashing = c.name
                            Task { try? await Task.sleep(for: .seconds(3)); if trashing == c.name { trashing = nil } }
                        }
                    }
                    .buttonStyle(.pill(.quiet, small: true))
                }
            }
        }
    }

    private func projects(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LOOKS ONLY ONE PROJECT HAS").font(.inter(.caption, .semibold)).tracking(0.8).foregroundStyle(Palette.muted)
                .padding(.bottom, 4)
            ForEach(names, id: \.self) { p in
                Button { Brand.select(); opened = .project(p) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "folder").foregroundStyle(Palette.faint).frame(width: 20)
                        Text(p).font(.inter(.body, .medium)).foregroundStyle(Palette.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPress())
            }
        }
    }

    // MARK: Actions

    private func change(_ name: String, _ action: String) {
        trashing = nil
        Brand.select()
        Task {
            do {
                try await model.api.changeStyle(name, action: action)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await load()
        }
    }

    private func ask(_ text: String) {
        Task {
            if await model.say(text, in: Self.chatID, from: "Styles") {
                model.stylesRunning = true
                chatOpen = true
            } else {
                problem = model.error ?? "The Mac didn't answer."
                model.error = nil
            }
        }
    }

    // The same asks as the Mac's Styles board (StyleLibrary.swift).
    static func makeAsk(_ example: String) -> String {
        """
        Make a new style from this example: \(example)
        Call create_style (name it yourself, 1-3 words) and follow every step it returns: the guide, the \
        tokens, the parts (each kept with save_to_library), and preview.mp4 + preview.png from the shared sample.
        """
    }

    static func previewAsk(_ name: String) -> String {
        "Render preview.mp4 and preview.png for my style \(name): the shared sample clip (get_library gives its path) with this style's title card, a caption and the lower third on it."
    }

    static func fixAsk(_ name: String) -> String {
        "I left comments on my style \(name). Read them with get_comments for its library, fix each part as a new version, and reply to each one."
    }
}

/// Which library a style page shows: a style, or one project's own looks.
enum StyleTarget: Hashable {
    case style(String)
    case project(String)
}

/// The open-comments count on a card or tile, as the Mac's badge.
struct CountBadge: View {
    let n: Int
    var body: some View {
        Label("\(n)", systemImage: "text.bubble.fill").font(.inter(.caption2, .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Palette.accent, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("\(n) open comment\(n == 1 ? "" : "s")")
    }
}

/// "New style from an example": a link or words. Takes on the Mac makes it.
struct NewStyleSheet: View {
    let send: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var example = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New style").font(.nunito(size: 24, relativeTo: .title2)).foregroundStyle(Palette.ink)
            Text("Paste a link, or describe the look. Takes on your Mac makes the guide, the colours, the parts and a preview.")
                .font(.inter(.footnote)).foregroundStyle(Palette.muted)
            TextField("https://… or “big yellow captions, black cards”", text: $example, axis: .vertical)
                .font(.inter(.body)).lineLimit(2...5).focused($typing)
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
            if failed { Text("The Mac didn't answer. Try again.").font(.inter(.footnote)).foregroundStyle(Palette.danger) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.pill(.quiet))
                Spacer()
                Button {
                    let x = example.trimmingCharacters(in: .whitespacesAndNewlines)
                    sending = true
                    Task {
                        if await send(x) { dismiss() } else { failed = true }
                        sending = false
                    }
                } label: {
                    if sending { WorkingDots(color: .white) } else { Text("Make it") }
                }
                .buttonStyle(.pill())
                .disabled(sending || example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Palette.canvas.ignoresSafeArea())
        .onAppear { typing = true }
    }
}

// MARK: - One style

/// One style's guide, colours, type and parts, as the section under the Mac's gallery.
struct StyleView: View {
    @EnvironmentObject var model: Model
    let target: StyleTarget
    @State private var detail: StyleDetail?
    @State private var failed: String?
    @State private var showing: RemoteFile?
    @State private var reading: String?
    /// item name -> the version on show (path).
    @State private var picked: [String: String] = [:]
    @State private var asked = false

    private var key: String {
        switch target {
        case .style(let n): "style-" + n
        case .project(let p): "style-project-" + p
        }
    }
    private var title: String {
        switch target {
        case .style(let n): n
        case .project(let p): "Only \(p)"
        }
    }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title, subtitle: { if case .project = target { "Wins over the style" } else { "Guide, colours, type and parts" } }()) {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let detail {
                        if detail.openComments > 0 { fixRow(detail) }
                        if detail.readme == nil && !detail.hasTokens && detail.groups.isEmpty {
                            MascotEmpty(title: "Empty", message: "Ask Takes to build it, or to copy from another library.")
                                .padding(.top, 30)
                        }
                        if let readme = detail.readme { guide(readme, comments: detail.readmeComments) }
                        if detail.hasTokens { tokens(detail) }
                        ForEach(detail.groups) { group($0) }
                    } else if let failed {
                        MascotEmpty(title: "Can't load the style", message: failed, mood: .sorry)
                    } else {
                        WorkingDots().frame(maxWidth: .infinity).padding(.top, 80)
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $reading) { file in
            if let detail {
                StyleDoc(libraryID: detail.id, file: file, title: file == "README.md" ? "Style guide" : file,
                         text: file == "README.md" ? (detail.readme ?? "") : nil, folder: detail.folder)
            }
        }
        .fullScreenCover(item: $showing) { f in
            Viewer(file: f, sessionID: detail?.id ?? "", onDone: { showing = nil; Task { await load() } })
        }
        .onChange(of: model.stylesTick) { _, _ in Task { await load() } }
        .onChange(of: model.connected) { _, on in if on { Task { await load() } } }
        .task {
            if detail == nil, let d = Cache.load(StyleDetail.self, key) { detail = d; StyleFonts.load(d.fonts, api: model.api) }
            await load()
        }
    }

    private func load() async {
        do {
            let d: StyleDetail
            switch target {
            case .style(let n): d = try await model.api.style(name: n, id: nil)
            case .project(let p): d = try await model.api.style(name: nil, id: p + "/_library")
            }
            StyleFonts.load(d.fonts, api: model.api)
            if d != detail { detail = d }
            let k = key
            Task.detached(priority: .utility) { Cache.save(d, k) }
            failed = nil
        } catch {
            if detail == nil { failed = error.localizedDescription }
        }
    }

    private func fixRow(_ d: StyleDetail) -> some View {
        HStack(spacing: 10) {
            CountBadge(n: d.openComments)
            Text(d.openComments == 1 ? "1 open comment" : "\(d.openComments) open comments")
                .font(.inter(.subheadline, .medium)).foregroundStyle(Palette.ink)
            Spacer()
            Button(asked ? "Sent" : "Ask Takes to fix") {
                asked = true
                Task { if !(await model.say(StylesView.fixAsk(title), in: StylesView.chatID, from: "Styles")) { asked = false } else { model.stylesRunning = true } }
            }
            .buttonStyle(.pill(small: true)).disabled(asked)
        }
        .padding(12)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Guide

    private func guide(_ readme: String, comments: Int) -> some View {
        Button { Brand.select(); reading = "README.md" } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("Style guide", systemImage: "text.book.closed").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.accent)
                    Spacer()
                    if comments > 0 { CountBadge(n: comments) }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
                }
                Text(Self.preview(readme)).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .lineSpacing(2).lineLimit(4).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
    }

    /// The first lines of prose, without Markdown marks (as the Mac's card).
    static func preview(_ md: String) -> String {
        md.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("---") }
            .prefix(5)
            .map { $0.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    // MARK: Tokens

    private func tokens(_ d: StyleDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Colours and type", systemImage: "swatchpalette").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.accent)
                Spacer()
                if d.tokensComments > 0 { CountBadge(n: d.tokensComments) }
                Button { reading = "tokens.json" } label: { Text("tokens.json").font(.inter(.caption)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.faint)
            }
            if !d.swatches.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 8)], alignment: .leading, spacing: 12) {
                    ForEach(d.swatches, id: \.self) { s in
                        VStack(spacing: 5) {
                            Circle()
                                .fill(Self.color(s.value) ?? .clear)
                                .overlay(Circle().strokeBorder(Palette.faint.opacity(0.45)))
                                .overlay { if Self.color(s.value) == nil { Text("?").font(.inter(.caption2)).foregroundStyle(Palette.muted) } }
                                .frame(width: 32, height: 32)
                            Text(s.name).font(.inter(.caption2)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(s.usage.isEmpty ? "\(s.name) \(s.value)" : "\(s.name) \(s.value). \(s.usage)")
                    }
                }
            }
            if !d.type.isEmpty {
                Rectangle().fill(Palette.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(d.type, id: \.self) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.name) · \(t.family) \(Int(t.size))").font(.inter(.caption2)).foregroundStyle(Palette.faint).lineLimit(1)
                            Text("Four days and 75 updates").font(Font(StyleFonts.font(t))).foregroundStyle(Palette.ink).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }

    /// #rgb, #rrggbb, #rrggbbaa. Anything else: nil (shown as "?").
    static func color(_ s: String) -> Color? {
        var h = s.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let (r, g, b, a) = h.count == 6
            ? ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, UInt64(255))
            : ((v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    // MARK: Parts

    private func group(_ g: StyleGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(g.name.capitalized).font(.inter(.footnote, .semibold)).foregroundStyle(Palette.accent)
                Text("\(g.items.count)").font(.inter(.caption)).foregroundStyle(Palette.faint)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(g.items) { tile($0, group: g.name) }
            }
        }
    }

    private func tile(_ item: StyleItem, group: String) -> some View {
        let v = item.versions.first { $0.path == picked[item.name] } ?? item.versions.last!
        let open = item.versions.reduce(0) { $0 + $1.openComments }
        let file = RemoteFile(path: v.path, name: v.name, folder: group, kind: v.kind, size: v.size, modified: v.modified)
        return VStack(alignment: .leading, spacing: 5) {
            Button { Brand.select(); showing = file } label: {
                ZStack(alignment: .topTrailing) {
                    Color.clear.aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            if file.isVideo || file.isImage {
                                RemoteImage(url: model.api.thumb(v.path, width: 480)) { $0.resizable().scaledToFit() }
                                    placeholder: { Palette.well }
                                    .padding(file.isImage ? 8 : 0)
                            } else {
                                Image(systemName: file.isAudio ? "waveform" : "doc").font(.system(size: 22)).foregroundStyle(Palette.faint)
                            }
                        }
                        .background(Palette.well)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
                    if file.isVideo {
                        Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(.black.opacity(0.55), in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                    }
                    if open > 0 { CountBadge(n: open).padding(6) }
                }
            }
            .buttonStyle(Pressable(scale: 0.97))
            .accessibilityLabel(item.name)
            Text(item.name).font(.inter(.caption, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
            if let note = v.note {
                Text(note).font(.inter(.caption2)).foregroundStyle(Palette.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.versions.count > 1 {
                HStack(spacing: 3) {
                    ForEach(item.versions, id: \.path) { x in
                        let on = x.path == v.path
                        Button { Brand.select(); picked[item.name] = x.path } label: {
                            Text(x.version.map { "v\($0)" } ?? "–")
                                .font(.system(size: 11, weight: on ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(on ? Color.white : Palette.muted)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(on ? Palette.accent : Palette.well, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The style guide or the tokens: read, select words and comment for Takes, as the Mac's reader.
struct StyleDoc: View {
    @EnvironmentObject var model: Model
    let libraryID: String
    let file: String
    let title: String
    /// The text if known (the guide comes with the style); else it loads from the Mac.
    let text: String?
    let folder: String
    @State private var loaded: String?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: title, subtitle: file) { EmptyView() }
            ScrollView {
                if let t = text ?? loaded {
                    CommentedText(sessionID: libraryID, file: file, text: t,
                                  font: file.hasSuffix(".json") ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 16),
                                  what: file == "README.md" ? "guide" : "file") { $0 } below: { EmptyView() }
                        .padding(16)
                } else {
                    WorkingDots().padding(.top, 80)
                }
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard text == nil else { return }
            if let (data, _) = try? await API.session.data(from: model.api.media(folder + "/" + file)) {
                loaded = String(decoding: data, as: UTF8.self)
            }
        }
    }
}

/// A video's style on its Files tab: "Style Magazine ⌄ from the project", as the Mac's chip.
struct StylePicker: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let project: String
    @State var style: SessionStyle
    @State private var choosing = false
    @State private var failed: String?

    var body: some View {
        Button { Brand.select(); choosing = true } label: {
            HStack(spacing: 8) {
                Text("Style").font(.inter(.footnote, .medium)).foregroundStyle(Palette.faint)
                HStack(spacing: 4) {
                    Text(style.own ?? style.project ?? "none").font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(style.own == nil ? "from the project" : "this video only").font(.inter(.caption)).foregroundStyle(Palette.faint)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Style: \(style.own ?? style.project ?? "none")")
        .sheet(isPresented: $choosing) { chooser.presentationDetents([.medium, .large]) }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("Style for this video").font(.nunito(size: 22, relativeTo: .title3)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                row("Same as the project (\(style.project ?? "none"))", on: style.own == nil) { set(nil) }
                Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 12)
                ForEach(style.names, id: \.self) { n in row(n, on: style.own == n) { set(n) } }
                if let own = style.own, own != style.project {
                    Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 12)
                    row("Use \(own) for all of \(project)", on: false) { set(own, project: true) }
                }
                if let failed { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger).padding(12) }
            }
            .padding(.vertical, 20).padding(.horizontal, 8)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }

    private func row(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            HStack(spacing: 10) {
                Text(title).font(.inter(.body, on ? .semibold : .regular)).foregroundStyle(Palette.ink)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
    }

    private func set(_ name: String?, project: Bool = false) {
        let before = style
        // The pick shows at once; the Mac's answer takes over.
        if project { style.project = name; style.own = nil } else { style.own = name }
        choosing = false
        Task {
            do {
                style = try await model.api.setStyle(sessionID, style: name, project: project)
                failed = nil
            } catch {
                style = before
                failed = error.localizedDescription
                choosing = true
            }
        }
    }
}

/// A style's own fonts (otf, ttf) on the phone, so its type samples look as on the Mac.
enum StyleFonts {
    @MainActor private static var loaded: Set<String> = []

    @MainActor static func load(_ paths: [String], api: API) {
        for p in paths where !loaded.contains(p) {
            loaded.insert(p)
            let url = api.media(p)
            Task.detached(priority: .utility) {
                guard let (data, _) = try? await API.session.data(from: url) else { return }
                let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "style-fonts")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appending(path: (p as NSString).lastPathComponent)
                guard (try? data.write(to: file, options: .atomic)) != nil else { return }
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
    }

    static func font(_ t: StyleType) -> UIFont {
        let size = min(24, max(12, t.size))
        let weight: UIFont.Weight = t.weight >= 700 ? .bold : t.weight >= 600 ? .semibold : t.weight >= 500 ? .medium : t.weight <= 300 ? .light : .regular
        let d = UIFontDescriptor(fontAttributes: [.family: t.family])
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        let f = UIFont(descriptor: d, size: size)
        return f.familyName == t.family ? f : (UIFont(name: t.family, size: size) ?? .systemFont(ofSize: size, weight: weight))
    }
}
