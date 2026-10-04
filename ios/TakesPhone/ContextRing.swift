import SwiftUI

/// How full Claude's context is, as on the Mac: a ring and a percentage in the chat's top bar.
/// A tap offers /compact, which has Claude summarize the conversation to free space.
struct ContextRing: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var live: LiveChat
    let sessionID: String
    @State private var asking = false

    var body: some View {
        if model.chatID == sessionID, let chat = live.chat, let c = chat.context, c.window > 0 {
            let f = min(Double(c.used) / Double(c.window), 1)
            let tint = f >= 0.7 ? Palette.warn : Palette.muted
            Button { asking = true } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(Palette.border, lineWidth: 2)
                        Circle().trim(from: 0, to: f)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    Text("\(Int((f * 100).rounded()))%").font(.inter(.caption, .semibold)).monospacedDigit()
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10).frame(height: 32)
                .background(Palette.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border))
            }
            .buttonStyle(.press)
            .disabled(chat.running)
            .accessibilityLabel("Context \(Int((f * 100).rounded())) percent full")
            .confirmationDialog("Context \(Int((f * 100).rounded()))% full: \(Self.short(c.used)) of \(Self.short(c.window)) tokens",
                                isPresented: $asking, titleVisibility: .visible) {
                Button("Compact the conversation") { Task { _ = await model.say("/compact", in: sessionID) } }
            } message: {
                Text("Takes summarizes the chat so far and keeps going with more room.")
            }
        }
    }

    static func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}
