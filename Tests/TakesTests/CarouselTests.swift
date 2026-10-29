import AppKit
import SwiftUI
import Testing
@testable import Takes

/// Carousels on the Post tab (Carousel.swift). Pictures of the LinkedIn and Vertical posts with slides:
/// TAKES_CAROUSEL=/tmp/shots ./test.sh --filter CarouselShots
let carouselDir = ProcessInfo.processInfo.environment["TAKES_CAROUSEL"]

@MainActor @Suite(.serialized) struct CarouselTests {
    static let slides = [
        CarouselSlide(kicker: "Swipe →", title: "5 things I wish I knew before filming on my phone", body: "Save this for your next video."),
        CarouselSlide(kicker: "Tip 1", title: "Light from the front", body: "Face a window. Never sit with it behind you."),
        CarouselSlide(kicker: "Tip 2", title: "Lock the exposure", body: "Hold on your face until AE/AF Lock shows."),
        CarouselSlide(kicker: "Tip 3", title: "The mic beats the camera", body: "A clip-on mic does more than a new phone."),
        CarouselSlide(kicker: "Tip 4", title: "Look at the lens", body: "Put your script right under the camera."),
        CarouselSlide(kicker: "Tip 5", title: "Cut the first 2 seconds", body: "Start on the point, not on the hello."),
        CarouselSlide(kicker: "That's it", title: "Save this. Film one today.", body: "Follow for a tip every week."),
    ]

    static func session() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "carousel-\(UUID().uuidString)")
        let s = root.appending(path: "Phone filming/5 things")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["title": "5 things I wish I knew", "createdAt": "2026-10-26T10:00:00Z", "named": true, "takes": []])
            .write(to: s.appending(path: "session.json"))
        return s
    }

    static func clean(_ s: URL) { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }

    @Test func fileRoundTripsAndReadsOldFiles() throws {
        let s = try Self.session()
        defer { Self.clean(s) }
        #expect(CarouselFile.read(s) == nil && !CarouselFile.isOn(s, .linkedin))
        let c = CarouselFile(slides: Self.slides, on: ["linkedin": true], docTitle: "5 things")
        #expect(CarouselFile.write(c, to: s))
        #expect(CarouselFile.read(s) == c && CarouselFile.isOn(s, .linkedin) && !CarouselFile.isOn(s, .vertical))
        // The first build kept captions in it, and the MCP server may leave keys out.
        try Data(#"{"slides":[{"title":"Only"}],"captions":{"linkedin":"old"}}"#.utf8).write(to: CarouselFile.url(s))
        let old = try #require(CarouselFile.read(s))
        #expect(old.slides == [CarouselSlide(title: "Only")] && old.on.isEmpty && !old.isOn(.linkedin))
    }

    @Test func turningOnStartsSlidesOnceAndKeepsThem() throws {
        let s = try Self.session()
        defer { Self.clean(s) }
        let first = CarouselFile.set(.linkedin, on: true, in: s, title: "5 things I wish I knew")
        #expect(first.slides.count == 4 && first.slides[0].title == "5 things I wish I knew" && first.isOn(.linkedin))
        var c = first
        c.slides[1].title = "Mine"
        CarouselFile.write(c, to: s)
        let both = CarouselFile.set(.vertical, on: true, in: s, title: "x")
        #expect(both.slides[1].title == "Mine" && both.isOn(.linkedin) && both.isOn(.vertical))
        let off = CarouselFile.set(.linkedin, on: false, in: s, title: "x")
        #expect(!off.isOn(.linkedin) && off.slides.count == 4)
    }

    @Test func verticalPhotosGoToTikTokAndInstagram() {
        #expect(CarouselPlace.photos(VerticalPlace.allCases) == [.tiktok, .instagram])
        #expect(CarouselPlace.photos([.reels]) == [.instagram])
        #expect(CarouselPlace.photos([.shorts]).isEmpty)
    }

    @Test func contextNamesTheSlides() throws {
        let c = CarouselFile(slides: Self.slides, on: ["linkedin": true])
        let line = try #require(c.context(.linkedin))
        #expect(line.contains("carousel (a PDF)") && line.contains("7 slides") && line.contains("2. Light from the front"))
        #expect(c.context(.vertical) == nil && c.context(.x) == nil)
    }

    @Test func exportWritesTheSizesEachAppWants() async throws {
        let s = try Self.session()
        defer { Self.clean(s) }
        for place in [CarouselPlace.instagram, .tiktok] {
            let rel = try await CarouselExport.run(CarouselFile(slides: Self.slides), place: place, session: s, name: "Test Name")
            let dir = s.appending(path: rel)
            let pngs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
            #expect(pngs.count == 7 && pngs.first == "slide-01.png" && pngs.last == "slide-07.png")
            let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appending(path: "slide-01.png"))))
            #expect(CGFloat(rep.pixelsWide) == place.size.width && CGFloat(rep.pixelsHigh) == place.size.height)
        }
        #expect(try await CarouselExport.run(CarouselFile(slides: Self.slides), place: .linkedin, session: s, name: "Test Name") == "posts/carousel/linkedin.pdf")
        let pdf = try #require(CGPDFDocument(s.appending(path: "posts/carousel/linkedin.pdf") as CFURL))
        #expect(pdf.numberOfPages == 7 && pdf.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 1080, height: 1350))
        // Fewer slides next time: the old ones go.
        let rel = try await CarouselExport.run(CarouselFile(slides: Array(Self.slides.prefix(4))), place: .instagram, session: s, name: "Test Name")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.appending(path: rel).path).filter { $0.hasSuffix(".png") }.count == 4)
    }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardizedFileURL
    static let demo = repo.appending(path: "scripts/public/demo-media")

    /// A demo picture at `to`. The public copy has no scripts/public (2026-10-29: the release's own
    /// test run failed on it), so there a plain picture of the same shape stands in.
    static func demoPicture(_ name: String, to: URL, size: CGSize = CGSize(width: 1080, height: 1920)) throws {
        let from = demo.appending(path: name)
        if FileManager.default.fileExists(atPath: from.path) { return try FileManager.default.copyItem(at: from, to: to) }
        let ctx = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let type = to.pathExtension == "png" ? "public.png" : "public.jpeg"
        let dest = try #require(CGImageDestinationCreateWithURL(to as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A session with made-up stills and a storyboard whose shots have takes (the demo pictures).
    static func filmedSession() throws -> URL {
        let s = try session()
        let fm = FileManager.default
        try fm.createDirectory(at: s.appending(path: "stills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: s.appending(path: "storyboard"), withIntermediateDirectories: true)
        for (i, who) in ["maya", "arjun", "lin", "sam"].enumerated() {
            try demoPicture("\(who)/creator-tall.jpg", to: s.appending(path: String(format: "stills/still-%02d.jpg", i + 1)))
        }
        let sketches = ((try? fm.contentsOfDirectory(atPath: demo.appending(path: "sketches").path)) ?? ["sketch-1.png", "sketch-2.png", "sketch-3.png"])
            .filter { $0.hasSuffix(".png") }.sorted()
        var shots: [[String: Any]] = []
        for (i, f) in sketches.prefix(3).enumerated() {
            try demoPicture("sketches/\(f)", to: s.appending(path: "storyboard/\(f)"), size: CGSize(width: 1080, height: 1920))
            shots.append(["id": "s\(i)", "kind": "SHOT", "say": "Line \(i + 1) of the script, said to the lens", "do": "Wide, at eye height", "image": f])
        }
        try JSONSerialization.data(withJSONObject: ["shots": shots, "format": "9:16"]).write(to: s.appending(path: "storyboard/storyboard.json"))
        // Takes for shots 0 and 1; shot 2 was not filmed. The take files are pictures here: a still is enough to draw.
        try JSONSerialization.data(withJSONObject: [
            "title": "How I film on my phone", "createdAt": "2026-10-26T10:00:00Z", "named": true,
            "takes": [["number": 1, "kind": "camera", "file": "stills/still-02.jpg", "startedAt": "2026-10-26T10:01:00Z", "shot": "s0", "keeper": false],
                      ["number": 2, "kind": "camera", "file": "stills/still-03.jpg", "startedAt": "2026-10-26T10:02:00Z", "shot": "s1", "keeper": true],
                      ["number": 3, "kind": "camera", "file": "stills/still-04.jpg", "startedAt": "2026-10-26T10:03:00Z", "shot": "s1", "keeper": false]]])
            .write(to: s.appending(path: "session.json"))
        try Data(#"{"2": {"state": "done", "start": 3.5, "end": 9}}"#.utf8).write(to: s.appending(path: "cuts.json"))
        return s
    }

    @Test func slidesKeepOnlyWhatIsSet() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let text = String(decoding: try enc.encode(CarouselSlide(kicker: "1", title: "A", body: "")), as: UTF8.self)
        #expect(text == #"{"body":"","kicker":"1","title":"A"}"#)
        let full = CarouselSlide(layout: .frames, title: "Shots", items: [SlideItem(media: "stills/a.jpg", at: 2, label: "WS", text: "Wide")],
                                 marks: [SlideMark(x: 0.2, y: 0.4, text: "Light")])
        #expect(try JSONDecoder().decode(CarouselSlide.self, from: enc.encode(full)) == full)
        // A layout from a newer Takes reads as text; a mark off the picture stays on it.
        let odd = try JSONDecoder().decode(CarouselSlide.self, from: Data(#"{"layout":"hologram","title":"x","marks":[{"x":3,"y":-1}]}"#.utf8))
        #expect(odd.layout == .text && odd.marks == [SlideMark(x: 1, y: 0)])
        let file = try JSONDecoder().decode(CarouselFile.self, from: Data(##"{"slides":[],"look":"bold","accent":"#00FF88"}"##.utf8))
        #expect(file.look == .bold && file.accent == "#00FF88")
        #expect(try JSONDecoder().decode(CarouselFile.self, from: Data(#"{"look":"neon"}"#.utf8)).look == .takes)
        #expect(!String(decoding: try enc.encode(CarouselFile()), as: UTF8.self).contains("look"))
    }

    @Test func mediaResolvesInTheSessionOrAnywhere() {
        let s = URL(fileURLWithPath: "/tmp/x/session")
        #expect(CarouselFile.resolve("stills/a.jpg", in: s)?.path == "/tmp/x/session/stills/a.jpg")
        #expect(CarouselFile.resolve("/Users/a/b.png", in: s)?.path == "/Users/a/b.png")
        #expect(CarouselFile.resolve(" ", in: s) == nil)
    }

    @Test func templatesFillFromTheSession() throws {
        let s = try Self.filmedSession()
        defer { Self.clean(s) }
        #expect(CarouselTemplate.auto(s) == .filmed)
        let filmed = CarouselTemplate.filmed.slides(s, title: "How I film on my phone")
        #expect(filmed.first?.layout == .cover && filmed.first?.media == "stills/still-01.jpg")
        #expect(filmed[1].layout == .frames && filmed[1].items.count == 3 && filmed[1].items[0].media.hasPrefix("storyboard/"))
        let pairs = filmed.filter { $0.layout == .compare }
        // Shot 2 has no take; shot 1's keeper (take 2) wins over the newer take 3, a second into its best cut.
        #expect(pairs.count == 2)
        #expect(pairs[1].items[1] == SlideItem(media: "stills/still-03.jpg", at: 4.5, label: "Filmed"))
        #expect(pairs[0].items[1].at == 1 && pairs[0].items[0].label == "Sketch")
        #expect(filmed.last?.layout == .word)
        let photos = CarouselTemplate.photos.slides(s, title: "T")
        #expect(photos.count == 5 && photos[1...3].allSatisfy { $0.layout == .photo } && photos[3].media == "stills/still-04.jpg")
        // A session with nothing still gets slides to fill in.
        let empty = try Self.session()
        defer { Self.clean(empty) }
        #expect(CarouselTemplate.auto(empty) == .tips)
        for t in CarouselTemplate.allCases { #expect(t.slides(empty, title: "T").count >= 2) }
        #expect(CarouselFile.set(.linkedin, on: true, in: s, title: "T").look == .bold)
    }

    @Test func droppedFilesLandOnTheSlide() throws {
        let s = try Self.filmedSession()
        defer { Self.clean(s) }
        CarouselFile.write(CarouselFile(slides: [CarouselSlide(title: "Hook"), CarouselSlide(), CarouselSlide(layout: .frames)]), to: s)
        let store = CarouselStore()
        store.load(s)
        // From outside the session: copied in. On a text slide with a title: a cover photo.
        let outside = s.deletingLastPathComponent().deletingLastPathComponent().appending(path: "creator-wide.jpg")
        try Self.demoPicture("maya/creator-wide.jpg", to: outside, size: CGSize(width: 1920, height: 1080))
        store.put([outside], on: 0)
        #expect(store.file?.slides[0].layout == .cover && store.file?.slides[0].media == "posts/carousel/media/creator-wide.jpg")
        #expect(FileManager.default.fileExists(atPath: s.appending(path: "posts/carousel/media/creator-wide.jpg").path))
        store.put([outside], on: 1)
        #expect(store.file?.slides[1].media == "posts/carousel/media/creator-wide-2.jpg" && store.file?.slides[1].layout == .photo)
        // In the session: kept where it is. Frames fill in order.
        store.put([s.appending(path: "stills/still-01.jpg"), s.appending(path: "stills/still-02.jpg")], on: 2)
        #expect(store.file?.slides[2].items.map(\.media) == ["stills/still-01.jpg", "stills/still-02.jpg"])
        // A video makes a video slide.
        try Data().write(to: s.appending(path: "take-01-camera.mov"))
        store.put([s.appending(path: "take-01-camera.mov")], on: 1)
        #expect(store.file?.slides[1].layout == .video && store.file?.slides[1].media == "take-01-camera.mov")
    }

    @Test func phoneChangesLayoutLookAndTemplate() throws {
        let s = try Self.filmedSession()
        defer { Self.clean(s) }
        #expect(CarouselFile.phoneChange(["template": "story"], in: s, title: "T") == nil)
        #expect(CarouselFile.read(s)?.look == .magazine && CarouselFile.read(s)?.slides[1].layout == .magazine)
        #expect(CarouselFile.phoneChange(["look": "note"], in: s, title: "T") == nil)
        #expect(CarouselFile.phoneChange(["slide": "1", "layout": "word"], in: s, title: "T") == nil)
        let c = try #require(CarouselFile.read(s))
        #expect(c.look == .note && c.slides[1].layout == .word)
        #expect(CarouselFile.phoneChange(["look": "neon"], in: s, title: "T") == "No such look")
        #expect(CarouselFile.phoneChange(["slide": "1", "layout": "x"], in: s, title: "T") == "No such layout")
        #expect(CarouselFile.phoneChange(["template": "x"], in: s, title: "T") == "No such template")
    }

    @Test func videoSlideArgsFillTheSlideAndKeepTheSound() {
        let a = CarouselExport.videoArgs(URL(fileURLWithPath: "/c.mov"), start: 2, end: 9.5, overlay: URL(fileURLWithPath: "/o.png"),
                                         size: CarouselPlace.instagram.size, to: URL(fileURLWithPath: "/out.mp4"))
        #expect(a.contains("2.000") && a.contains("7.500") && a.last == "/out.mp4")
        #expect(a.joined(separator: " ").contains("scale=1080:1440:force_original_aspect_ratio=increase,crop=1080:1440"))
        #expect(a.contains("0:a?"))
        let long = CarouselExport.videoArgs(URL(fileURLWithPath: "/c.mov"), start: nil, end: nil, overlay: URL(fileURLWithPath: "/o.png"),
                                            size: CarouselPlace.instagram.size, to: URL(fileURLWithPath: "/out.mp4"))
        #expect(long.contains("60.000"))
        #expect(CarouselPlace.instagram.plays && !CarouselPlace.tiktok.plays && !CarouselPlace.linkedin.plays)
    }

    @Test func exportDrawsPicturesAndTheVideoSlide() async throws {
        let s = try Self.filmedSession()
        defer { Self.clean(s) }
        var c = CarouselFile(slides: CarouselTemplate.filmed.slides(s, title: "T"), look: .bold)
        let hasFFmpeg = Setup.tool("ffmpeg") != nil
        if hasFFmpeg {
            // A 2 s test clip from a still.
            try await Cover.ffmpeg(["-y", "-loop", "1", "-i", s.appending(path: "stills/still-01.jpg").path, "-t", "2", "-r", "10",
                                    "-vf", "scale=360:640", "-pix_fmt", "yuv420p", s.appending(path: "clip.mp4").path])
            c.slides.insert(CarouselSlide(layout: .video, title: "Watch", media: "clip.mp4"), at: 1)
        }
        let rel = try await CarouselExport.run(c, place: .instagram, session: s, name: "Test Name")
        let names = try FileManager.default.contentsOfDirectory(atPath: s.appending(path: rel).path).sorted()
        #expect(names.first == "slide-01.png" && names.count == c.slides.count)
        if hasFFmpeg { #expect(names[1] == "slide-02.mp4") }
        // The cover has the still under it: not one flat colour.
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: s.appending(path: "\(rel)/slide-01.png"))))
        #expect(rep.pixelsHigh == 1440)
        let a = rep.colorAt(x: 540, y: 300), b = rep.colorAt(x: 200, y: 700)
        #expect(a != b)
        // TikTok has no video in photo posts: the video slide is a picture there.
        let tik = try await CarouselExport.run(c, place: .tiktok, session: s, name: "Test Name")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.appending(path: tik).path).allSatisfy { $0.hasSuffix(".png") })
    }

    @Test func phoneChangesTheFile() throws {
        let s = try Self.session()
        defer { Self.clean(s) }
        #expect(CarouselFile.phoneChange(["slide": "0", "title": "x"], in: s, title: "T") == "No carousel")
        #expect(CarouselFile.phoneChange(["platform": "vertical", "on": "true"], in: s, title: "T") == nil)
        #expect(CarouselFile.isOn(s, .vertical))
        #expect(CarouselFile.phoneChange(["slide": "1", "title": "Face the window"], in: s, title: "T") == nil)
        #expect(CarouselFile.phoneChange(["action": "add"], in: s, title: "T") == nil)
        #expect(CarouselFile.phoneChange(["slide": "40", "title": "x"], in: s, title: "T") == "Nothing to change")
        #expect(CarouselFile.phoneChange(["platform": "x", "on": "true"], in: s, title: "T") == "Nothing to change")
        var c = try #require(CarouselFile.read(s))
        // Added before the last slide: the ask stays last.
        #expect(c.slides[1].title == "Face the window" && c.slides.count == 5)
        #expect(c.slides[3].title == "New slide" && c.slides[4].title == "Save this.")
        #expect(CarouselFile.phoneChange(["action": "delete", "slide": "3"], in: s, title: "T") == nil)
        c = try #require(CarouselFile.read(s))
        #expect(c.slides.count == 4 && !c.slides.contains { $0.title == "New slide" })
        #expect(CarouselFile.phoneChange(["action": "delete", "slide": "0"], in: s, title: "T") == nil)
        #expect(CarouselFile.phoneChange(["action": "delete", "slide": "0"], in: s, title: "T") == nil)
        #expect(CarouselFile.phoneChange(["action": "delete", "slide": "0"], in: s, title: "T") == "A carousel keeps two slides or more")
        #expect(CarouselFile.read(s)?.slides.count == 2)
    }

    @Test func storeEditsReachTheFile() throws {
        let s = try Self.session()
        defer { Self.clean(s) }
        let store = CarouselStore()
        store.load(s)
        #expect(store.file == nil)
        store.set(.linkedin, on: true, title: "5 things I wish I knew")
        #expect(store.file?.slides.count == 4 && store.file?.isOn(.linkedin) == true)
        store.change { $0.slides[1].title = "Changed" }
        #expect(CarouselFile.read(s)?.slides[1].title == "First point")
        store.flush()
        #expect(CarouselFile.read(s)?.slides[1].title == "Changed")
    }
}

@MainActor @Suite(.serialized) struct CarouselShots {
    func shoot(_ name: String, _ view: some View, size: CGSize, dark: Bool = false) async {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(1.6)
        while Date() < end { try? await Task.sleep(for: .milliseconds(100)); SessionMode.set(.post); host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: carouselDir!).appending(path: "\(name).png"))
    }

    /// Every layout in every look, at Instagram's size: TAKES_CAROUSEL=/tmp/shots ./test.sh --filter CarouselShots
    @Test(.enabled(if: carouselDir != nil)) func everyLayoutInEveryLook() async throws {
        _ = NSApplication.shared
        for f in (try? FileManager.default.contentsOfDirectory(at: CarouselTests.repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let s = try CarouselTests.filmedSession()
        defer { CarouselTests.clean(s) }
        let filmed = CarouselTemplate.filmed.slides(s, title: "How I film every video on my phone")
        let slides: [CarouselSlide] = [
            filmed[0],
            CarouselSlide(layout: .word, kicker: "Rule 1", title: "Light.", body: "Everything else comes after."),
            CarouselSlide(kicker: "Tip 2", title: "Lock the exposure", body: "Hold on your face until AE/AF Lock shows."),
            filmed[1],
            filmed[2],
            CarouselSlide(layout: .annotate, kicker: "The setup", title: "Where it all goes", body: "One window, one mic, the phone at eye height.",
                          media: "stills/still-02.jpg", marks: [SlideMark(x: 0.3, y: 0.28, text: "Window light"), SlideMark(x: 0.62, y: 0.6, text: "Mic here")]),
            CarouselSlide(layout: .magazine, kicker: "Part 2", title: "The day I stopped buying gear",
                          body: "I had three cameras and no videos. Then I filmed one a day on the phone in my pocket, for a month.", media: "stills/still-04.jpg"),
            CarouselSlide(layout: .list, kicker: "Before you film", title: "The checklist", body: "Face the window\nLock the exposure\nClip the mic on\nLook at the lens"),
            CarouselSlide(layout: .photo, kicker: "Behind the scenes", title: "Day 12", media: "stills/still-03.jpg"),
            CarouselSlide(layout: .video, title: "Watch the take", media: "stills/still-01.jpg"),
            CarouselSlide(kicker: "That's it", title: "Save this.", body: "Follow for more."),
        ]
        let dir = URL(fileURLWithPath: carouselDir!)
        let pics = slides.flatMap { sl in sl.files.compactMap { CarouselFile.resolve($0, in: s) }.map { ($0, Optional<Double>.none) } }
        await SlidePictures.shared.preload(pics)
        for look in CarouselLook.allCases {
            let style = SlideStyle(look)
            for (i, sl) in slides.enumerated() {
                let v = CarouselSlideView(slide: sl, index: i, total: slides.count, place: .instagram, name: "Maya Chen", width: 540,
                                          style: style, session: s, exporting: true)
                try CarouselExport.png(v, to: dir.appending(path: String(format: "look-%@-%02d-%@.png", look.rawValue, i + 1, sl.layout.rawValue)))
            }
        }
        // TikTok's safe zones, and the Post tab's empty picture.
        for (i, sl) in [filmed[0], slides[5], CarouselSlide(layout: .cover, title: "No picture yet")].enumerated() {
            let v = CarouselSlideView(slide: sl, index: i, total: 3, place: .tiktok, name: "Maya Chen", width: 540, style: SlideStyle(.bold), session: s)
            try CarouselExport.png(v, to: dir.appending(path: "tiktok-\(i + 1).png"))
        }
    }

    @Test(.enabled(if: carouselDir != nil)) func postTab() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let setup = Setup.shared
        (setup.agent, setup.signedIn, setup.ffmpeg) = (.ok, .ok, .ok)
        UserDefaults.standard.set(false, forKey: "chatOpen")
        UserDefaults.standard.set("post", forKey: "rightTab")
        UserDefaults.standard.set("tiktok", forKey: "verticalPreview")
        let s = try CarouselTests.filmedSession()
        defer { CarouselTests.clean(s) }
        PostFile.write(PostFile.Content(text: "I filmed every video this year on my phone.\nThese 5 changes did more than any new gear.\n\nWhich one do you skip?\n"), to: s, .linkedin)
        PostFile.write(PostFile.Content(text: "5 phone filming tips I wish I knew sooner #filmingtips #creator\n"), to: s, .vertical)
        CarouselFile.write(CarouselFile(slides: CarouselTemplate.filmed.slides(s, title: "How I film every video on my phone"),
                                        on: ["linkedin": true, "vertical": true], docTitle: "5 things", look: .bold), to: s)
        let app = AppModel()
        app.library.setRoot(s.deletingLastPathComponent().deletingLastPathComponent())
        SessionView.write(s, mode: .post, file: nil, time: nil)
        app.library.select(s)
        SessionMode.set(.post)
        app.chats.open = false
        func window() -> some View {
            ContentView(library: app.library).environment(app).tint(Theme.accent).font(Theme.body).foregroundStyle(Theme.ink)
        }
        let size = CGSize(width: 1440, height: 900)
        UserDefaults.standard.set("linkedin", forKey: "postPlatform")
        await shoot("1-linkedin-carousel", window(), size: size)
        await shoot("1-linkedin-carousel-dark", window(), size: size, dark: true)
        UserDefaults.standard.set("x", forKey: "postPlatform")
        await shoot("tmp", window(), size: CGSize(width: 200, height: 200))
        UserDefaults.standard.set("vertical", forKey: "postPlatform")
        await shoot("2-vertical-photos", window(), size: size)
        UserDefaults.standard.set("reels", forKey: "verticalPreview")
        UserDefaults.standard.set("x", forKey: "postPlatform")
        await shoot("tmp", window(), size: CGSize(width: 200, height: 200))
        UserDefaults.standard.set("vertical", forKey: "postPlatform")
        await shoot("2-vertical-photos-instagram", window(), size: size)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: carouselDir!).appending(path: "tmp.png"))
    }
}
