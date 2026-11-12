import SwiftUI

// The Effects tab of the Styles board, from the Mac (Effects.swift, 2026-10-28): every effect
// plays its preview at once, one opens with when it fits and what Takes asks you for, Use in a
// video sends the Mac's ask to that video's chat, and New effect asks the Styles chat to build one.
// Takes adds an effect only when you ask for it.

struct Effect: Codable, Hashable, Identifiable {
    var slug: String
    var name: String
    var description: String
    var when: String
    /// "Full frame", "Cut-out" or "Overlay".
    var kind: String
    var needs: [String]
    var seconds: Double?
    /// "any" (it fits every frame) or one like "9:16".
    var shape: String
    var video: Bool
    var poster: Bool
    var readme: Bool
    var id: String { slug }

    /// "6 s · Any format · Overlay", as the Mac's details line.
    var meta: String {
        ([seconds.map { "\(Int($0.rounded())) s" }, shape == "any" ? "Any format" : shape, kind.isEmpty ? nil : kind] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A style, effect or skill for the chat's @ list (the Mac's PhoneMention).
struct MentionItem: Codable, Hashable, Identifiable {
    /// "Styles", "Effects" or "Skills".
    var kind: String
    var name: String
    var detail: String?
    var id: String
    var image: String?
    var effect: String?
    var token: String { "@" + name }
}

extension API {
    func effects() async throws -> [Effect] { try await send(request("/api/effects")) }
    /// preview.mp4, preview.png or README.md of an effect. Shipped effects live in the Mac app.
    func effectFile(_ slug: String, _ file: String) -> URL { url("/api/effects/file", ["slug": slug, "file": file, "token": token ?? ""]) }
    /// action "use" (slug, session) or "new" (example).
    func changeEffect(_ body: [String: String]) async throws {
        _ = try await send(request("/api/effects", method: "POST", json: body), as: OK.self)
    }
    func mentions(_ id: String?) async throws -> [MentionItem] { try await send(request("/api/mentions", id.map { ["id": $0] } ?? [:])) }
}

/// The Effects page under the board's switch.
struct EffectsPage: View {
    @EnvironmentObject var model: Model
    let open: (Effect) -> Void
    let new: () -> Void
    @State private var effects: [Effect]?
    @State private var failed: String?
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One move for one beat of a video. Takes adds an effect only when you ask for it.")
                .font(.inter(.footnote)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let effects {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(effects) { tile($0) }
                    newTile
                }
            } else if let failed {
                MascotEmpty(title: "Can't load the effects", message: failed, mood: .sorry)
            } else {
                WorkingDots().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .onChange(of: model.stylesTick) { _, _ in Task { await load() } }
        .onChange(of: model.connected) { _, on in if on { Task { await load() } } }
        .task {
            if effects == nil { effects = Cache.load([Effect].self, "effects") }
            await load()
        }
    }

    private func load() async {
        do {
            let fresh = try await model.api.effects()
            if fresh != effects { effects = fresh }
            Task.detached(priority: .utility) { Cache.save(fresh, "effects") }
            failed = nil
        } catch {
            if effects == nil { failed = error.localizedDescription }
        }
    }

    private func tile(_ e: Effect) -> some View {
        Button { Brand.select(); open(e) } label: {
            VStack(alignment: .leading, spacing: 7) {
                EffectPreview(effect: e)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.name).font(.nunito(size: 16, relativeTo: .headline)).foregroundStyle(Palette.ink).lineLimit(1)
                    if !e.kind.isEmpty { Text(e.kind).font(.inter(.caption2, .medium)).foregroundStyle(Palette.faint).lineLimit(1) }
                }
                Text(e.when).font(.inter(.caption)).foregroundStyle(Palette.muted)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .accessibilityLabel("\(e.name) effect")
    }

    private var newTile: some View {
        Button { Brand.select(); new() } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear.aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            Text("Paste a reel or say the move. Takes builds it as your own effect.")
                                .font(.inter(.caption)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Palette.muted).padding(14)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                Text("New effect").font(.nunito(size: 16, relativeTo: .headline)).foregroundStyle(Palette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.97))
        .accessibilityLabel("New effect")
    }
}

/// A 9:16 preview that loops, muted: the poster at once, the clip over it.
struct EffectPreview: View {
    @EnvironmentObject var model: Model
    let effect: Effect

    var body: some View {
        Color.clear.aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            // The Mac's stage: dark in both looks, as a video is.
            .background(Color(white: 0.09))
            .overlay { if !effect.poster && !effect.video { Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4)) } }
            .overlay {
                if effect.poster {
                    RemoteImage(url: model.api.effectFile(effect.slug, "preview.png"), maxPixels: 900) { $0.resizable().scaledToFill() }
                        placeholder: { Palette.well }
                }
            }
            .overlay { if effect.video { ClipLoop(url: model.api.effectFile(effect.slug, "preview.mp4")) } }
            .clipped()
    }
}

/// One effect, as the details beside the Mac's grid.
struct EffectView: View {
    @EnvironmentObject var model: Model
    let effect: Effect
    @State private var choosing = false
    @State private var sent: String?
    @State private var problem: String?
    @State private var reading = false

    /// The newest videos first, as the list's top.
    private var videos: [Session] {
        Array(model.sessions.filter { $0.archived != true }.sorted { $0.updated > $1.updated }.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: effect.name, subtitle: effect.meta) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EffectPreview(effect: effect)
                        .frame(maxWidth: 260).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(effect.description).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !effect.when.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Fits when")
                            Text(effect.when).font(.inter(.subheadline)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !effect.needs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Takes asks you for")
                            ForEach(effect.needs, id: \.self) { n in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text("•").foregroundStyle(Palette.faint)
                                    Text(n.prefix(1).uppercased() + n.dropFirst()).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.inter(.subheadline)).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button { Brand.select(); withAnimation(Brand.quick) { choosing.toggle() } } label: {
                            Text("Use in a video").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.pill(wide: true))
                        if choosing { chooser }
                        if effect.readme {
                            Button { Brand.select(); reading = true } label: { Text("Open the source").frame(maxWidth: .infinity) }
                                .buttonStyle(.pill(.quiet, wide: true))
                        }
                        if let sent {
                            Label("Sent to the chat of \(sent)", systemImage: "checkmark").font(.inter(.footnote, .medium))
                                .foregroundStyle(Palette.accent)
                        }
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.inter(.footnote)).foregroundStyle(Palette.danger)
                        }
                        Text("Sends one line to that video's chat. Takes picks the spot and tells you where.")
                            .font(.inter(.caption)).foregroundStyle(Palette.faint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
                .padding(16)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $reading) { EffectSource(effect: effect) }
        .task { if model.sessions.isEmpty { await model.refresh() } }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.inter(.caption, .semibold)).tracking(0.5).foregroundStyle(Palette.faint)
    }

    /// Which video: Takes's own panel, in place under the button.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 1) {
            if videos.isEmpty {
                Text("Open a video to use it").font(.inter(.footnote)).foregroundStyle(Palette.muted).padding(10)
            }
            ForEach(videos) { v in
                PanelRow(icon: "film", title: v.title, detail: v.project) { use(in: v) }
            }
        }
        .padding(6)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .shadow(color: Palette.shadow, radius: 10, y: 4)
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func use(in v: Session) {
        withAnimation(Brand.quick) { choosing = false }
        Task {
            do {
                try await model.api.changeEffect(["action": "use", "slug": effect.slug, "session": v.id])
                sent = v.title
                problem = nil
            } catch {
                sent = nil
                problem = error.localizedDescription
            }
        }
    }
}

/// The effect's README: how it is made and what you can change.
struct EffectSource: View {
    @EnvironmentObject var model: Model
    let effect: Effect
    @State private var text: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: effect.name, subtitle: "README.md") { EmptyView() }
            ScrollView {
                if let text {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else if failed {
                    MascotEmpty(title: "Can't load the source", message: "The Mac didn't answer. Try again.", mood: .sorry).padding(.top, 40)
                } else {
                    WorkingDots().padding(.top, 80)
                }
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let (data, _) = try? await API.session.data(from: model.api.effectFile(effect.slug, "README.md")) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                failed = true
            }
        }
    }

    enum Block { case heading(String, Int), bullet(String), code(String), text(String) }

    /// Headings, bullets, code and paragraphs: enough Markdown for a README.
    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        var code: [String]?
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else {
                out.append(.text(line))
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let s, let level):
            Text(s).font(level == 1 ? .nunito(size: 24, relativeTo: .title2) : .inter(.headline, .semibold))
                .foregroundStyle(Palette.ink).padding(.top, level == 1 ? 0 : 8)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(Palette.faint)
                Text(Self.inline(s)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.inter(.subheadline)).foregroundStyle(Palette.ink)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink).padding(10)
            }
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .text(let s):
            Text(Self.inline(s)).font(.inter(.subheadline)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// "New effect": a reel link or the move in words. The Styles chat builds it, as on the Mac.
struct NewEffectSheet: View {
    let send: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var example = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New effect").font(.nunito(size: 24, relativeTo: .title2)).foregroundStyle(Palette.ink)
            Text("Paste a link to a reel, or say the move. Takes builds it as your own effect, with a preview, in the Styles chat.")
                .font(.inter(.footnote)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            TextField("A reel link, or: my screen slides in from the side as I talk", text: $example, axis: .vertical)
                .font(.inter(.body)).lineLimit(3...6).focused($typing)
                .padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
                .accessibilityIdentifier("effect-example")
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
