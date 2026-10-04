import SwiftUI

/// The canvas behind the clock, fading out below it: content scrolls away under it instead of
/// running into the status bar.
struct TopFade: View {
    var body: some View {
        GeometryReader { g in
            let top = g.safeAreaInsets.top
            LinearGradient(stops: [.init(color: Palette.canvas, location: 0),
                                   .init(color: Palette.canvas, location: top / (top + 18)),
                                   .init(color: Palette.canvas.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: top + 18)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}
