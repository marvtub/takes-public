import AVFoundation
import AppKit
import SwiftUI

// The video model browser (2026-10-09) on Plugins › Replicate and Plugins › Higgsfield: cards with
// a preview that plays on hover, and a sheet with the model's prices, speed, settings and inputs.
// The takes MCP reads all of it (`--replicate catalog|details`, `--higgsfield catalog|details`).

/// One model on a shelf.
struct VideoModel: Identifiable, Equatable {
    let model, label, description: String
    let runs: Int
    let page: URL?
    let image, video: URL?
    /// The Replicate model whose example a Higgsfield card shows (Higgsfield has no previews).
    let previewFrom: String?
    var id: String { model }
    var hasPreview: Bool { image != nil || video != nil }

    init?(_ d: [String: Any]) {
        guard let m = d["model"] as? String else { return nil }
        model = m
        label = d["label"] as? String ?? Replicate.label(m)
        description = d["description"] as? String ?? ""
        runs = d["runs"] as? Int ?? 0
        page = (d["url"] as? String).flatMap(URL.init(string:))
        image = (d["image"] as? String).flatMap(URL.init(string:))
        video = (d["video"] as? String).flatMap(URL.init(string:))
        previewFrom = d["preview_from"] as? String
    }

    static func list(_ r: [String: Any], _ key: String) -> [VideoModel] {
        (r[key] as? [[String: Any]] ?? []).compactMap(VideoModel.init)
    }
}

/// What the sheet shows, from the MCP's details call.
struct VideoModelDetails {
    struct Row: Hashable { let name, value: String }
    var prices: [Row] = []
    var priceNote: String?
    var speed: String?
    var yours: String?
    var settings: [Row] = []
    var takes: [String] = []
    var problem: String?

    init(_ d: [String: Any]) {
        let rows = { (k: String, a: String, b: String) in
            (d[k] as? [[String: Any]] ?? []).compactMap { r in
                (r[a] as? String).flatMap { n in (r[b] as? String).map { Row(name: n, value: $0) } }
            }
        }
        prices = rows("prices", "when", "price")
        settings = rows("settings", "name", "value")
        priceNote = d["price_note"] as? String
        speed = d["speed"] as? String
        yours = d["yours"] as? String
        takes = d["takes"] as? [String] ?? []
        problem = d["error"] as? String
    }
}

/// What a card's button does: Add to Replicate's defaults, or make it Higgsfield's model.
struct ModelAction {
    let title: String
    /// Already done: the button shows this with a check instead.
    let done: String?
    let help: String
    let run: () -> Void
}

/// A shelf of cards under a title, arriving in order from `from`.
struct ModelShelf: View {
    let title: String
    let detail: String
    let models: [VideoModel]
    var from = 0
    let caption: (VideoModel) -> String
    let action: (VideoModel) -> ModelAction
    let open: (VideoModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            .arrive(from)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
                    ModelCard(card: m, caption: caption(m), action: action(m)) { open(m) }
                        .arrive(min(from + i + 1, 14))
                }
            }
        }
    }
}

/// Models with no preview: a wrap of small cards with the name; a click opens the sheet.
struct ModelChips: View {
    let title: String
    let detail: String
    let models: [VideoModel]
    var from = 0
    let open: (VideoModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(models) { m in Chip(model: m) { open(m) } }
            }
        }
        .arrive(from)
    }

    private struct Chip: View {
        let model: VideoModel
        let open: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: open) {
                HStack(spacing: 6) {
                    Text(model.label).font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.2), value: hover)
        }
    }
}

/// One model: its preview (the still, the video playing while the pointer is on it), name, a
/// caption, what it does, and its button. A click anywhere else opens the sheet.
struct ModelCard: View {
    let card: VideoModel
    let caption: String
    let action: ModelAction
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay { ModelPreview(card: card, playing: hover) }
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.label).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    ModelActionButton(action: action).frame(height: 20)
                }
                Text(caption).font(Theme.sans(11)).foregroundStyle(Theme.faint).lineLimit(1)
                Text(card.description).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.2), value: hover)
        .help("Prices, speed and settings")
    }
}

struct ModelActionButton: View {
    let action: ModelAction

    var body: some View {
        if let done = action.done {
            Label(done, systemImage: "checkmark").labelStyle(.titleAndIcon)
                .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accentInk)
        } else {
            Button(action: action.run) {
                Text(action.title).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(action.help)
        }
    }
}

/// The still (or the video's first frame), and the video while `playing`.
struct ModelPreview: View {
    let card: VideoModel
    let playing: Bool
    @State private var poster: NSImage?
    /// The video gave no first frame (some are too big or slow): the film icon shows instead.
    @State private var noPoster = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border.opacity(0.4))
            if let i = card.image {
                AsyncImage(url: i) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            } else if let p = poster {
                Image(nsImage: p).resizable().scaledToFill()
            } else if !card.hasPreview || noPoster {
                Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.faint)
            }
            if playing, let v = card.video {
                LoopingVideo(url: v).transition(.opacity)
            }
        }
        .task(id: card.video) {
            if card.image == nil, let v = card.video {
                poster = await ModelPoster.frame(v)
                noPoster = poster == nil
            }
        }
    }
}

/// The first frame of a preview video, for models whose only preview is a video. Kept in memory.
@MainActor enum ModelPoster {
    private static var cache: [URL: NSImage] = [:]

    static func frame(_ url: URL) async -> NSImage? {
        if let i = cache[url] { return i }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let i = NSImage(cgImage: cg, size: .zero)
        cache[url] = i
        return i
    }
}

/// A model's sheet: the preview playing, then price, speed, your clips, settings and inputs.
/// The top shows at once from the card; the facts arrive when the MCP has them.
struct ModelSheet: View {
    let card: VideoModel
    let provider: String
    let load: () async -> [String: Any]
    let action: () -> ModelAction
    @Environment(\.dismiss) private var dismiss
    @State private var details: VideoModelDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if card.hasPreview {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { ModelPreview(card: card, playing: true) }
                    .clipped()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let d = details { facts(d) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                if let p = card.page {
                    Button("Open on replicate.com") { NSWorkspace.shared.openSoon(p) }.buttonStyle(.link)
                }
                Spacer()
                ModelActionButton(action: action())
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .font(Theme.sans(12))
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: card.hasPreview ? 720 : 520)
        .background(Theme.paper)
        .task { details = VideoModelDetails(await load()) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.label).font(Theme.sans(18, .semibold)).foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Text(card.model).font(Theme.mono(11)).foregroundStyle(Theme.faint).textSelection(.enabled)
                if card.runs > 0 { Text("· " + Replicate.runs(card.runs)).font(Theme.sans(11)).foregroundStyle(Theme.faint) }
            }
            if !card.description.isEmpty {
                Text(card.description).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if let f = card.previewFrom {
                Text("Preview: the same model's example on Replicate (\(f)).").font(Theme.sans(11)).foregroundStyle(Theme.faint)
            }
        }
    }

    @ViewBuilder private func facts(_ d: VideoModelDetails) -> some View {
        if let p = d.problem {
            Text(p).font(Theme.sans(12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).arrive(0)
        }
        section("Price on \(provider)", index: 0) {
            ForEach(d.prices, id: \.self) { r in row(r.name, r.value) }
            if let n = d.priceNote { note(n) }
            if d.prices.isEmpty && d.priceNote == nil {
                note(card.page == nil ? "Ask Takes for the price of a clip." : "See the price on replicate.com.")
            }
        }
        section("Speed", index: 1) {
            note(d.speed ?? "\(provider) gives no figure. Your own clips show here once you make some.")
            if let y = d.yours { note(y) }
        }
        if !d.settings.isEmpty {
            section("Settings", index: 2) { ForEach(d.settings, id: \.self) { r in row(r.name, r.value) } }
        }
        if !d.takes.isEmpty {
            section("It takes", index: 3) {
                Text(d.takes.joined(separator: " · ")).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<C: View>(_ title: String, index: Int, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.sans(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
            c()
        }
        .arrive(index)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(value).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.sans(12.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
    }
}
