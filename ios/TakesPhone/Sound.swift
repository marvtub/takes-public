import AVFoundation
import SwiftUI

/// A sound in the chat plays right in its card, as on the Mac (2026-10-07). A tap plays or stops it;
/// the arrow opens it in the viewer.
struct SoundCard: View {
    @EnvironmentObject var model: Model
    @ObservedObject private var audio = PhoneAudio.shared
    let file: RemoteFile

    var body: some View {
        let url = model.api.media(file.path)
        let on = audio.url == url
        Button { audio.toggle(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: on && audio.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Palette.accent : Palette.muted)
                    .frame(width: 40, height: 40)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text((file.name as NSString).deletingPathExtension)
                        .font(.inter(.footnote, .medium)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if let m = file.model { Text(m).font(.inter(.caption2)).foregroundStyle(Palette.faint).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Text(on && audio.length > 0 ? Self.clock(audio.time) : (file.name as NSString).pathExtension.uppercased())
                    .font(.inter(.caption, .medium)).monospacedDigit().foregroundStyle(Palette.faint).fixedSize()
            }
            .padding(12)
            .overlay(alignment: .bottomLeading) {
                if on, audio.length > 0 {
                    GeometryReader { g in
                        Palette.accent.frame(width: g.size.width * min(1, audio.time / audio.length), height: 2)
                    }
                    .frame(height: 2)
                }
            }
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border))
            .shadow(color: Palette.shadow.opacity(0.5), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.98))
        .accessibilityLabel(on && audio.playing ? "Stop \(file.name)" : "Play \(file.name)")
        .onDisappear { if audio.url == url { audio.stop() } }
    }

    static func clock(_ t: Double) -> String { Duration.seconds(max(0, t)).formatted(.time(pattern: .minuteSecond)) }
}

/// The one sound that plays from the chat. A new one stops the last.
@MainActor
final class PhoneAudio: ObservableObject {
    static let shared = PhoneAudio()
    @Published private(set) var url: URL?
    @Published private(set) var playing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var length: Double = 0
    private var player: AVPlayer?
    private var watch: Any?
    private var end: NSObjectProtocol?

    func toggle(_ file: URL) {
        if url == file, let player {
            if playing { player.pause(); playing = false } else { player.play(); playing = true }
            return
        }
        stop()
        AVAudioSession.sharedInstance().use(.playback)  // he tapped play himself
        let p = AVPlayer(url: file)
        player = p
        url = file
        watch = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem else { return }
                self.time = t.seconds
                let d = item.duration.seconds
                if d.isFinite { self.length = d }
            }
        }
        end = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        p.play()
        playing = true
    }

    func stop() {
        player?.pause()
        if let watch { player?.removeTimeObserver(watch) }
        if let end { NotificationCenter.default.removeObserver(end) }
        watch = nil; end = nil; player = nil
        playing = false; time = 0; length = 0; url = nil
    }
}

extension AVAudioSession {
    /// Sets the category only when it changes: each set is a call to the system's audio server
    /// that blocks the main thread, and it ran on every video that came on screen (2026-10-08).
    func use(_ category: Category, _ options: CategoryOptions = []) {
        guard self.category != category || categoryOptions != options else { return }
        try? setCategory(category, options: options)
    }
}
