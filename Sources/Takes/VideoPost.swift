import AppKit
import AVFoundation
import SwiftUI

// The video platforms of the post tab (2026-10-03). Two shapes, two texts:
//
//   posts/youtube.md    the long wide video on YouTube: front matter `title`, the text is the
//                       description (chapters go in it as "0:00 Intro" lines)
//   posts/vertical.md   one vertical video for TikTok, Instagram Reels and YouTube Shorts, with one
//                       caption. Front matter `on: tiktok, reels` picks the places (none: all three),
//                       `title` is the Shorts title (empty: YouTube takes the first line).
//
// Both have variants, hooks and history in posts/<platform>/, as the X post does.

/// YouTube's colours and type (the web watch page, light mode).
enum YouTube {
    static let red = Color(red: 1, green: 0, blue: 0)
    static let ink = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)             // #0F0F0F
    static let muted = Color(red: 96 / 255, green: 96 / 255, blue: 96 / 255)           // #606060
    static let well = Color.black.opacity(0.05)
    static let inkNS = NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
    static let blueNS = NSColor(srgbRed: 6 / 255, green: 95 / 255, blue: 212 / 255, alpha: 1)
    /// The preview follows the app's text size (⌘+ / ⌘−), like the rest of Takes.
    static var textFont: NSFont { NSFont.systemFont(ofSize: 14 * TextSize.shared.factor) }
    static var lineHeight: CGFloat { (20 * TextSize.shared.factor).rounded() }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * TextSize.shared.factor, weight: weight) }

    static func styled(_ text: String, ink: NSColor = inkNS, tag: NSColor = blueNS) -> AttributedString {
        let ns = NSMutableAttributedString(string: text, attributes: [.foregroundColor: ink])
        for r in PostFile.tags(text) { ns.addAttribute(.foregroundColor, value: tag, range: r) }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }

    static func hashtags(_ text: String) -> Int {
        PostFile.tags(text).filter { (text as NSString).substring(with: $0).hasPrefix("#") }.count
    }
}

extension EditorLook {
    static var youtube: EditorLook { EditorLook(font: YouTube.textFont, lineHeight: YouTube.lineHeight, ink: YouTube.inkNS, tag: YouTube.blueNS) }
}

/// A one-line title, saved after a short pause, so typing does not write the file on each key.
struct PostTitleField: View {
    let saved: String
    var placeholder = "Title"
    var font: Font = YouTube.font(18, .bold)
    var limit = VerticalPlace.titleLimit
    let save: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(YouTube.muted.opacity(0.7)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(YouTube.ink)
                .lineLimit(1...3)
            if text.count > limit - 20 {
                Text("\(text.count)/\(limit)").font(YouTube.font(11)).monospacedDigit()
                    .foregroundStyle(text.count > limit ? YouTube.red : YouTube.muted)
                    .help("YouTube allows \(limit) characters in a title")
            }
        }
        .onAppear { text = saved }
        .onChange(of: saved) { _, s in if s != text { text = s } }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled, text != saved { save(text) }
        }
        .onDisappear { if text != saved { save(text) } }
    }
}

// MARK: - YouTube

/// The long video as the YouTube watch page shows it: the player, the title, the channel row and
/// the description box, cut after three lines with "...more".
struct YouTubeCard: View {
    @Binding var text: String
    var draft = ""
    let title: String
    let saveTitle: (String) -> Void
    let media: URL?
    @Binding var expanded: Bool
    let highlights: [String]
    let reveal: (quote: String, token: Int)?
    let focusToken: Int
    let onSelect: (String) -> Void
    let onComment: () -> Void
    let onExpand: () -> Void
    var onCollapse: () -> Void = {}
    @AppStorage("linkedinName") private var name = "You"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            player
            PostTitleField(saved: title, placeholder: "Video title", save: saveTitle)
            channel
            description
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var player: some View {
        if let media {
            PostMedia(url: media).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.ratio.16.to.9").font(.system(size: 26))
                    Text("No wide edit yet").font(YouTube.font(13, .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private var channel: some View {
        HStack(spacing: 12) {
            VideoAvatar(name: name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(YouTube.font(16, .semibold)).foregroundStyle(YouTube.ink)
                Text("1.2K subscribers").font(YouTube.font(12)).foregroundStyle(YouTube.muted)
            }
            Text("Subscribe").font(YouTube.font(14, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 36).background(YouTube.ink, in: Capsule())
                .padding(.leading, 8)
            Spacer(minLength: 8)
            pill { HStack(spacing: 8) { Image(systemName: "hand.thumbsup"); Text("128"); Rectangle().fill(.black.opacity(0.1)).frame(width: 1, height: 20); Image(systemName: "hand.thumbsdown") } }
            pill { HStack(spacing: 6) { Image(systemName: "arrowshape.turn.up.right"); Text("Share") } }
        }
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().font(YouTube.font(14, .medium)).foregroundStyle(YouTube.ink)
            .padding(.horizontal, 14).frame(height: 36).background(YouTube.well, in: Capsule())
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("0 views  Now").font(YouTube.font(14, .semibold)).foregroundStyle(YouTube.ink)
            if expanded {
                PostEditor(text: $text, identity: draft, highlights: highlights, reveal: reveal, focusToken: focusToken,
                           onSelect: onSelect, onComment: onComment, look: .youtube,
                           placeholder: "Tell viewers about your video. Chapters: one \"0:00 Intro\" line each.")
                Button("Show less", action: onCollapse).buttonStyle(.plain)
                    .font(YouTube.font(14, .semibold)).foregroundStyle(YouTube.ink)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add a description").font(YouTube.font(14)).foregroundStyle(YouTube.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(perform: onExpand)
            } else {
                Text(YouTube.styled(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .font(YouTube.font(14)).lineSpacing(3).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("...more").font(YouTube.font(14, .semibold)).foregroundStyle(YouTube.ink)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YouTube.well, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { onExpand() } }
        .help(expanded ? "" : "Click to see the whole description and edit it")
    }
}

/// The LinkedIn photo, else initials. Every preview shows the same face.
struct VideoAvatar: View {
    let name: String
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let img = LinkedIn.photo {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(red: 0.2, green: 0.4, blue: 0.9)
                    Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Vertical

/// One vertical video for TikTok, Reels and Shorts. Left: the phone as the picked place shows it,
/// as tall as the pane allows. Right: one card with the caption, the Shorts title and where it goes.
struct VerticalCard: View {
    @Binding var text: String
    var draft = ""
    let title: String
    let saveTitle: (String) -> Void
    let places: [VerticalPlace]
    let setPlaces: ([VerticalPlace]) -> Void
    let media: URL?
    /// The phone's screen height; the pane works it out from its own height.
    var phoneHeight: CGFloat = 560
    @Binding var expanded: Bool
    let highlights: [String]
    let reveal: (quote: String, token: Int)?
    let focusToken: Int
    let onSelect: (String) -> Void
    let onComment: () -> Void
    let onExpand: () -> Void
    var onCollapse: () -> Void = {}
    @AppStorage("verticalPreview") private var previewRaw = VerticalPlace.tiktok.rawValue
    @AppStorage("linkedinName") private var name = "You"
    /// The app's own mode: the card below draws light like the feeds, the empty frame does not.
    @Environment(\.colorScheme) private var scheme

    private var preview: VerticalPlace { VerticalPlace(rawValue: previewRaw) ?? .tiktok }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 40) {
                phoneColumn
                details.frame(width: 440 * TextSize.shared.factor).frame(minHeight: VerticalPhone.outer(phoneHeight).height, alignment: .top)
            }
            VStack(spacing: 28) {
                phoneColumn
                details.frame(maxWidth: 520 * TextSize.shared.factor)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var phoneColumn: some View {
        VStack(spacing: 16) {
            if media == nil {
                VerticalEmpty(height: phoneHeight).environment(\.colorScheme, scheme)
            } else {
                VerticalPhone(place: preview, media: media, name: name, caption: text, title: title, height: phoneHeight)
                placePicker
            }
        }
    }

    @Namespace private var placeNS

    private var placePicker: some View {
        HStack(spacing: 2) {
            ForEach(VerticalPlace.allCases) { p in
                Button { withAnimation(Theme.spring) { previewRaw = p.rawValue } } label: {
                    HStack(spacing: 6) {
                        PlatformLogo(platform: p.logo, size: 14)
                        Text(p.name).font(YouTube.font(12.5, .medium))
                    }
                    .foregroundStyle(p == preview ? YouTube.ink : YouTube.muted)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background {
                        if p == preview {
                            Capsule().fill(.white).shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "place", in: placeNS)
                        }
                    }
                    .contentShape(Capsule())
                    .opacity(places.contains(p) ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .help(places.contains(p) ? "Show it as \(p.name) shows it" : "Show it as \(p.name) shows it (it does not go there now)")
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.05), in: Capsule())
    }

    // MARK: The card

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
                .padding(20)
                .frame(maxHeight: .infinity, alignment: .top)
            if places.contains(.shorts) {
                Divider()
                shortsTitle.padding(.horizontal, 20).padding(.vertical, 16)
            }
            Divider()
            goesTo.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow, radius: 14, y: 6)
        .animation(Theme.motion, value: places)
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(YouTube.font(10.5, .semibold)).tracking(0.6).foregroundStyle(YouTube.muted)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                label("Caption")
                Spacer()
                captionStats
            }
            Group {
                if expanded {
                    PostEditor(text: $text, identity: draft, highlights: highlights, reveal: reveal, focusToken: focusToken,
                               onSelect: onSelect, onComment: onComment, look: .youtube,
                               placeholder: "Start with the hook: the feeds show one or two lines.")
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Start with the hook: the feeds show one or two lines.")
                        .font(YouTube.font(14)).foregroundStyle(YouTube.muted)
                } else {
                    Text(YouTube.styled(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .font(YouTube.font(14)).lineSpacing(6)
                        .textSelection(.disabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { if !expanded { onExpand() } }
            .help(expanded ? "" : "Click to edit the caption")
            if expanded {
                HStack {
                    Spacer()
                    Button("Done", action: onCollapse).buttonStyle(AccentButtonStyle(kind: .quiet))
                }
            }
        }
        .frame(minHeight: 160, alignment: .top)
    }

    @ViewBuilder private var captionStats: some View {
        let tags = YouTube.hashtags(text)
        let over = places.contains(.reels) && tags > VerticalPlace.reelsHashtags
        if tags > 0 {
            Text("# \(tags)")
                .font(YouTube.font(11, .medium)).monospacedDigit()
                .foregroundStyle(over ? YouTube.red : YouTube.muted)
                .padding(.horizontal, 7).frame(height: 18)
                .background((over ? YouTube.red.opacity(0.1) : Color.black.opacity(0.05)), in: Capsule())
                .help(over ? "Instagram allows \(VerticalPlace.reelsHashtags) hashtags. Drop some for Reels."
                           : "\(tags) hashtag\(tags == 1 ? "" : "s"). Instagram allows \(VerticalPlace.reelsHashtags).")
        }
    }

    private var shortsTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PlatformLogo(platform: "youtube", size: 12)
                label("Shorts title")
            }
            PostTitleField(saved: title, placeholder: "Empty: YouTube uses the caption's first line",
                           font: YouTube.font(14, .semibold), save: saveTitle)
        }
    }

    private var goesTo: some View {
        HStack(spacing: 8) {
            label("Goes to")
            Spacer(minLength: 4)
            ForEach(VerticalPlace.allCases) { p in placeToggle(p) }
        }
    }

    private func placeToggle(_ p: VerticalPlace) -> some View {
        let on = places.contains(p)
        return Button {
            setPlaces(on ? places.filter { $0 != p } : places + [p])
        } label: {
            HStack(spacing: 6) {
                PlatformLogo(platform: p.logo, size: 14).saturation(on ? 1 : 0).opacity(on ? 1 : 0.45)
                Text(p.name).font(YouTube.font(12.5, .medium))
            }
            .foregroundStyle(on ? YouTube.ink : YouTube.muted)
            .padding(.leading, 7).padding(.trailing, 10).frame(height: 28)
            .background(on ? Color.black.opacity(0.05) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(.black.opacity(on ? 0 : 0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(on ? "It goes to \(p.name). Click to leave it out." : "Click to post it on \(p.name) too")
    }
}

/// No vertical edit yet: a quiet 9:16 outline the size of the phone, with one line on what to do.
/// No fill, so it sits on the page in light and dark.
struct VerticalEmpty: View {
    var height: CGFloat = 480

    var body: some View {
        let size = VerticalPhone.outer(height)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: "rectangle.portrait")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("No vertical edit yet")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Ask Takes for a 9:16 cut.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(width: size.width, height: size.height)
        .overlay(shape.strokeBorder(Theme.faint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 5])))
    }
}

/// A phone with the video filling its screen and the place's bars, buttons and caption on top.
/// The chrome is drawn at 270 × 480 and scaled, so it looks the same at any size.
struct VerticalPhone: View {
    let place: VerticalPlace
    let media: URL?
    let name: String
    let caption: String
    let title: String
    var height: CGFloat = 480
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var paused = true
    @State private var ratio: CGFloat = 9.0 / 16.0

    private static let base = CGSize(width: 270, height: 480)
    private var k: CGFloat { height / Self.base.height }
    /// The whole phone, rim included, for a screen this tall.
    static func outer(_ height: CGFloat) -> CGSize {
        let k = height / base.height
        return CGSize(width: base.width * k + 6 * k + 3, height: height + 6 * k + 3)
    }

    private var handle: String { "@" + name.lowercased().replacingOccurrences(of: " ", with: "") }
    /// Shorts shows the title; the others the caption.
    private var shown: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if place == .shorts, !t.isEmpty { return t }
        return caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let screen = RoundedRectangle(cornerRadius: 30 * k, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            if let player { PostVideo(player: player) }
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.16),
                                   .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            chrome
                .frame(width: Self.base.width, height: Self.base.height)
                .scaleEffect(k)
        }
        .frame(width: Self.base.width * k, height: height)
        .clipShape(screen)
        .padding(3 * k)
        .background(RoundedRectangle(cornerRadius: 33 * k, style: .continuous).fill(Color(white: 0.1)))
        .padding(1.5)
        .background(RoundedRectangle(cornerRadius: 33 * k + 1.5, style: .continuous).fill(Color(white: 0.86)))
        .shadow(color: Color(red: 0.06, green: 0.16, blue: 0.34).opacity(0.10), radius: 22, y: 10)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .task(id: media) { await start() }
        .onDisappear { player?.pause(); player = nil; looper = nil }
        .animation(Theme.motion, value: place)
    }

    /// Everything on the glass, at the base size.
    private var chrome: some View {
        ZStack {
            VStack(spacing: 0) {
                statusBar
                topBar.padding(.top, 6)
                Spacer()
            }
            centre
            bottom
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 11, weight: .semibold))
            Spacer()
            Capsule().fill(.black).frame(width: 66, height: 18)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    @ViewBuilder private var topBar: some View {
        switch place {
        case .tiktok:
            HStack(spacing: 14) {
                Text("Following").opacity(0.7)
                VStack(spacing: 3) {
                    Text("For You").fontWeight(.bold)
                    Capsule().fill(.white).frame(width: 18, height: 2)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).padding(.trailing, 14) }
        case .reels:
            HStack {
                Text("Reels").font(.system(size: 18, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                Spacer()
                Image(systemName: "camera").font(.system(size: 16))
            }
            .padding(.horizontal, 14)
        case .shorts:
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "magnifyingglass")
                Image(systemName: "ellipsis")
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder private var centre: some View {
        if paused && player != nil {
            Image(systemName: "play.fill").font(.system(size: 28))
                .frame(width: 60, height: 60)
                .background(.black.opacity(0.3), in: Circle())
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
        if ratio > 0.7 {
            // A wide edit in a tall frame: say it, it gets cropped.
            Label("This edit is wide. Vertical needs 9:16.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5).background(.red.opacity(0.85), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
        }
    }

    private var bottom: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if place == .tiktok {
                    Text(name).font(.system(size: 14, weight: .semibold))
                } else {
                    HStack(spacing: 8) {
                        VideoAvatar(name: name, size: 26)
                        Text(place == .shorts ? handle : String(handle.dropFirst())).font(.system(size: 13, weight: .semibold))
                        Text(place == .shorts ? "Subscribe" : "Follow").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(place == .shorts ? Color.black : .white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background { if place == .shorts { Capsule().fill(.white) } }
                            .overlay { if place == .reels { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.7)) } }
                    }
                }
                if !shown.isEmpty {
                    Text(YouTube.styled(shown, ink: .white, tag: .white))
                        .font(.system(size: 12.5, weight: place == .shorts ? .medium : .regular))
                        .lineLimit(2)
                        .lineSpacing(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "music.note").font(.system(size: 10))
                    Text(place == .shorts ? "Original sound" : "original sound · \(name)").font(.system(size: 11)).lineLimit(1)
                }
                .opacity(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rail
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .padding(.horizontal, 12).padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var rail: some View {
        VStack(spacing: 15) {
            if place == .tiktok {
                VideoAvatar(name: name, size: 36)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                    .overlay(alignment: .bottom) {
                        Image(systemName: "plus").font(.system(size: 8, weight: .heavy))
                            .frame(width: 15, height: 15).background(Color(red: 1, green: 0.17, blue: 0.33), in: Circle())
                            .offset(y: 7)
                    }
                    .padding(.bottom, 4)
            }
            railItem(place == .shorts ? "hand.thumbsup.fill" : "heart.fill", "128")
            if place == .shorts { railItem("hand.thumbsdown.fill", "Dislike") }
            railItem(place == .reels ? "bubble.right" : "ellipsis.bubble.fill", "24")
            if place == .tiktok { railItem("bookmark.fill", "9") }
            railItem(place == .reels ? "paperplane" : "arrowshape.turn.up.right.fill", place == .shorts ? "Share" : "6")
            if place != .tiktok { Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).padding(.top, 2) }
        }
    }

    private func railItem(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 20))
            Text(label).font(.system(size: 10, weight: .semibold))
        }
    }

    private func start() async {
        player?.pause()
        player = nil
        looper = nil
        paused = true
        ratio = 9.0 / 16.0
        guard let media, Asset.kind(of: media) == .video else { return }
        let p = AVQueuePlayer()
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: media))
        player = p
        if let track = try? await AVURLAsset(url: media).loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let s = size.applying(transform)
            if abs(s.height) > 0 { ratio = abs(s.width) / abs(s.height) }
        }
    }

    private func toggle() {
        guard let player else { return }
        if paused { player.play() } else { player.pause() }
        withAnimation(Theme.motion) { paused.toggle() }
    }
}
