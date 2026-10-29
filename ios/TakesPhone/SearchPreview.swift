import AVFoundation
import SwiftUI

// The Mac's results-page preview as a phone screen (2026-10-28): the picked clip or still in its own
// shape, a clip playing its found moment without sound, every moment found in that file, then Open.
// The Mac side is Sources/Takes/SearchResults.swift. Public.

struct SearchPreviewScreen: View {
    @EnvironmentObject var model: Model
    let hit: Hit
    /// The hits in the same file, the picked one among them.
    let moments: [Hit]
    let open: (Hit) -> Void
    @State private var at: Double

    init(hit: Hit, moments: [Hit], open: @escaping (Hit) -> Void) {
        self.hit = hit
        self.moments = moments
        self.open = open
        _at = State(initialValue: hit.start)
    }

    private var ext: String { (hit.path as NSString).pathExtension.lowercased() }
    private var isVideo: Bool { ["mov", "mp4", "m4v"].contains(ext) }
    private var name: String { (hit.path as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: name, subtitle: place) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picture
                    if let facts = Self.facts(hit) {
                        Text(facts).font(.inter(.footnote).monospacedDigit()).foregroundStyle(Palette.faint)
                    }
                    if moments.count > 1 || moments.first?.text != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(moments.sorted { $0.start < $1.start }) { m in
                                Button { Brand.select(); withAnimation(Brand.quick) { at = m.start } } label: { moment(m) }
                                    .buttonStyle(RowPress())
                            }
                        }
                    }
                    Button { open(hit) } label: { Text("Open") }
                        .buttonStyle(.pill(wide: true))
                }
                .padding(16)
            }
        }
        .background(Palette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    /// A tall edit stands tall, a wide one fills the width: the box has the file's own shape.
    private var picture: some View {
        ZStack(alignment: .bottomLeading) {
            Palette.well
            if isVideo {
                MomentView(url: model.api.media(hit.path), start: at).id("\(hit.path)#\(at)")
            } else {
                RemoteImage(url: model.api.thumb(hit.path, width: 1600)) { $0.resizable().scaledToFit() } placeholder: { Palette.well }
            }
            if isVideo, at > 0 {
                Text(BoardView.clock(at)).font(.inter(.caption, .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(10)
            }
        }
        .aspectRatio(Self.ratio(hit), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: UIScreen.main.bounds.height * 0.55)
        .onTapGesture { open(hit) }
    }

    private func moment(_ m: Hit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(isVideo ? BoardView.clock(m.start) : "").font(.inter(.subheadline, .medium).monospacedDigit())
                .foregroundStyle(Palette.accentInk).frame(width: 44, alignment: .leading)
            Text(m.text.map { "“\($0)”" } ?? (m.kind == "image" ? "The still matches" : "On screen"))
                .font(.inter(.subheadline)).foregroundStyle(m.start == at ? Palette.ink : Palette.muted)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(m.start == at ? Palette.well : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var place: String? { hit.session.map { $0.replacingOccurrences(of: "/", with: " › ") } }

    static func ratio(_ h: Hit) -> CGFloat {
        guard let w = h.w, let ht = h.h, w > 0, ht > 0 else { return 16 / 9 }
        return CGFloat(w) / CGFloat(ht)
    }

    /// "Vertical 9:16 · 1080×1920 · 0:48", as the Mac says it.
    static func facts(_ h: Hit) -> String? {
        guard let w = h.w, let ht = h.h, w > 0, ht > 0 else { return nil }
        let r = Double(w) / Double(ht)
        let known: [(Double, String)] = [(9.0 / 16, "Vertical 9:16"), (4.0 / 5, "Portrait 4:5"), (3.0 / 4, "Portrait 3:4"), (1, "Square 1:1"),
                                         (4.0 / 3, "4:3"), (16.0 / 9, "Wide 16:9"), (21.0 / 9, "Cinema 21:9")]
        let name = known.first { abs($0.0 - r) / $0.0 < 0.03 }?.1 ?? (r < 1 ? "Vertical" : "Wide")
        return (["\(name) · \(w)×\(ht)"] + [h.seconds.map(BoardView.clock)].compactMap { $0 }).joined(separator: " · ")
    }
}

/// A clip that plays from `start` for a few seconds, then again, without sound.
private struct MomentView: UIViewRepresentable {
    let url: URL
    let start: Double
    var length: Double = 8

    final class Box: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var token: Any?
    }

    func makeUIView(context: Context) -> Box {
        let v = Box()
        v.playerLayer.videoGravity = .resizeAspect
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.actionAtItemEnd = .pause
        // Muted and mixed: a preview never stops the music on the phone.
        AVAudioSession.sharedInstance().use(.ambient, .mixWithOthers)
        let from = CMTime(seconds: start, preferredTimescale: 600)
        let end = CMTime(seconds: start + length, preferredTimescale: 600)
        v.token = p.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak p] in
            p?.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: from); p?.play()
        }
        p.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.play() }
        v.playerLayer.player = p
        return v
    }

    func updateUIView(_ v: Box, context: Context) {}

    static func dismantleUIView(_ v: Box, coordinator: ()) {
        if let t = v.token { v.playerLayer.player?.removeTimeObserver(t) }
        v.playerLayer.player?.pause()
        v.playerLayer.player = nil
    }
}
