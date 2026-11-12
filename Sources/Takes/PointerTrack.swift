import AppKit
import AVFoundation
import AVKit

// 2026-10-30: a screen take recorded with the cursor log leaves the pointer out of its video
// ("pointer": false in take-NN-screen.events.json, CursorLog.swift). render_edit draws it back in
// edits; this draws it on the stage while the take plays, exactly where it was.

struct PointerTrack {
    let times: [Double]
    let points: [CGPoint]  // .mov pixels, top-left origin
    let shape: [Int]       // the look at each move: an index of looks
    let size: CGSize       // the .mov frame
    let looks: [Look]      // the arrow, then each other cursor the screen showed (I-beam, hand...)

    struct Look {
        let image: CGImage
        let box: CGRect  // in .mov pixels around the hot spot: origin = -hot spot
    }

    static func load(_ video: URL) -> PointerTrack? {
        guard let data = try? Data(contentsOf: CursorLog.file(for: video)),
              let ev = try? JSONDecoder().decode(CursorEvents.self, from: data) else { return nil }
        return make(ev)
    }

    static func make(_ ev: CursorEvents) -> PointerTrack? {
        guard !ev.pointer, let a = ev.arrow, !ev.moves.isEmpty, ev.size.count == 2, let arrow = look(a, ev.scale)
        else { return nil }
        let looks = [arrow] + (ev.shapes ?? []).dropFirst().map { look($0, ev.scale) ?? arrow }
        return PointerTrack(times: ev.moves.map { $0[0] }, points: ev.moves.map { CGPoint(x: $0[1], y: $0[2]) },
                            shape: ev.moves.map { m in m.count > 3 && Int(m[3]) < looks.count ? max(0, Int(m[3])) : 0 },
                            size: CGSize(width: ev.size[0], height: ev.size[1]), looks: looks)
    }

    private static func look(_ a: CursorEvents.Arrow, _ scale: Double) -> Look? {
        guard a.hot.count == 2, a.size.count == 2, let png = Data(base64Encoded: a.png),
              let img = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let k = scale * a.zoom
        return Look(image: img, box: CGRect(x: -a.hot[0] * k, y: -a.hot[1] * k, width: a.size[0] * k, height: a.size[1] * k))
    }

    /// The last move at or before t.
    private func index(_ t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi { let m = (lo + hi) / 2; if times[m] <= t { lo = m + 1 } else { hi = m } }
        return max(0, lo - 1)
    }

    /// Where it was at t.
    func at(_ t: Double) -> CGPoint { points[index(t)] }

    /// Its look at t.
    func look(at t: Double) -> Look { looks[shape[index(t)]] }

    /// The pointer's frame in a view (bottom-left origin) that shows the video in `video`.
    func frame(at t: Double, in video: CGRect) -> CGRect {
        let p = at(t), box = look(at: t).box, s = video.width / size.width
        let left = p.x + box.minX, top = p.y + box.minY
        return CGRect(x: video.minX + left * s, y: video.maxY - (top + box.height) * s,
                      width: box.width * s, height: box.height * s)
    }
}

/// Moves the arrow layer with the player's time, 60 times a second, on the player view's overlay.
@MainActor final class PointerDrawer {
    private var observer: Any?
    private weak var player: AVPlayer?

    func draw(_ track: PointerTrack, in view: AVPlayerView, player: AVPlayer) {
        guard let overlay = view.contentOverlayView else { return }
        overlay.wantsLayer = true
        let layer = CALayer()
        layer.contents = track.looks[0].image
        layer.contentsGravity = .resize
        overlay.layer?.addSublayer(layer)
        self.player = player
        let place: (CMTime) -> Void = { [weak view] time in
            guard let view else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = track.look(at: time.seconds).image
            layer.frame = track.frame(at: time.seconds, in: view.videoBounds)
            CATransaction.commit()
        }
        place(player.currentTime())
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { t in
            MainActor.assumeIsolated { place(t) }
        }
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
    }
}
