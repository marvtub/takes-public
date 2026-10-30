import AVFoundation
import AppKit
import ImageIO
import SwiftUI

// The carousel's slides as they are exported (2026-10-29): one view draws every layout in every
// look, at any width. Carousels are not only text: a cover photo, a grid of frames with tags, a
// sketch next to the frame that was filmed, a photo with handwritten notes, a magazine page, one
// big word, a screen recording on a paper card on your desk. The data is CarouselSlide in Carousel.swift.

// MARK: - Looks

/// A look's type and colours. The hook (slide 1) and the ask (the last slide) may turn the page dark.
struct SlideStyle: Equatable {
    var look: CarouselLook
    var bg: Color
    var ink: Color
    var accent: Color
    /// Text on an accent tag.
    var onAccent: Color
    var hookBg: Color
    var hookInk: Color
    var askBg: Color
    var askInk: Color
    /// The kicker on slide 1: the accent unless the hook page is the accent.
    var hookKicker: Color
    /// Thin grid lines on the paper.
    var grid = false
    /// Titles in capitals.
    var upper = false
    /// The desk look's photo under the slides (CarouselFile.backdrop).
    var backdrop = ""

    init(_ look: CarouselLook, accent hex: String = "", backdrop: String = "") {
        self.look = look
        self.backdrop = backdrop
        switch look {
        case .takes:
            bg = .white; ink = CarouselSlideView.navy; accent = CarouselSlideView.blue; onAccent = .white
            hookBg = CarouselSlideView.navy; hookInk = .white; askBg = CarouselSlideView.blue; askInk = .white
            hookKicker = CarouselSlideView.mint
        case .bold:
            bg = Color(hex: 0xF1EFE9); ink = Color(hex: 0x111111); accent = Color(hex: 0xFFD21F); onAccent = Color(hex: 0x111111)
            hookBg = Color(hex: 0x111111); hookInk = .white; askBg = Color(hex: 0xFFD21F); askInk = Color(hex: 0x111111)
            hookKicker = Color(hex: 0xFFD21F)
            grid = true; upper = true
        case .magazine:
            bg = Color(hex: 0xF3EEE4); ink = Color(hex: 0x1E1B18); accent = Color(hex: 0x7A1F2B); onAccent = Color(hex: 0xF3EEE4)
            hookBg = bg; hookInk = ink; askBg = Color(hex: 0x1E1B18); askInk = Color(hex: 0xF3EEE4)
            hookKicker = accent
        case .note:
            bg = Color(hex: 0xFFFDF6); ink = Color(hex: 0x1C1C1E); accent = Color(hex: 0xE0A100); onAccent = Color(hex: 0x1C1C1E)
            hookBg = bg; hookInk = ink; askBg = bg; askInk = ink
            hookKicker = accent
        case .cinema:
            bg = Color(hex: 0x0B0B0C); ink = Color(hex: 0xF5F2EA); accent = Color(hex: 0xE8C66A); onAccent = Color(hex: 0x0B0B0C)
            hookBg = bg; hookInk = ink; askBg = bg; askInk = ink
            hookKicker = accent
        case .desk:
            bg = Color(hex: 0x1E6E4E); ink = .white; accent = Color(hex: 0xFFD21F); onAccent = Color(hex: 0x141414)
            hookBg = bg; hookInk = ink; askBg = bg; askInk = ink
            hookKicker = accent
        }
        if let c = Color(hexString: hex) {
            if askBg == accent { askBg = c }
            if hookKicker == accent { hookKicker = c }
            accent = c
        }
    }

    /// The big type.
    func display(_ size: CGFloat) -> Font {
        switch look {
        case .takes: CarouselSlideView.display(size)
        case .bold: (Self.font("Anton-Regular", size) ?? .system(size: size, weight: .black).width(.compressed)).leading(.tight)
        case .magazine, .cinema: Self.font("InstrumentSerif-Regular", size) ?? .system(size: size, weight: .regular, design: .serif)
        case .note: .system(size: size, weight: .bold)
        case .desk: .system(size: size, weight: .heavy)
        }
    }

    /// Small and body type.
    func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        look == .note ? .system(size: size, weight: weight) : CarouselSlideView.text(size, weight)
    }

    /// The words of a note on a picture: handwriting in the note and desk looks.
    func hand(_ size: CGFloat) -> Font {
        guard look == .note || look == .desk else { return text(size, .bold) }
        return NSFont(name: "Caveat-Regular", size: size) != nil ? .custom("Caveat", size: size * 1.35).weight(.bold) : .system(size: size, weight: .semibold)
    }

    /// A serif's italic for the magazine's kicker.
    func italic(_ size: CGFloat) -> Font? {
        look == .magazine || look == .cinema ? Self.font("InstrumentSerif-Italic", size) : nil
    }

    /// Tall narrow type sets tight; serifs need a little air.
    var titleLeading: CGFloat {
        switch look {
        case .bold: -0.12
        case .takes, .desk: -0.06
        default: 0
        }
    }

    static func font(_ name: String, _ size: CGFloat) -> Font? {
        NSFont(name: name, size: size) != nil ? .custom(name, size: size) : nil
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// "#FFD21F" or "FFD21F"; nil for anything else.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

// MARK: - Pictures

/// The slides' pictures: a still decoded off the main thread at most 2400 px, or a video's frame
/// at a second. The views ask and redraw when it lands; export waits for all of them first.
@MainActor
final class SlidePictures: ObservableObject {
    static let shared = SlidePictures()
    @Published private(set) var loaded = 0
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    private var lengths: [String: Double] = [:]

    /// A still has one picture whatever the second; a video has one a second.
    nonisolated static func key(_ url: URL, _ at: Double?) -> String { url.path + "@" + (isVideo(url) ? String(at ?? 0) : "") }

    nonisolated static func isVideo(_ url: URL) -> Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }

    /// The picture when it is here; else starts loading it and says nil.
    func image(_ url: URL, at: Double?) -> NSImage? {
        let k = Self.key(url, at)
        if let i = cache[k] { return i }
        if !missing.contains(k) && !loading.contains(k) {
            loading.insert(k)
            Task {
                let img = await Self.load(url, at: at)
                self.loading.remove(k)
                if let img { self.cache[k] = img } else { self.missing.insert(k) }
                self.loaded += 1
            }
        }
        return nil
    }

    /// The file is there but has no picture (or is gone): the view stops waiting.
    func failed(_ url: URL, at: Double?) -> Bool { missing.contains(Self.key(url, at)) }

    /// A video's length, once a frame of it loaded.
    func length(_ url: URL) -> Double? { lengths[url.path] }

    /// Loads every picture the slides show, for export.
    func preload(_ files: [(URL, Double?)]) async {
        for (url, at) in files where cache[Self.key(url, at)] == nil {
            if let img = await Self.load(url, at: at) { cache[Self.key(url, at)] = img }
            if Self.isVideo(url), lengths[url.path] == nil,
               let d = try? await AVURLAsset(url: url).load(.duration) { lengths[url.path] = d.seconds }
        }
    }

    /// Forget a file that changed on disk.
    func forget(_ url: URL) {
        for k in cache.keys where k.hasPrefix(url.path + "@") { cache[k] = nil }
        missing = missing.filter { !$0.hasPrefix(url.path + "@") }
    }

    nonisolated static func load(_ url: URL, at: Double?) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 2400, height: 2400)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            let t = CMTime(seconds: max(0, at ?? 0), preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 2400]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }.value
    }
}

// MARK: - The slide

/// One slide as it is exported, drawn at any width. TikTok keeps the words clear of the caption
/// below and the buttons on the right; a full-bleed picture still runs under them.
struct CarouselSlideView: View {
    let slide: CarouselSlide
    let index: Int
    let total: Int
    let place: CarouselPlace
    let name: String
    var width: CGFloat
    var style = SlideStyle(.takes)
    /// The session the slide's files are in.
    var session: URL? = nil
    /// Set on the post: the lines are typed in place.
    var edit: ((CarouselSlide) -> Void)? = nil
    /// Set while it is drawn for a file: a picture still loading shows nothing, not a hint.
    var exporting = false
    /// A video slide's words for its file: the page and the picture stay see-through, the video goes under.
    var overlayOnly = false
    @ObservedObject private var pictures = SlidePictures.shared

    static let navy = Color(red: 0x10 / 255, green: 0x2A / 255, blue: 0x56 / 255)
    static let blue = Color(red: 0x1D / 255, green: 0x5F / 255, blue: 0xD1 / 255)
    static let mint = Color(red: 0x9B / 255, green: 0xE8 / 255, blue: 0xC0 / 255)

    static func display(_ size: CGFloat) -> Font {
        NSFont(name: "Nunito-ExtraBold", size: size) != nil ? .custom("Nunito-ExtraBold", size: size) : .system(size: size, weight: .heavy, design: .rounded)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        NSFont(name: "Inter", size: size) != nil ? .custom("Inter", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    private var w: CGFloat { width }
    private var h: CGFloat { width / place.ratio }
    private var tall: Bool { place == .tiktok }
    private var hook: Bool { index == 0 }
    private var ask: Bool { total > 2 && index == total - 1 }
    private var bg: Color { hook ? style.hookBg : ask ? style.askBg : style.bg }
    private var fg: Color { hook ? style.hookInk : ask ? style.askInk : style.ink }
    private var kick: Color { hook ? style.hookKicker : ask ? (style.askBg == style.accent ? style.askInk : style.accent) : style.accent }
    /// The space the app's buttons and caption take, as parts of the width.
    private var inset: EdgeInsets {
        tall ? EdgeInsets(top: w * 0.25, leading: w * 0.08, bottom: w * 0.58, trailing: w * 0.2)
            : EdgeInsets(top: w * 0.08, leading: w * 0.08, bottom: w * 0.08, trailing: w * 0.08)
    }

    var body: some View {
        content
            .frame(width: w, height: h)
            .background {
                if !overlayOnly {
                    page
                } else if slide.layout == .screen {
                    // The video goes under the slide: a hole where the card's picture is.
                    let pic = Self.screenPicture(width: w, place: place, aspect: Self.screenAspect(slide, session: session))
                    page.mask {
                        ZStack {
                            Rectangle()
                            Rectangle().frame(width: pic.width, height: pic.height).position(x: pic.midX, y: pic.midY).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                }
            }
            .overlay { if desk && (!overlayOnly || slide.layout == .screen) { stickers } }
            .clipped()
            .environment(\.colorScheme, .light)
    }

    private var desk: Bool { style.look == .desk }

    @ViewBuilder private var content: some View {
        if desk && [.text, .word, .list].contains(slide.layout) {
            notebookSlide
        } else {
            layoutSlide
        }
    }

    @ViewBuilder private var layoutSlide: some View {
        switch slide.layout {
        case .screen: screenSlide
        case .text: textSlide
        case .word: wordSlide
        case .cover, .video: coverSlide
        case .photo: photoSlide
        case .frames: framesSlide
        case .compare: compareSlide
        case .annotate: annotateSlide
        case .magazine: magazineSlide
        case .list: listSlide
        }
    }

    /// The paper: its colour, and the grid in the bold look. The desk look's desk.
    @ViewBuilder private var page: some View {
        if desk { deskPage } else { paper }
    }

    private var paper: some View {
        ZStack {
            bg
            if style.grid && bg == style.bg {
                Canvas { ctx, size in
                    let step = size.width / 24
                    var p = Path()
                    var x: CGFloat = 0
                    while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    ctx.stroke(p, with: .color(.black.opacity(0.055)), lineWidth: max(0.5, size.width / 1080))
                }
            }
        }
    }

    // MARK: Lines

    private func title(_ text: String) -> String { style.upper ? text.uppercased() : text }

    /// The big text's size as a part of the width: smaller for a long title, so it fits the slide.
    private func titleScale(_ base: CGFloat) -> CGFloat {
        let n = slide.title.count
        let narrow: CGFloat = style.look == .bold ? 1.18 : 1
        return base * narrow * (n > 60 ? 0.62 : n > 44 ? 0.72 : n > 26 ? 0.84 : 1) * (tall ? 0.92 : 1)
    }

    /// A line of the slide: typed in place on the post, else plain text.
    @ViewBuilder
    private func line(_ text: String, hint: String, font: Font, color: Color, align: TextAlignment = .leading,
                      upper: Bool = false, set: @escaping (inout CarouselSlide, String) -> Void) -> some View {
        if let edit {
            SlideField(text: text, hint: hint, font: font, color: color, align: align) { v in
                var s = slide; set(&s, upper ? v.uppercased() : v); edit(s)
            }
        } else if !text.isEmpty {
            Text(Self.marked(upper ? text.uppercased() : text, hi: kick == color ? nil : kick)).font(font).foregroundStyle(color)
                .multilineTextAlignment(align)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Words in *stars* in the accent colour (just the words when there is no other colour).
    static func marked(_ text: String, hi: Color?) -> AttributedString {
        let parts = text.components(separatedBy: "*")
        guard parts.count >= 3 else { return AttributedString(text) }
        var out = AttributedString()
        for (i, p) in parts.enumerated() {
            // A star with no partner stays a star.
            if i == parts.count - 1 && parts.count % 2 == 0 { out += AttributedString("*" + p); continue }
            var a = AttributedString(p)
            if i % 2 == 1, let hi { a.foregroundColor = hi }
            out += a
        }
        return out
    }

    @ViewBuilder
    private func kickerLine(_ color: Color) -> some View {
        if desk {
            // A small black tag, the words in the accent.
            if !slide.kicker.isEmpty || edit != nil {
                line(slide.kicker, hint: "KICKER", font: style.text(w * 0.03, .heavy), color: style.accent, upper: true) { $0.kicker = $1 }
                    .tracking(w * 0.002).fixedSize()
                    .padding(.horizontal, w * 0.016).padding(.vertical, w * 0.006)
                    .background(Self.tape).rotationEffect(.degrees(-2))
            }
        } else {
            line(slide.kicker, hint: "KICKER", font: style.italic(w * 0.05) ?? style.text(w * 0.036, .bold), color: color,
                 upper: style.italic(1) == nil) { $0.kicker = $1 }
                .tracking(style.italic(1) == nil ? w * 0.003 : 0)
        }
    }

    /// The big text. In the desk look it sits on a strip of black paper, unless `strip` is off.
    @ViewBuilder
    private func titleLine(_ size: CGFloat, _ color: Color, align: TextAlignment = .leading, strip: Bool = true) -> some View {
        let paper = desk && strip
        let t = line(title(slide.title), hint: "Big text", font: style.display(size), color: paper ? .white : color, align: align) { $0.title = $1 }
            .lineSpacing(size * style.titleLeading)
            .tracking(desk ? -size * 0.025 : 0)
        if paper && (!slide.title.isEmpty || edit != nil) {
            t.padding(.horizontal, size * 0.36).padding(.vertical, size * 0.2)
                .background(Self.tape)
                .compositingGroup()
                .shadow(color: .black.opacity(0.35), radius: size * 0.12, y: size * 0.06)
                .rotationEffect(.degrees(-0.6))
        } else {
            t
        }
    }

    /// The small text. In the desk look it is a handwritten aside in a white bubble.
    @ViewBuilder
    private func bodyLine(_ size: CGFloat, _ color: Color, align: TextAlignment = .leading) -> some View {
        if desk {
            if !slide.body.isEmpty || edit != nil {
                line(slide.body, hint: "(a note)", font: style.hand(size * 0.85), color: Self.tape, align: .center) { $0.body = $1 }
                    .padding(.horizontal, size * 0.55).padding(.vertical, size * 0.18)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().strokeBorder(Self.tape, lineWidth: max(1, size * 0.05)))
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.3), radius: size * 0.15, y: size * 0.08)
                    .rotationEffect(.degrees(1.5))
            }
        } else {
            line(slide.body, hint: "Small text", font: style.text(size), color: color, align: align) { $0.body = $1 }
                .lineSpacing(size * 0.25)
        }
    }

    @ViewBuilder
    private func footer(_ color: Color) -> some View {
        if !desk {
            Text("\(name) · \(index + 1)/\(total)").font(style.text(w * 0.03, .regular)).foregroundStyle(color.opacity(0.7))
        }
    }

    /// A small tag: "WS", "Before", a kicker on a photo.
    private func tag(_ text: String, size: CGFloat? = nil) -> some View {
        Text(style.italic(1) == nil ? text.uppercased() : text)
            .font(style.italic(1).map { _ in style.italic((size ?? w * 0.032) * 1.3)! } ?? style.text(size ?? w * 0.032, .bold))
            .tracking(style.italic(1) == nil ? w * 0.002 : 0)
            .foregroundStyle(style.onAccent)
            .padding(.horizontal, w * 0.018).padding(.vertical, w * 0.008)
            .background(style.accent)
    }

    // MARK: Pictures

    private func url(_ media: String) -> URL? { session.flatMap { CarouselFile.resolve(media, in: $0) } }

    /// A picture filling its frame (or fitting it, on a white card), or a calm place for one.
    @ViewBuilder
    private func picture(_ media: String, at: Double?, width pw: CGFloat, height ph: CGFloat, hint: String = "Drop a picture",
                         fit: Bool = false) -> some View {
        let u = url(media)
        let img = u.flatMap { pictures.image($0, at: at) }
        ZStack {
            if overlayOnly {
                Color.clear
            } else if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                    .frame(width: pw, height: ph).clipped()
            } else {
                let dark = fit ? Color.black : bg == style.bg ? style.ink : fg
                dark.opacity(0.06)
                if !exporting && (u == nil || pictures.failed(u!, at: at)) {
                    VStack(spacing: pw * 0.03) {
                        Image(systemName: "photo").font(.system(size: max(9, min(pw, ph) * 0.12), weight: .light))
                        if min(pw, ph) > 90 {
                            Text(u == nil ? hint : "The picture is gone").font(style.text(max(8, min(pw, ph) * 0.06)))
                        }
                    }
                    .foregroundStyle(dark.opacity(0.35))
                    RoundedRectangle(cornerRadius: 2).strokeBorder(dark.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
        }
        .frame(width: pw, height: ph)
    }

    /// The video's length on the post: a slide that plays.
    @ViewBuilder private var videoBadge: some View {
        if slide.plays && !exporting {
            let len = url(slide.media).flatMap { pictures.length($0) }
            let secs = slide.end.map { $0 - (slide.start ?? 0) } ?? len.map { $0 - (slide.start ?? 0) }
            HStack(spacing: w * 0.012) {
                Image(systemName: "play.fill")
                if let secs { Text(String(format: "0:%02d", Int(secs.rounded()))) }
            }
            .font(.system(size: max(8, w * 0.032), weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, w * 0.022).padding(.vertical, w * 0.012)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    // MARK: Layouts

    private var textSlide: some View {
        VStack(alignment: .leading, spacing: 0) {
            kickerLine(kick)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: w * 0.04) {
                titleLine(w * titleScale(hook ? 0.1 : 0.115), fg)
                bodyLine(w * 0.05, fg.opacity(0.85))
            }
            Spacer(minLength: 0)
            footer(fg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(inset)
    }

    /// One word, as big as the slide takes it.
    private var wordSlide: some View {
        VStack(spacing: 0) {
            kickerLine(kick)
            Spacer(minLength: 0)
            if edit != nil {
                titleLine(w * 0.2, fg, align: .center)
            } else {
                Text(title(slide.title)).font(style.display(w * 0.42)).foregroundStyle(fg)
                    .lineLimit(slide.title.contains(" ") ? 2 : 1).minimumScaleFactor(0.1)
                    .multilineTextAlignment(.center)
                    .lineSpacing(w * 0.42 * style.titleLeading)
            }
            bodyLine(w * 0.045, fg.opacity(0.8), align: .center).padding(.top, w * 0.03)
            Spacer(minLength: 0)
            footer(fg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(inset)
    }

    /// A picture under the whole slide, the words over its dark foot. A video slide starts here too.
    private var coverSlide: some View {
        ZStack(alignment: .bottomLeading) {
            picture(slide.media, at: slide.layout == .video ? (slide.start ?? 0) : slide.at, width: w, height: h,
                    hint: slide.layout == .video ? "Drop a video" : "Drop a picture")
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.78)], startPoint: .init(x: 0.5, y: 0.35), endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: w * 0.025) {
                HStack {
                    if !slide.kicker.isEmpty || edit != nil {
                        line(slide.kicker.uppercased(), hint: "KICKER", font: style.text(w * 0.032, .bold), color: style.onAccent, upper: true) { $0.kicker = $1 }
                            .fixedSize()
                            .padding(.horizontal, w * 0.018).padding(.vertical, w * 0.008).background(style.accent)
                    }
                    Spacer()
                    videoBadge
                }
                Spacer(minLength: 0)
                titleLine(w * titleScale(0.12), style.look == .bold ? style.accent : .white)
                bodyLine(w * 0.042, .white.opacity(0.92))
                footer(.white).padding(.top, w * 0.02)
            }
            .padding(inset)
        }
        .frame(width: w, height: h)
    }

    /// The picture alone; a short caption over its foot when there is one.
    private var photoSlide: some View {
        ZStack(alignment: .bottomLeading) {
            picture(slide.media, at: slide.at, width: w, height: h)
            if !slide.title.isEmpty || !slide.body.isEmpty || edit != nil {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .init(x: 0.5, y: 0.6), endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: w * 0.015) {
                if !slide.kicker.isEmpty { tag(slide.kicker) }
                Spacer(minLength: 0)
                line(slide.title, hint: "Caption", font: style.text(w * 0.045, .bold), color: .white) { $0.title = $1 }
                line(slide.body, hint: "", font: style.text(w * 0.034), color: .white.opacity(0.9)) { $0.body = $1 }
            }
            .padding(inset)
        }
        .frame(width: w, height: h)
    }

    /// Two to four pictures, each with a tag and a line: WS, MS, CU, ECU.
    private var framesSlide: some View {
        let items = Array(slide.items.prefix(4))
        let n = max(1, items.count)
        let cols = n == 1 ? 1 : 2
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let gap = w * 0.025
        let area = w - inset.leading - inset.trailing
        let cw = (area - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let headH = slide.title.isEmpty && edit == nil ? 0 : w * 0.16
        let textH = w * 0.1
        let free = h - inset.top - inset.bottom - headH - w * 0.05
        let ph = max(w * 0.12, (free - CGFloat(rows) * textH - gap * CGFloat(rows - 1)) / CGFloat(rows))
        return VStack(alignment: .leading, spacing: 0) {
            if headH > 0 {
                VStack(alignment: .leading, spacing: w * 0.01) {
                    kickerLine(kick)
                    titleLine(w * titleScale(0.075), fg)
                }
                .frame(height: headH, alignment: .bottomLeading)
                .padding(.bottom, w * 0.02)
            }
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < items.count { cell(items[i], i, cw, ph, textH) } else { Color.clear.frame(width: cw) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            footer(fg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(inset)
    }

    private func cell(_ item: SlideItem, _ i: Int, _ cw: CGFloat, _ ph: CGFloat, _ textH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: w * 0.012) {
            picture(item.media, at: item.at, width: cw, height: ph)
                .overlay(alignment: .topLeading) { if !item.label.isEmpty { tag(item.label) } }
            itemLine(item.text, i, font: style.text(w * 0.028), color: fg.opacity(0.85)) { $0.text = $1 }
                .frame(width: cw, alignment: .leading)
                .frame(maxHeight: textH, alignment: .top)
        }
    }

    @ViewBuilder
    private func itemLine(_ text: String, _ i: Int, font: Font, color: Color, set: @escaping (inout SlideItem, String) -> Void) -> some View {
        if let edit {
            SlideField(text: text, hint: "A line", font: font, color: color) { v in
                var s = slide
                if s.items.indices.contains(i) { set(&s.items[i], v) }
                edit(s)
            }
        } else if !text.isEmpty {
            Text(text).font(font).foregroundStyle(color).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The plan and what came of it: two pictures, an arrow between.
    private var compareSlide: some View {
        let a = slide.items.first ?? SlideItem(label: "Before")
        let b = slide.items.dropFirst().first ?? SlideItem(label: "After")
        let gap = w * 0.05
        let area = w - inset.leading - inset.trailing
        let pw = (area - gap) / 2
        let ph = min(pw * 1.7, (h - inset.top - inset.bottom) * 0.66)
        return VStack(alignment: .leading, spacing: 0) {
            kickerLine(kick)
            titleLine(w * titleScale(0.08), fg).padding(.top, w * 0.01)
            Spacer(minLength: w * 0.03).frame(maxHeight: w * 0.06)
            HStack(alignment: .top, spacing: gap) {
                side(a, 0, pw, ph, a.label.isEmpty ? "Before" : a.label)
                side(b, 1, pw, ph, b.label.isEmpty ? "After" : b.label)
            }
            .overlay {
                Image(systemName: "arrow.right")
                    .font(.system(size: w * 0.035, weight: .heavy)).foregroundStyle(style.onAccent)
                    .frame(width: w * 0.075, height: w * 0.075)
                    .background(Circle().fill(style.accent))
                    .offset(y: -(w * 0.05))
            }
            Spacer(minLength: w * 0.03)
            bodyLine(w * 0.036, fg.opacity(0.85))
            footer(fg).padding(.top, w * 0.02)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(inset)
    }

    private func side(_ item: SlideItem, _ i: Int, _ pw: CGFloat, _ ph: CGFloat, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: w * 0.015) {
            picture(item.media, at: item.at, width: pw, height: ph)
                .overlay(alignment: .topLeading) { tag(label) }
            itemLine(item.text, i, font: style.text(w * 0.03), color: fg.opacity(0.85)) { $0.text = $1 }
                .frame(width: pw, alignment: .leading)
        }
    }

    /// A picture with dots and words on it: what to look at, where the light is.
    private var annotateSlide: some View {
        let area = w - inset.leading - inset.trailing
        let ph = (h - inset.top - inset.bottom) * (slide.title.isEmpty && edit == nil ? 0.86 : 0.7)
        return VStack(alignment: .leading, spacing: w * 0.025) {
            if !slide.title.isEmpty || edit != nil {
                kickerLine(kick)
                titleLine(w * titleScale(0.075), fg)
            }
            picture(slide.media, at: slide.at, width: area, height: ph)
                .overlay { marks(area, ph) }
            bodyLine(w * 0.034, fg.opacity(0.85))
            Spacer(minLength: 0)
            footer(fg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(inset)
    }

    private func marks(_ pw: CGFloat, _ ph: CGFloat) -> some View {
        let hand = style.look == .note
        let ink = hand ? Color(hex: 0xD93A2B) : style.accent
        return ZStack(alignment: .topLeading) {
            ForEach(Array(slide.marks.enumerated()), id: \.offset) { _, m in
                let p = CGPoint(x: m.x * pw, y: m.y * ph)
                let right = m.x < 0.6
                let lineLen = w * 0.07
                Path { path in
                    path.move(to: p)
                    path.addLine(to: CGPoint(x: p.x + (right ? lineLen : -lineLen), y: p.y - lineLen * 0.5))
                }
                .stroke(ink, style: StrokeStyle(lineWidth: max(1, w * 0.004), lineCap: .round))
                Circle().fill(ink).frame(width: w * 0.028, height: w * 0.028)
                    .overlay(Circle().strokeBorder(.white, lineWidth: max(1, w * 0.004)))
                    .position(p)
                Text(m.text)
                    .font(style.hand(w * 0.034))
                    .foregroundStyle(hand ? ink : style.onAccent)
                    .padding(.horizontal, w * 0.016).padding(.vertical, hand ? w * 0.002 : w * 0.008)
                    .background(hand ? Color.white.opacity(0.92) : style.accent)
                    .rotationEffect(.degrees(hand ? -3 : 0))
                    .fixedSize()
                    .alignmentGuide(.leading) { d in right ? -(p.x + lineLen + w * 0.01) : -(p.x - lineLen - w * 0.01) + d.width }
                    .alignmentGuide(.top) { d in -(p.y - lineLen * 0.5) + d.height / 2 }
            }
        }
        .frame(width: pw, height: ph, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// A picture across the top, a headline and a paragraph under it.
    private var magazineSlide: some View {
        let ph = h * (tall ? 0.42 : 0.52)
        return VStack(alignment: .leading, spacing: 0) {
            picture(slide.media, at: slide.at, width: w, height: ph)
            VStack(alignment: .leading, spacing: w * 0.02) {
                kickerLine(kick)
                titleLine(w * titleScale(0.085), fg)
                Rectangle().fill(fg.opacity(0.25)).frame(width: w * 0.12, height: max(1, w * 0.002)).padding(.vertical, w * 0.01)
                bodyLine(w * 0.032, fg.opacity(0.85))
                Spacer(minLength: 0)
                footer(fg)
            }
            .padding(.top, w * 0.05)
            .padding(.leading, inset.leading).padding(.trailing, inset.trailing)
            .padding(.bottom, tall ? inset.bottom - ph * 0.3 : inset.bottom)
        }
        .frame(width: w, height: h, alignment: .top)
    }

    /// Steps or points: one a line in the small text, numbered.
    private var listSlide: some View {
        let rows = slide.body.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { r in r.replacingOccurrences(of: #"^([-•*]|\d+[.)]|\[ ?\]|\[x\])\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        let boxed = style.look == .bold
        let size = w * (rows.count > 6 ? 0.034 : 0.042)
        return VStack(alignment: .leading, spacing: w * 0.03) {
            kickerLine(kick)
            titleLine(w * titleScale(0.085), fg)
            Spacer(minLength: 0).frame(maxHeight: w * 0.08)
            if edit != nil {
                bodyLine(size, fg).padding(w * 0.03).background(fg.opacity(0.05))
            } else {
                VStack(alignment: .leading, spacing: size * 0.8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(alignment: .firstTextBaseline, spacing: size * 0.6) {
                            if style.look == .note {
                                Image(systemName: "circle").font(.system(size: size * 0.9)).foregroundStyle(style.accent)
                            } else {
                                Text("\(i + 1)").font(style.text(size * 0.8, .bold)).monospacedDigit()
                                    .foregroundStyle(style.onAccent)
                                    .frame(width: size * 1.4, height: size * 1.4)
                                    .background(style.accent, in: style.look == .takes ? AnyShape(Circle()) : AnyShape(Rectangle()))
                            }
                            Text(r).font(style.text(size)).foregroundStyle(boxed ? .white : fg)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(boxed ? w * 0.05 : 0)
                .background(boxed ? style.ink : .clear)
            }
            Spacer(minLength: 0)
            footer(fg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(inset)
    }
}

// MARK: - The desk look

/// The desk carousel (2026-10-29, after Gannon Meyer's "viral carousels with claude"): one photo of a
/// desk from above under every slide, the words on strips of black paper with the key words in yellow,
/// a handwritten aside in a white bubble, paper stickers, a white line drawn across, and the
/// screen recording on a white card. The hook, the steps and the ask sit on a notebook.
extension CarouselSlideView {
    static let tape = Color(hex: 0x141414)
    static let stickerIcons = ["envelope", "folder", "lightbulb", "stopwatch", "bolt", "heart", "paperclip", "pencil",
                               "sparkles", "doc.text", "camera", "checkmark"]

    /// The screen card's place: under the words, as big as the slide lets it be, in the shape of its
    /// picture (`aspect`, width over height) so a wide screen take has no white bands. The export puts
    /// the video in `screenPicture`, so both come from here.
    static func screenCard(width w: CGFloat, place: CarouselPlace, aspect: CGFloat? = nil) -> CGRect {
        let h = w / place.ratio
        let tall = place == .tiktok
        let top = (tall ? w * 0.25 : w * 0.08) + w * 0.36
        let bottom = h - (tall ? w * 0.58 : w * 0.1)
        let right = tall ? w * 0.2 : w * 0.08
        let full = CGRect(x: w * 0.08, y: top, width: w - w * 0.08 - right, height: bottom - top)
        guard let a = aspect, a > 0 else { return full }
        let pad = w * 0.02
        let ih = min(full.height - pad * 2, (full.width - pad * 2) / a)
        let iw = min(full.width - pad * 2, ih * a)
        // Lower by half the room it leaves, so the words and the card sit in the middle together.
        return CGRect(x: full.midX - iw / 2 - pad, y: top + (full.height - ih - pad * 2) / 2, width: iw + pad * 2, height: ih + pad * 2)
    }

    static func screenPicture(width w: CGFloat, place: CarouselPlace, aspect: CGFloat? = nil) -> CGRect {
        screenCard(width: w, place: place, aspect: aspect).insetBy(dx: w * 0.02, dy: w * 0.02)
    }

    /// A screen card's picture's shape, once it is loaded.
    static func screenAspect(_ slide: CarouselSlide, session: URL?) -> CGFloat? {
        guard let u = session.flatMap({ CarouselFile.resolve(slide.media, in: $0) }),
              let img = SlidePictures.shared.image(u, at: slide.plays ? (slide.start ?? 0) : slide.at),
              img.size.height > 0 else { return nil }
        return img.size.width / img.size.height
    }

    /// The desk: your photo, else a green cutting mat on a dark desk; stickers and the white line on top.
    var deskPage: some View {
        let u = style.backdrop.isEmpty ? nil : session.flatMap { CarouselFile.resolve(style.backdrop, in: $0) }
        let img = u.flatMap { SlidePictures.shared.image($0, at: nil) }
        return ZStack {
            if let img {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: width, height: height).clipped()
            } else {
                Color(hex: 0x2A241E)
                cuttingMat.frame(width: width * 1.12, height: height * 1.0).rotationEffect(.degrees(-3)).offset(x: width * 0.07, y: width * 0.02)
            }
            RadialGradient(colors: [.clear, .black.opacity(0.4)], center: .center, startRadius: width * 0.3, endRadius: width * 1.0)
            squiggle
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var height: CGFloat { width / place.ratio }

    private var cuttingMat: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x1E6E4E)))
            let step = size.width / 26
            var thin = Path(), thick = Path()
            var n = 0
            var x: CGFloat = 0
            while x <= size.width { (n % 5 == 0 ? { thick.move(to: CGPoint(x: x, y: 0)); thick.addLine(to: CGPoint(x: x, y: size.height)) } : { thin.move(to: CGPoint(x: x, y: 0)); thin.addLine(to: CGPoint(x: x, y: size.height)) })(); x += step; n += 1 }
            n = 0
            var y: CGFloat = 0
            while y <= size.height { (n % 5 == 0 ? { thick.move(to: CGPoint(x: 0, y: y)); thick.addLine(to: CGPoint(x: size.width, y: y)) } : { thin.move(to: CGPoint(x: 0, y: y)); thin.addLine(to: CGPoint(x: size.width, y: y)) })(); y += step; n += 1 }
            ctx.stroke(thin, with: .color(.white.opacity(0.13)), lineWidth: max(0.5, size.width / 1400))
            ctx.stroke(thick, with: .color(.white.opacity(0.3)), lineWidth: max(0.6, size.width / 700))
            // The ruler down the left edge.
            var ticks = Path()
            var t: CGFloat = 0
            var k = 0
            while t <= size.height {
                let len = k % 5 == 0 ? step * 0.7 : step * 0.35
                ticks.move(to: CGPoint(x: step * 0.6, y: t)); ticks.addLine(to: CGPoint(x: step * 0.6 + len, y: t))
                t += step / 2; k += 1
            }
            ctx.stroke(ticks, with: .color(.white.opacity(0.45)), lineWidth: max(0.5, size.width / 1000))
        }
    }

    /// A white line drawn across the foot of the slide, with a loop now and then.
    private var squiggle: some View {
        let tall = place == .tiktok
        return Canvas { ctx, size in
            let a = size.width * 0.02
            let y0 = size.height - size.width * (tall ? 0.52 : 0.055)
            var p = Path()
            var t: CGFloat = 0
            var started = false
            while true {
                let b = a * (0.55 + 1.5 * max(0, sin(t * 0.33 + CGFloat(index))))
                let x = -a + a * t - b * sin(t)
                let y = y0 + b * cos(t) + sin(t * 0.21) * a * 0.6
                if started { p.addLine(to: CGPoint(x: x, y: y)) } else { p.move(to: CGPoint(x: x, y: y)); started = true }
                if x > size.width + a * 2 { break }
                t += 0.08
            }
            ctx.stroke(p, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: max(1, size.width * 0.0055), lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }

    /// Two paper stickers over the slide: one top left, one bottom right, a different pair on each slide.
    /// Where a kicker tag sits top left (a photo, frames, a magazine page) only the bottom one.
    var stickers: some View {
        let tall = place == .tiktok
        let icons = Self.stickerIcons
        let a = icons[(index * 2) % icons.count], b = icons[(index * 2 + 5) % icons.count]
        let size = width * 0.07
        let top = [.text, .word, .list, .screen].contains(slide.layout)
        return ZStack {
            if top {
                sticker(a, size: size).rotationEffect(.degrees(-12))
                    .position(x: width * 0.075, y: tall ? width * 0.2 : width * 0.075)
            }
            sticker(b, size: size).rotationEffect(.degrees(10))
                .position(x: width * (tall ? 0.72 : 0.9), y: height - width * (tall ? 0.6 : 0.13))
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// A symbol cut out of paper: black, a white edge round it, a soft shadow.
    private func sticker(_ name: String, size: CGFloat) -> some View {
        let glyph = Image(systemName: name).font(.system(size: size, weight: .semibold))
        let o = size * 0.09
        return ZStack {
            ForEach(0..<12, id: \.self) { k in
                glyph.foregroundStyle(.white).offset(x: o * cos(Double(k) * .pi / 6), y: o * sin(Double(k) * .pi / 6))
            }
            glyph.foregroundStyle(Self.tape)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: size * 0.08, y: size * 0.05)
    }

    /// Text, one word and a list on the desk: on a dark notebook, the words white with the key ones yellow.
    var notebookSlide: some View {
        let tall = place == .tiktok
        let free = height - (tall ? width * 0.25 + width * 0.58 : width * 0.16)
        let nw = width * (tall ? 0.6 : 0.56)
        let nh = min(free * 0.92, nw * 1.48)
        let cy = tall ? width * 0.25 + free / 2 : height / 2
        let ink = Color.white
        let rows = slide.body.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { r in r.replacingOccurrences(of: #"^([-•*]|\d+[.)]|\[ ?\]|\[x\])\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        let n = slide.title.count
        let size = slide.layout == .word ? nw * (n > 12 ? 0.18 : 0.26) : nw * (n > 50 ? 0.085 : n > 30 ? 0.1 : 0.12)
        return ZStack {
            RoundedRectangle(cornerRadius: nw * 0.05)
                .fill(LinearGradient(colors: [Color(hex: 0x4A4A3E), Color(hex: 0x33332A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color(hex: 0x1C1C17)).frame(width: nw * 0.035).padding(.trailing, nw * 0.12)
                }
                .overlay(RoundedRectangle(cornerRadius: nw * 0.05).strokeBorder(.black.opacity(0.35), lineWidth: max(1, nw * 0.006)))
                .shadow(color: .black.opacity(0.5), radius: nw * 0.05, x: nw * 0.02, y: nw * 0.04)
            VStack(spacing: nw * 0.05) {
                kickerLine(kick)
                titleLine(size, ink, align: .center, strip: false)
                if slide.layout == .list {
                    if edit != nil {
                        line(slide.body, hint: "One step a line", font: style.text(nw * 0.07, .bold), color: ink, align: .center) { $0.body = $1 }
                    } else {
                        VStack(spacing: nw * 0.015) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                                Text("\(i + 1)) " + r).font(style.text(nw * (rows.count > 6 ? 0.055 : 0.07), .heavy)).foregroundStyle(ink)
                                    .tracking(-nw * 0.002).multilineTextAlignment(.center)
                            }
                        }
                    }
                } else {
                    bodyLine(nw * 0.075, ink)
                }
            }
            .padding(.horizontal, nw * 0.1)
            .frame(width: nw, height: nh)
        }
        .frame(width: nw, height: nh)
        .rotationEffect(.degrees(-2))
        .position(x: width / 2, y: cy)
        .frame(width: width, height: height)
    }

    /// The words on top, a white card with a picture or a screen take under them, an aside on its corner.
    var screenSlide: some View {
        let aspect = Self.screenAspect(slide, session: session)
        let card = Self.screenCard(width: width, place: place, aspect: aspect)
        let pic = Self.screenPicture(width: width, place: place, aspect: aspect)
        let pad = pic.minX - card.minX
        let head = card.minY - (place == .tiktok ? width * 0.25 : width * 0.08) - width * 0.05
        let side = place == .tiktok ? EdgeInsets(top: 0, leading: width * 0.08, bottom: 0, trailing: width * 0.2)
            : EdgeInsets(top: 0, leading: width * 0.06, bottom: 0, trailing: width * 0.06)
        return ZStack(alignment: .topLeading) {
            Group {
                if overlayOnly { Rectangle().strokeBorder(.white, lineWidth: pad) } else { Rectangle().fill(.white) }
            }
            .frame(width: card.width, height: card.height)
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: width * 0.02, y: width * 0.01)
            .position(x: card.midX, y: card.midY)
            picture(slide.media, at: slide.plays ? (slide.start ?? 0) : slide.at, width: pic.width, height: pic.height,
                    hint: "Drop a screen take", fit: true)
                .overlay(alignment: .topLeading) { videoBadge.padding(width * 0.015) }
                .position(x: pic.midX, y: pic.midY)
            VStack(spacing: width * 0.015) {
                kickerLine(kick)
                titleLine(width * titleScale(0.068), fg, align: .center)
                if !desk { bodyLine(width * 0.034, fg.opacity(0.85), align: .center) }
            }
            .frame(width: width - side.leading - side.trailing, height: head, alignment: .bottom)
            .position(x: side.leading + (width - side.leading - side.trailing) / 2, y: card.minY - width * 0.05 - head / 2)
            if desk {
                bodyLine(width * 0.036, fg)
                    .frame(width: card.width * 0.7, alignment: .trailing)
                    .position(x: card.maxX - card.width * 0.35 + width * 0.02, y: card.minY + width * 0.005)
            }
        }
        .frame(width: width, height: height)
    }
}

/// A line of the slide, typed in place on the post: no box, the slide's own font.
struct SlideField: View {
    let text: String
    let hint: String
    let font: Font
    let color: Color
    var align: TextAlignment = .leading
    let set: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("", text: $draft, prompt: Text(hint).foregroundStyle(color.opacity(0.45)), axis: .vertical)
            .textFieldStyle(.plain).font(font).foregroundStyle(color)
            .multilineTextAlignment(align)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { draft = text }
            .onChange(of: text) { _, t in if t != draft { draft = t } }
            .onChange(of: draft) { _, d in if d != text { set(d) } }
            .help("Click to edit")
    }
}
