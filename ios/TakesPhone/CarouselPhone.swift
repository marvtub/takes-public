import SwiftUI

/// The session's slides on the phone's Post tab (2026-10-26), as on the Mac (Sources/Takes/Carousel.swift):
/// the LinkedIn post switches its media from Video to Carousel (a PDF), the vertical post from Video to
/// Photos. The slides show where the video would be; the text stays the post's own. Export stays on the Mac.
struct CarouselSlide: Codable, Hashable {
    var kicker: String = ""
    var title: String = ""
    var body: String = ""
    /// What the slide is (2026-10-29): "text", "word", "cover", "photo", "frames", "compare", "annotate",
    /// "magazine", "list", "video". The Mac draws it; the phone shows the Mac's picture.
    var layout: String = "text"
    var media: String = ""

    enum CodingKeys: String, CodingKey { case kicker, title, body, layout, media }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "text"
        media = try c.decodeIfPresent(String.self, forKey: .media) ?? ""
    }
}

struct Carousel: Codable, Hashable {
    var slides: [CarouselSlide]
    var on: [String: Bool]
    var docTitle: String
    var look: String = "takes"
    var accent: String = ""

    enum CodingKeys: String, CodingKey { case slides, on, docTitle, look, accent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slides = try c.decodeIfPresent([CarouselSlide].self, forKey: .slides) ?? []
        on = try c.decodeIfPresent([String: Bool].self, forKey: .on) ?? [:]
        docTitle = try c.decodeIfPresent(String.self, forKey: .docTitle) ?? ""
        look = try c.decodeIfPresent(String.self, forKey: .look) ?? "takes"
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? ""
    }

    func isOn(_ platform: String) -> Bool { on[platform] == true && !slides.isEmpty }

    /// The layouts and looks, as the Mac names them (Sources/Takes/Carousel.swift).
    static let layouts: [(String, String, String)] = [
        ("text", "Text", "textformat"), ("word", "One word", "textformat.size.larger"), ("cover", "Cover photo", "photo.artframe"),
        ("photo", "Photo only", "photo"), ("frames", "Frames", "square.grid.2x2"), ("compare", "Before and after", "rectangle.split.2x1"),
        ("annotate", "Photo with notes", "mappin.and.ellipse"), ("magazine", "Magazine page", "newspaper"),
        ("list", "List", "list.number"), ("video", "Video", "play.rectangle"),
    ]
    static let looks: [(String, String)] = [("takes", "Takes"), ("bold", "Bold"), ("magazine", "Magazine"), ("note", "Note"), ("cinema", "Cinema")]
    static let templates: [(String, String)] = [("tips", "Tips"), ("filmed", "How I filmed this"), ("photos", "Photo dump"),
                                                ("story", "Magazine story"), ("note", "Note")]
}

/// Where a slide is shown: its shape, and the place the Mac draws it for.
enum SlidePlace: String {
    case instagram, linkedin, tiktok
    var ratio: CGFloat { self == .tiktok ? 9.0 / 16.0 : self == .linkedin ? 4.0 / 5.0 : 3.0 / 4.0 }
}

extension API {
    /// FNV-1a: the same words give the same URL in every launch, so the disk cache hits.
    static func stable(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    /// One slide as the Mac draws it. `v` changes with anything the slide shows, so an edit loads again.
    func slide(_ sessionID: String, _ c: Carousel, _ n: Int, place: SlidePlace, width: Int) -> URL {
        let s = c.slides[n]
        let v = [s.layout, s.kicker, s.title, s.body, s.media, c.look, c.accent, "\(n)/\(c.slides.count)"].joined(separator: "|")
        return url("/api/carousel/slide", ["id": sessionID, "n": String(n), "place": place.rawValue, "w": String(width),
                                           "v": Self.stable(v), "token": token ?? ""])
    }
}

/// Video or Carousel (LinkedIn) / Photos (vertical), under the draft bar, as the Mac's toolbar switch.
struct CarouselSwitch: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let platform: String
    let on: Bool
    let reload: () async -> Void
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ToggleChip(title: "Video", on: !on) { set(false) }
                ToggleChip(title: platform == "linkedin" ? "Carousel" : "Photos", on: on) { set(true) }
            }
            if let failed { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
        }
    }

    private func set(_ v: Bool) {
        guard v != on else { return }
        Brand.select()
        Task {
            failed = await model.tryAct("/api/carousel", ["id": sessionID], ["platform": platform, "on": v ? "true" : "false"])
            await reload()
        }
    }
}

/// The slides where the video would be, swiped one at a time, with the app's page tag. Each slide is
/// the Mac's picture of it (2026-10-29), so every layout and look shows as it exports.
struct CarouselPager: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let carousel: Carousel
    let place: SlidePlace
    @Binding var index: Int

    private var slides: [CarouselSlide] { carousel.slides }
    private var linkedin: Bool { place == .linkedin }

    var body: some View {
        GeometryReader { g in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(slides.indices, id: \.self) { n in
                        SlidePicture(sessionID: sessionID, carousel: carousel, n: n, place: place, width: g.size.width).id(n)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(get: { index }, set: { if let v = $0 { index = v } }))
            .overlay(alignment: .topTrailing) {
                Text(linkedin ? "\(index + 1) / \(slides.count)" : "\(index + 1)/\(slides.count)")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: linkedin ? AnyShape(RoundedRectangle(cornerRadius: 4)) : AnyShape(Capsule()))
                    .padding(10).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if linkedin {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.12))
                        Rectangle().fill(Color(red: 10 / 255, green: 102 / 255, blue: 194 / 255))
                            .frame(width: g.size.width * CGFloat(index + 1) / CGFloat(max(1, slides.count)))
                    }
                    .frame(height: 3).allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(place.ratio, contentMode: .fit)
        .accessibilityLabel("Slide \(index + 1) of \(slides.count)")
    }
}

/// One slide: the Mac's picture of it, at twice the width shown.
struct SlidePicture: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let carousel: Carousel
    let n: Int
    let place: SlidePlace
    let width: CGFloat

    var body: some View {
        RemoteImage(url: model.api.slide(sessionID, carousel, n, place: place, width: Int(min(1080, max(96, width * 2))))) {
            $0.resizable().scaledToFill()
        } placeholder: {
            Palette.well
        }
        .frame(width: width, height: width / place.ratio)
        .clipped()
    }
}

/// Under the post, as the Mac's slide rail: a picture of each slide (tap to show it, hold to delete),
/// + to add one before the last, and the selected slide's text to edit.
struct CarouselTools: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let carousel: Carousel
    @Binding var index: Int
    /// The vertical post goes to TikTok: it wants a sound.
    var tiktok = false
    /// The vertical post goes to Shorts: Shorts gets the video.
    var shorts = false
    let reload: () async -> Void
    @State private var editing: Field?
    @State private var failed: String?
    @State private var choosing: Choice?
    @State private var asking: String?

    private var slides: [CarouselSlide] { carousel.slides }
    private enum Field: String, Identifiable { case title, body; var id: String { rawValue } }
    private enum Choice: String, Identifiable { case layout, look; var id: String { rawValue } }

    private func note(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.circle.fill")
            .font(.inter(.footnote)).foregroundStyle(Palette.ink)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func strip(_ i: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(slides.indices, id: \.self) { n in
                    Button { Brand.select(); withAnimation(.snappy) { index = n } } label: {
                        SlidePicture(sessionID: sessionID, carousel: carousel, n: n, place: .instagram, width: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.border))
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(n == i ? Palette.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Slide \(n + 1)")
                    .contextMenu {
                        if slides.count > 2 {
                            Button("Delete slide \(n + 1)", systemImage: "trash", role: .destructive) { act(["action": "delete", "slide": String(n)], pick: max(0, i >= n ? i - 1 : i)) }
                        }
                    }
                }
                Button { act(["action": "add"], pick: max(0, slides.count - 1)) } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.muted)
                        .frame(width: 40, height: 69.3)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a slide")
            }
            .padding(2)
        }
    }

    private func act(_ change: [String: String], pick: Int) {
        Brand.select()
        Task {
            failed = await model.tryAct("/api/carousel", ["id": sessionID], change)
            if failed == nil { index = pick }
            await reload()
        }
    }

    var body: some View {
        let i = min(index, max(0, slides.count - 1))
        VStack(alignment: .leading, spacing: 8) {
            strip(i)
            HStack(spacing: 8) {
                Button("Edit big text") { editing = .title }.buttonStyle(.pill(.soft, small: true))
                Button("Edit small text") { editing = .body }.buttonStyle(.pill(.soft, small: true))
            }
            HStack(spacing: 8) {
                Button("Layout") { choosing = .layout }.buttonStyle(.pill(.soft, small: true))
                Button("Look") { choosing = .look }.buttonStyle(.pill(.soft, small: true))
            }
            if shorts { note("Shorts has no photo posts. It gets the video.") }
            if tiktok { note("Add a sound in TikTok when you post. Photo posts with a sound get more views.") }
            if let failed { Text(failed).font(.inter(.footnote)).foregroundStyle(Palette.danger) }
            Text("Pictures and export on the Mac, or ask Takes.").font(.inter(.caption)).foregroundStyle(Palette.faint)
        }
        .sheet(item: $choosing, onDismiss: { asking = nil }) { c in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let t = asking, let name = Carousel.templates.first(where: { $0.0 == t })?.1 {
                        // Starting again replaces every slide: say so first, on the same sheet.
                        Text("Start from \(name)?").font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                        Text("It takes the place of the \(slides.count) slides you have now.")
                            .font(.inter(.subheadline)).foregroundStyle(Palette.muted).padding(.top, 6)
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Cancel") { asking = nil }.buttonStyle(.pill(.quiet, small: true))
                            Button("Start from \(name)") { choosing = nil; act(["template": t], pick: 0) }.buttonStyle(.pill(.ink, small: true))
                        }
                        .padding(.top, 14)
                    } else if c == .layout {
                        Text("Slide \(i + 1)").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 4)
                        ForEach(Carousel.layouts, id: \.0) { l in
                            PanelRow(icon: l.2, title: l.1, checked: slides.indices.contains(i) && slides[i].layout == l.0) {
                                choosing = nil
                                act(["slide": String(i), "layout": l.0], pick: i)
                            }
                        }
                    } else {
                        ForEach(Carousel.looks, id: \.0) { l in
                            PanelRow(icon: "paintpalette", title: l.1, checked: carousel.look == l.0) {
                                choosing = nil
                                act(["look": l.0], pick: i)
                            }
                        }
                        PanelDivider()
                        Text("Start from").font(.inter(.footnote, .semibold)).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.vertical, 4)
                        ForEach(Carousel.templates, id: \.0) { t in
                            PanelRow(icon: "square.on.square", title: t.1) { withAnimation(Brand.quick) { asking = t.0 } }
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.paper)
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { f in
            let text = slides.indices.contains(i) ? (f == .title ? slides[i].title : slides[i].body) : ""
            TextEditSheet(title: "Slide \(i + 1): " + (f == .title ? "big text" : "small text"), text: text, font: .system(size: 16), limit: nil) { new in
                if let e = await model.tryAct("/api/carousel", ["id": sessionID], ["slide": String(i), f.rawValue: new]) {
                    throw APIError(status: 400, message: e)
                }
                await reload()
            }
        }
    }
}
