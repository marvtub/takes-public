import AVFoundation
import SwiftUI

/// Effects: ready-made looks for talking-head videos (text behind the head, a glass chart, a
/// freeze-frame sticker...). Takes ships them in Resources/effects (effects/ in the repo); your own
/// go in _library/effects and win by folder name. Same files as the server's list_effects.
/// Opt-in (2026-10-28): the chat uses one only when you ask for it, so the board is where you find them.
struct EffectCard: Identifiable, Hashable {
    let slug: String
    let name: String
    let description: String
    let when: String
    let video: URL?
    let poster: URL?
    /// "Full frame", "Cut-out" or "Overlay": how the effect sits on the video.
    var kind = ""
    /// What Takes asks you for, from effect.json.
    var needs: [String] = []
    var seconds: Double?
    /// effect.json's shape: "any" (it lays itself out for the video's frame, 2026-10-29) or one like "9:16".
    var shape = "9:16"
    /// The effect's folder: its README and src/.
    var dir: URL?
    var id: String { slug }
}

enum EffectLib {
    static var shipped: URL { Bundle.main.bundleURL.appending(path: "Contents/Resources/effects") }
    static func own(root: URL) -> URL { StyleLib.user(root: root).appending(path: "effects") }

    /// Every effect, A–Z by folder name. Yours win over the shipped one of the same name.
    static func cards(shipped: URL = shipped, root: URL) -> [EffectCard] {
        let fm = FileManager.default
        var dirs: [String: URL] = [:]
        for base in [shipped, own(root: root)] {
            for d in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where d.hasDirectoryPath && !d.lastPathComponent.hasPrefix("_")
                && fm.fileExists(atPath: d.appending(path: "effect.json").path) {
                dirs[d.lastPathComponent] = d
            }
        }
        return dirs.keys.sorted().map { slug in
            let d = dirs[slug]!
            let meta = StyleLib.json(d.appending(path: "effect.json"))
            let file = { (n: String) -> URL? in fm.fileExists(atPath: d.appending(path: n).path) ? d.appending(path: n) : nil }
            return EffectCard(slug: slug, name: meta["name"] as? String ?? slug,
                              description: meta["description"] as? String ?? "", when: meta["when"] as? String ?? "",
                              video: file("preview.mp4"), poster: file("preview.png"),
                              kind: meta["kind"] as? String ?? "", needs: meta["needs"] as? [String] ?? [],
                              seconds: (meta["length_s"] as? NSNumber)?.doubleValue,
                              shape: meta["shape"] as? String ?? "9:16", dir: d)
        }
    }

    /// What the video's chat hears when you pick an effect for it.
    static func useAsk(_ c: EffectCard) -> String {
        "Use the \(c.name) effect in this video (list_effects \(c.slug)). Put it where it fits the script best, and tell me where."
    }

    /// What the Styles chat hears for a new effect of your own.
    static func makeAsk(_ example: String, root: URL) -> String {
        """
        Make a new effect from this example: \(example)
        Build it like the shipped ones (list_effects, then list_effects <the closest one> for its files): \
        effect.json ("shape": "any"), README.md, src/ (HyperFrames) that lays itself out for any frame \
        (9:16, 4:5, 1:1, 16:9) and a 9:16 preview.mp4 + preview.png, in \
        \(own(root: root).path)/<short-name>/. It shows on the Effects tab when its preview is there.
        """
    }
}

/// The Effects tab on the Styles board (2026-10-28): every effect plays at once, the one you
/// click opens on the right with when it fits, what Takes asks you for, and "Use in <video>".
struct EffectsSection: View {
    @Environment(AppModel.self) var app
    let root: URL
    var shipped = EffectLib.shipped
    @Binding var asking: Bool
    @State private var cards: [EffectCard] = []
    @State private var picked: String?
    @State private var width: CGFloat = 0
    @State private var example = ""

    init(root: URL, shipped: URL = EffectLib.shipped, asking: Binding<Bool> = .constant(false)) {
        self.root = root
        self.shipped = shipped
        _asking = asking
    }

    private var current: EffectCard? { cards.first { $0.slug == picked } ?? cards.first }

    var body: some View {
        // Side by side when there is room; the details on top in the narrow column beside a player.
        let wide = width >= 760
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
        VStack(alignment: .leading, spacing: 14) {
            Text("One move for one beat of a video. Takes adds an effect only when you ask for it.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            layout {
                if !wide, let c = current { details(c) }
                grid.frame(maxWidth: .infinity, alignment: .leading)
                if wide, let c = current { details(c).frame(width: 320) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: root) { load() }
        .onFilesChanged(in: StyleLib.user(root: root)) { load() }
        .sheet(isPresented: $asking) { newEffect }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
            ForEach(cards) { tile($0) }
            newTile
        }
    }

    private func tile(_ c: EffectCard) -> some View {
        let on = c.slug == current?.slug
        return Button { withAnimation(Theme.motion) { picked = c.slug } } label: {
            VStack(alignment: .leading, spacing: 8) {
                EffectLoop(video: c.video, poster: c.poster)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
                    .shadow(color: Theme.shadow, radius: on ? 10 : 6, y: 3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.name).font(Theme.display(15)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !c.kind.isEmpty { Text(c.kind).font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.faint).lineLimit(1) }
                }
                Text(c.when).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.description)
    }

    private var newTile: some View {
        Button { asking = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            Text("Paste a reel or say the move. Takes builds it as your own effect.")
                                .font(Theme.sans(12)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Theme.muted).padding(16)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                Text("New effect").font(Theme.display(15)).foregroundStyle(Theme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Takes makes a new effect from your example, in the Styles chat")
    }

    private func details(_ c: EffectCard) -> some View {
        let doc = app.library.current
        return VStack(alignment: .leading, spacing: 16) {
            EffectLoop(video: c.video, poster: c.poster)
                .frame(maxWidth: 260).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .id(c.slug)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(c.name).font(Theme.display(20, .heavy)).foregroundStyle(Theme.ink)
                    Text(meta(c)).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Text(c.description).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !c.when.isEmpty {
                label("Fits when")
                Text(c.when).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, -10)
            }
            if !c.needs.isEmpty {
                label("Takes asks you for")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(c.needs, id: \.self) { n in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").foregroundStyle(Theme.faint)
                            Text(n.prefix(1).uppercased() + n.dropFirst()).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(Theme.sans(12.5)).foregroundStyle(Theme.ink).padding(.top, -10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button { if let doc { use(c, in: doc) } } label: {
                    Text(doc.map { "Use in \($0.meta.title)" } ?? "Open a video to use it")
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(kind: .accent))
                .disabled(doc == nil)
                .help(doc == nil ? "Open a video first. Takes adds the effect to that video's edit."
                                 : "Takes adds this effect to the edit of \(doc!.meta.title), in that video's chat.")
                if let readme = c.dir?.appending(path: "README.md"), FileManager.default.fileExists(atPath: readme.path) {
                    Button { app.styleFile = readme } label: { Text("Open the source").frame(maxWidth: .infinity) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                        .help("How the effect is made and what you can change")
                }
                Text("Sends one line to that video's chat. Takes picks the spot and tells you where.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(Theme.sans(11, .semibold)).tracking(0.5).foregroundStyle(Theme.faint)
    }

    private func meta(_ c: EffectCard) -> String {
        ([c.seconds.map { "\(Int($0.rounded())) s" }, c.shape == "any" ? "Any format" : c.shape, c.kind.isEmpty ? nil : c.kind] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var newEffect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New effect").font(Theme.display(20)).foregroundStyle(Theme.ink)
            Text("Paste a link to a reel, or say the move. Takes builds it as your own effect, with a preview, in the Styles chat.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextField("A reel link, or: my screen slides in from the side as I talk", text: $example, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.sans(13)).lineLimit(3...6)
                .padding(10).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .onSubmit(make)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }.buttonStyle(AccentButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Button("Make it", action: make).buttonStyle(AccentButtonStyle(kind: .accent))
                    .disabled(example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 460).background(Theme.paper)
    }

    private func make() {
        let x = example.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty else { return }
        app.chats.styles.send(EffectLib.makeAsk(x, root: root), title: "Styles", onStage: nil)
        app.chats.open = true
        example = ""
        asking = false
    }

    /// Board actions write a line in the chat (2026-10-11): the video's chat gets the ask.
    private func use(_ c: EffectCard, in doc: SessionDoc) {
        app.board = nil
        app.go(doc.url)
        app.chats.chat(doc.url).send(EffectLib.useAsk(c), title: doc.meta.title, onStage: nil)
        app.chats.open = true
    }

    private func load() {
        let found = EffectLib.cards(shipped: shipped, root: root)
        if found != cards { cards = found }
    }
}

/// A 9:16 preview that plays on a loop, muted, from the moment it shows. It holds still while
/// you record, so the camera gets the Mac's full attention, and lets go of its player off screen.
struct EffectLoop: View {
    @Environment(AppModel.self) var app
    let video: URL?
    let poster: URL?
    @State private var image: NSImage?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Theme.stage)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .overlay { if let player { StylePlayerLayer(player: player) } }
            .clipped()
            .onAppear(perform: play)
            .onDisappear(perform: stop)
            .onChange(of: app.isRecording) { _, rec in rec ? player?.pause() : player?.play() }
            .task(id: poster) {
                guard let poster else { return }
                let still = await Task.detached(priority: .utility) { NSImage(contentsOf: poster) }.value
                image = still
            }
    }

    private func play() {
        guard let video, player == nil else { return }
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: video))
        player = p
        if !app.isRecording { p.play() }
    }

    private func stop() {
        player?.pause()
        looper = nil
        player = nil
    }
}
