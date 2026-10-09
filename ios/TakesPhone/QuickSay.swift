import SwiftUI

/// A small message bar under the Files, Script, Board and Post tabs: talk or type to the session's
/// Claude without going to the chat. One line; the mic records a voice message (VoiceNote), and
/// the arrow while recording stops and sends in one tap.
struct QuickSay: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let toChat: () -> Void
    /// The screen it sits on, for Claude ("Board", "Script", …).
    var from: String? = nil
    var placeholder = "Tell Takes…"
    /// Adds the context Claude needs to the typed text, as it goes out.
    var wrap: (String) -> String = { $0 }
    /// Runs just before the message goes out (the record screen sends the take first).
    var before: () -> Void = {}
    @State private var draft = ""
    @State private var voice = VoiceNote()
    @State private var sent = false
    /// Some of the draft was dictated.
    @State private var spoke = false
    @FocusState private var typing: Bool

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if sent {
                Button(action: toChat) {
                    Label("Sent to Takes · See the reply", systemImage: "checkmark.circle.fill")
                        .font(.inter(.footnote, .semibold)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Palette.accentSoft, in: Capsule())
                }
                .buttonStyle(.press)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                Group {
                    if voice.recording {
                        HStack(spacing: 8) {
                            Button { voice.cancel() } label: {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                                    .frame(width: 24, height: 30)
                            }
                            .accessibilityLabel("Discard recording")
                            VoiceBars(levels: voice.levels).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                        }
                    } else {
                        TextField(placeholder, text: $draft, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($typing)
                            .submitLabel(.send)
                            .onSubmit(send)
                    }
                }
                .padding(.leading, 14).padding(.vertical, voice.recording ? 4 : 9)
                Button {
                    if hasText || voice.recording { send() } else { Task { await toggleVoice() } }
                } label: {
                    Image(systemName: hasText || voice.recording ? "arrow.up" : "mic")
                        .font(.system(size: 15, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(hasText || voice.recording ? .white : Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(hasText || voice.recording ? Palette.accent : Palette.accentSoft, in: Circle())
                }
                .buttonStyle(.press)
                .padding(.trailing, 5)
                .accessibilityLabel(hasText || voice.recording ? "Send to Takes" : "Record a voice message")
            }
            .frame(minHeight: 46)
            .background(Palette.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(typing ? Palette.accent.opacity(0.5) : Palette.border, lineWidth: typing ? 1.5 : 1))
            .shadow(color: Palette.shadow, radius: 14, y: 5)
            .animation(Brand.quick, value: typing)
        }
        .padding(.horizontal, 16).padding(.bottom, 8).padding(.top, 4)
        .animation(Brand.spring, value: sent)
        .animation(Brand.spring, value: voice.recording)
        .animation(Brand.quick, value: hasText)
        .onDisappear { voice.cancel() }
        .onChange(of: draft) { if draft.isEmpty { spoke = false } }
    }

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

    private func send() {
        Task {
            if voice.recording { await toggleVoice() }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let dictated = spoke
            draft = ""
            typing = false
            before()
            if await model.say(wrap(text), in: sessionID, from: from, voice: dictated) {
                sent = true
                try? await Task.sleep(for: .seconds(5))
                sent = false
            } else {
                draft = text
                spoke = dictated
            }
        }
    }
}
