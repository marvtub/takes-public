import SwiftUI

/// Where TikTok, Reels and Shorts put their own buttons and text over a vertical video, in
/// 1080×1920 pixels: the strictest of the three, as the video-edit skill's safe_area.py uses.
/// Anything that must be read stays inside `safe`; the upper right is free above the button rail.
enum SafeZone {
    static let canvas = CGSize(width: 1080, height: 1920)
    static let safe = [CGRect(x: 60, y: 240, width: 820, height: 1300),
                       CGRect(x: 880, y: 240, width: 140, height: 520)]
    static let top = CGRect(x: 0, y: 0, width: 1080, height: 240)
    static let rail = CGRect(x: 880, y: 760, width: 200, height: 780)
    static let bottom = CGRect(x: 0, y: 1540, width: 1080, height: 380)

    /// A video tall enough for the vertical apps: 9:16, give or take a crop.
    nonisolated static func fits(_ size: CGSize) -> Bool {
        size.width > 0 && size.height / size.width >= 1.6
    }

    /// `r` (in 1080×1920 pixels) where the video sits in `frame`.
    nonisolated static func place(_ r: CGRect, in frame: CGRect) -> CGRect {
        let sx = frame.width / canvas.width, sy = frame.height / canvas.height
        return CGRect(x: frame.minX + r.minX * sx, y: frame.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
    }
}

/// The safe zone over a vertical video: outside it dimmed and named, the edge dashed.
struct SafeZoneOverlay: View {
    let frame: CGRect

    var body: some View {
        let safe = SafeZone.safe.map { SafeZone.place($0, in: frame) }
        let small = frame.width < 300
        ZStack(alignment: .topLeading) {
            // Everything but the safe area, dimmed.
            Path { p in
                p.addRect(frame)
                for r in safe { p.addRect(r) }
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            outline(safe)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [6, 4]))
            zone(SafeZone.top, alignment: .bottom) { label("Top bar", "rectangle.topthird.inset.filled") }
            zone(SafeZone.rail, alignment: .center) {
                VStack(spacing: small ? 8 : 14) {
                    ForEach(["heart.fill", "ellipsis.bubble.fill", "bookmark.fill", "arrowshape.turn.up.right.fill"], id: \.self) {
                        Image(systemName: $0).font(.system(size: small ? 11 : 16, weight: .semibold))
                    }
                    if !small { Text("Buttons").font(Theme.sans(10, .semibold)) }
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            zone(SafeZone.bottom, alignment: .top) { label("Caption & name", "text.alignleft") }
            if !small {
                Text("Safe zone")
                    .font(Theme.sans(10, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .position(x: safe[0].minX + 40, y: safe[0].minY + 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityLabel("Safe zone for TikTok, Reels and Shorts")
    }

    /// The safe area's outer edge: the tall box with the upper-right step.
    private func outline(_ r: [CGRect]) -> Path {
        let a = r[0], b = r[1]
        return Path { p in
            p.move(to: CGPoint(x: a.minX, y: a.minY))
            p.addLine(to: CGPoint(x: b.maxX, y: b.minY))
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
            p.addLine(to: CGPoint(x: a.maxX, y: b.maxY))
            p.addLine(to: CGPoint(x: a.maxX, y: a.maxY))
            p.addLine(to: CGPoint(x: a.minX, y: a.maxY))
            p.closeSubpath()
        }
    }

    private func zone<V: View>(_ r: CGRect, alignment: Alignment, @ViewBuilder _ content: () -> V) -> some View {
        let f = SafeZone.place(r, in: frame)
        return content()
            .padding(8)
            .frame(width: f.width, height: f.height, alignment: alignment)
            .offset(x: f.minX, y: f.minY)
    }

    private func label(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.sans(frame.width < 300 ? 9 : 11, .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
    }
}
