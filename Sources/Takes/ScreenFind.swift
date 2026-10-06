import AppKit
import SwiftUI
import Vision

// ⌘F: find a word on what the window shows right now (2026-10-05). Takes is mostly SwiftUI text,
// which no find panel can search, so Takes reads its own window: a snapshot of the content view,
// then Vision text recognition. Every match gets a box, Return goes to the next one. The bar
// reads the window again after a scroll, a click or a resize, so the boxes follow the screen.
// Reads are costly (a full-window snapshot on the main thread, then OCR on every core), so the
// bar reads with Vision's fast level, runs one read at a time, and reads again only when there
// is a word to find and the screen sat still for a moment.

@Observable
final class ScreenFind {
    static let shared = ScreenFind()

    /// One line of text Vision read, with the observation that gives a box for any part of it.
    struct Line {
        let text: String
        let box: (Range<String.Index>) -> CGRect?   // in the content view, top-left origin
    }

    var open = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            match(keepPlace: false)
            if moved, searching { moved = false; refreshSoon(after: 0.15) }
        }
    }
    private(set) var matches: [CGRect] = []
    private(set) var current = 0
    private(set) var reading = false
    /// Where the bar sits, so its own text never counts as a match.
    var barFrame: CGRect = .zero
    /// Bumped on every ⌘F, so the field takes focus and selects its text again.
    private(set) var focusToken = 0

    @ObservationIgnored private var lines: [Line] = []
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pending: DispatchWorkItem?
    /// A read runs; another one waits for it instead of running beside it.
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var stale = false
    /// The screen changed while there was no word to find, so the last read is old.
    @ObservationIgnored private var moved = false

    /// ⌘F, ⌘G and ⇧⌘G go here before any view: the Comments board used ⌘F for Feedback.
    func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return e }
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            switch (e.charactersIgnoringModifiers?.lowercased(), mods) {
            case ("f", .command): self.show(in: e.window ?? NSApp.keyWindow)
            case ("g", .command) where self.open: self.step(1)
            case ("g", [.command, .shift]) where self.open: self.step(-1)
            default: return e
            }
            return nil
        }) { monitors.append(m) }
        // The screen changed under the boxes: read it again once it is still.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp], handler: { [weak self] e in
            guard let self, self.open, e.window === self.window else { return e }
            guard self.searching else { self.moved = true; return e }
            // A click on the bar itself (the arrows) changes nothing under the boxes.
            if e.type == .leftMouseUp, let h = e.window?.contentView?.bounds.height,
               self.barFrame.contains(CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)) { return e }
            self.refreshSoon()
            return e
        }) { monitors.append(m) }
        monitors.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, self.open, (n.object as? NSWindow) === self.window else { return }
            guard self.searching else { self.moved = true; return }
            self.refreshSoon()
        })
    }

    func show(in window: NSWindow?) {
        guard let window, window.contentView != nil else { return }
        self.window = window
        let wasOpen = open
        open = true
        focusToken += 1
        // A fresh bar reads at once, before it is drawn into the window.
        if wasOpen { refreshSoon(after: 0) } else { refresh() }
    }

    func close() {
        open = false
        matches = []
        lines = []
        generation += 1
        stale = false
        moved = false
        pending?.cancel()
        window?.makeFirstResponder(nil)
    }

    func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        current = (current + by + matches.count) % matches.count
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func refreshSoon(after delay: TimeInterval = 0.5) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Snapshot the window on the main thread, read it on a background one.
    private func refresh() {
        guard open else { return }
        if busy { stale = true; return }
        guard let view = window?.contentView, let image = Self.snapshot(view) else { return }
        generation += 1
        let gen = generation, size = view.bounds.size
        busy = true
        stale = false
        reading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let read = Self.read(image, size: size)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if gen == self.generation {
                    self.lines = read
                    self.reading = false
                    self.match(keepPlace: true)
                }
                // The screen moved while this read ran: read it once more.
                if self.stale { self.refreshSoon(after: 0.1) }
            }
        }
    }

    private func match(keepPlace: Bool) {
        let old = matches.indices.contains(current) ? matches[current] : nil
        let bar = barFrame.insetBy(dx: -4, dy: -4)
        matches = Self.matches(of: query, in: lines).filter { !$0.intersects(bar) }
        // After a scroll, stay on the match nearest to the one you were on.
        if keepPlace, let old, !matches.isEmpty {
            current = matches.indices.min { Self.distance(matches[$0], old) < Self.distance(matches[$1], old) } ?? 0
        } else {
            current = 0
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }

    /// Every place the query shows, top to bottom, then left to right. Case and accents don't count.
    static func matches(of query: String, in lines: [Line]) -> [CGRect] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var found: [CGRect] = []
        for line in lines {
            var from = line.text.startIndex
            while let r = line.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<line.text.endIndex) {
                if let box = line.box(r) { found.append(box) }
                from = r.upperBound
            }
        }
        return found.sorted { abs($0.minY - $1.minY) > 4 ? $0.minY < $1.minY : $0.minX < $1.minX }
    }

    /// The view as an opaque image: Vision reads nothing from text on a see-through background.
    static func snapshot(_ view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage,
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        var paper = NSColor.white.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { paper = Theme.paperNS.cgColor }
        let all = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.setFillColor(paper)
        ctx.fill(all)
        ctx.draw(cg, in: all)
        return ctx.makeImage()
    }

    /// Vision's lines, with boxes in view points (Vision measures from the bottom left, 0 to 1).
    static func read(_ image: CGImage, size: CGSize) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast  // about 6x less work than .accurate, and it finds UI text as well
        request.usesLanguageCorrection = false  // find the words as they are written
        request.recognitionLanguages = ["en-US", "de-DE"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { o -> Line? in
            guard let text = o.topCandidates(1).first else { return nil }
            return Line(text: text.string) { r in
                guard let b = try? text.boundingBox(for: r)?.boundingBox else { return nil }
                return CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                              width: b.width * size.width, height: b.height * size.height)
            }
        }
    }
}

/// The boxes and the bar, over the whole window.
struct ScreenFindLayer: View {
    @State private var find = ScreenFind.shared
    @FocusState private var focused: Bool

    var body: some View {
        if find.open {
            ZStack(alignment: .topTrailing) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                ForEach(Array(find.matches.enumerated()), id: \.offset) { i, r in
                    let now = i == find.current
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.warn.opacity(now ? 0.38 : 0.2))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.warn, lineWidth: now ? 2 : 0))
                        .frame(width: r.width + 4, height: r.height + 2)
                        .position(x: r.midX, y: r.midY)
                }
                .allowsHitTesting(false)
                bar
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("screenFind")) } action: { find.barFrame = $0 }
                    .padding(.top, 12).padding(.trailing, 16)
            }
            .coordinateSpace(name: "screenFind")
            .transition(.opacity)
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
            TextField("Find on screen", text: $find.query)
                .textFieldStyle(.plain)
                .font(Theme.sans(13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { find.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); focused = true }
                .onExitCommand { find.close() }
            Text(status).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).monospacedDigit()
            Button { find.step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(find.matches.isEmpty).help("Previous match (⇧⌘G)")
            Button { find.step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).disabled(find.matches.isEmpty).help("Next match (⌘G or Return)")
            Button { find.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close (Esc)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12).frame(height: 34)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 12, y: 4)
        .onAppear { focused = true }
        .onChange(of: find.focusToken) { focused = true; NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
    }

    private var status: String {
        if find.query.trimmingCharacters(in: .whitespaces).isEmpty { return find.reading ? "Reading…" : "" }
        if find.matches.isEmpty { return find.reading ? "Reading…" : "None" }
        return "\(find.current + 1) of \(find.matches.count)"
    }
}
