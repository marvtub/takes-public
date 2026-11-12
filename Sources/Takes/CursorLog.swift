import AppKit
import CoreMedia

// 2026-10-30: the cursor log. While Takes records the screen it notes where the pointer goes, the
// clicks and the app in front, and writes them next to the screen file when the take ends:
//
//   take-01-screen.events.json   (take-01-<name>-screen.events.json once the take is named)
//   {"v": 1, "clock": "video", "source": "display", "size": [3024, 1964], "scale": 2, "fps": 60,
//    "moves":  [[0, 1510.4, 980], [0.017, 1512, 981.5], ...],         [t, x, y], only when it moved
//    "clicks": [{"t": 2.4, "x": 1512, "y": 981.5, "button": "left", "down": true}, ...],
//    "apps":   [{"t": 0, "id": "com.apple.Safari", "name": "Safari"}, ...]}
//
// t is seconds on the .mov's clock (its first frame = 0). x and y are pixels of the .mov frame,
// top-left origin.
//
// 2026-10-30: "pointer": false means the .mov has no pointer in it (showsCursor off). render_edit and
// the stage player draw it back from "moves" with "arrow": the system arrow as a PNG, its hot spot and
// size in points, and "zoom" (the Accessibility pointer size). The file is written every 5 s while
// recording too, so a take that never stops cleanly keeps its pointer.
//
// 2026-10-30: the pointer's shape. "shapes" lists each cursor the screen showed (shapes[0] = the arrow;
// an I-beam, a hand, a resize arrow when they came), read 10 times a second from
// NSCursor.currentSystem (read only), deduped by a hash of the image and hot spot. Each move then
// has its shape: [t, x, y, shape]. A shape change on a still pointer adds a move at the same place.
// Read only: mouse position and buttons, never keys, and nothing that needs Accessibility or
// Input Monitoring. It never moves or makes input.
//
// 2026-10-31: a shape that is one of the system's own cursors has its "name": "arrow", "text" (I-beam),
// "hand" (pointing hand) or "grab" (open or closed hand). The cursor-looks effect reads it as the state.

struct CursorEvents: Codable, Equatable {
    var v = 1
    var clock = "video"
    var source: String  // "display" or "window"
    var size: [Int]     // the .mov frame in pixels
    var scale: Double   // pixels per point
    var fps: Int
    var moves: [[Double]] = []
    var clicks: [Click] = []
    var apps: [App] = []
    var pointer = true  // the .mov shows the pointer
    var arrow: Arrow?
    var shapes: [Arrow]?
    var keys: [Key]?  // shortcuts, only when the pill's ⌨ is on (KeyLog.swift)
    var typing: [[Double]]?  // [start, end] of each run of plain typing, only with ⌨ on; never the keys

    struct Arrow: Codable, Equatable {
        var png: String; var hot: [Double]; var size: [Double]; var zoom: Double
        var name: String? = nil
    }
    struct Click: Codable, Equatable { var t: Double; var x: Double; var y: Double; var button: String; var down: Bool }
    struct App: Codable, Equatable { var t: Double; var id: String; var name: String }
    struct Key: Codable, Equatable { var t: Double; var keys: String }
}

/// Global points (Cocoa: bottom-left of the main screen, y up) to pixels of the .mov frame.
struct CursorMap: Equatable {
    var area: CGRect     // what the .mov shows, in global points with a top-left origin (CGDisplayBounds)
    var mainHeight: Double  // the main screen's height in points, to turn Cocoa's y over
    var size: CGSize     // the .mov frame in pixels

    func pixel(_ p: CGPoint) -> CGPoint {
        let top = mainHeight - p.y
        return CGPoint(x: (p.x - area.minX) * size.width / area.width,
                       y: (top - area.minY) * size.height / area.height)
    }
}

final class CursorLog: @unchecked Sendable {
    static let suffix = ".events.json"

    /// <stem>.events.json next to the screen file.
    static func file(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("events.json")
    }

    /// Host clock seconds (mach time): the clock of ScreenCaptureKit's frames and of NSEvent.timestamp.
    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private struct Raw {
        var moves: [(Double, CGPoint)] = []; var clicks: [(Double, CGPoint, String, Bool)] = []
        var apps: [(Double, String, String)] = []; var keys: [(Double, String)]? = nil
        var typing: [[Double]]? = nil  // host-time runs, closed as they go: each key's time is never kept
        var shapes: [(Double, Int)] = []  // (t, shape id) at each change
    }

    let url: URL
    private var head: CursorEvents
    private var map: CursorMap
    private let windowID: CGWindowID?
    private var raw = Raw()
    private var first: Double?  // host time of the first frame
    private let began = CursorLog.now()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "takes.cursor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var last: CGPoint?
    private var ticks = 0
    private var stopped = false
    private var saver: DispatchSourceTimer?
    private var keyTap: (CFMachPort, CFRunLoopSource)?
    private var looker: DispatchSourceTimer?
    private var shapeIDs: [Int: Int] = [:]  // the hash of a cursor's look -> its id in head.shapes (main thread)
    private var shapeNames: [Int: String] = [:]  // the hash of a system cursor's look -> its name (main thread)
    private var shapeNow = 0
    static let maxShapes = 24  // an animated cursor (the spinning wait) stops adding new ones here
    /// Told on the main thread whether the shortcuts are being noted (the tap is on).
    var onKeys: ((Bool) -> Void)?

    /// arrow: Takes draws the pointer from this log, so the .mov leaves it out. nil: the .mov shows it.
    init(video: URL, map: CursorMap, source: String, scale: Double, fps: Int, windowID: CGWindowID? = nil,
         arrow: CursorEvents.Arrow? = nil, keys: Bool = false) {
        url = Self.file(for: video)
        self.map = map
        self.windowID = windowID
        head = CursorEvents(source: source, size: [Int(map.size.width), Int(map.size.height)], scale: scale, fps: fps)
        head.pointer = arrow == nil
        head.arrow = arrow
        head.shapes = arrow.map { var a = $0; a.name = "arrow"; return [a] }
        if keys { raw.keys = []; raw.typing = [] }
    }

    /// The system arrow as the screen shows it: drawn at 4x, its hot spot (top-left origin) and size in
    /// points, and the pointer size from Accessibility. nil if it cannot be drawn.
    @MainActor static func arrow() -> CursorEvents.Arrow? { shape(.arrow) }

    /// Any cursor, drawn the same way.
    @MainActor static func shape(_ c: NSCursor) -> CursorEvents.Arrow? {
        let img = c.image, size = img.size, k = 4.0
        guard size.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * k), pixelsHigh: Int(size.height * k), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let zoom = UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 0
        return .init(png: png.base64EncodedString(), hot: [c.hotSpot.x, c.hotSpot.y],
                     size: [size.width, size.height], zoom: zoom >= 1 ? zoom : 1)
    }

    /// What tells two cursors apart: their image's pixels and hot spot.
    @MainActor static func look(_ c: NSCursor) -> Int? {
        guard let cg = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data as Data? else { return nil }
        var h = Hasher()
        h.combine(data)
        h.combine(cg.width)
        h.combine(c.hotSpot.x)
        h.combine(c.hotSpot.y)
        return h.finalize()
    }

    /// The cursor on screen now (main thread). A new look gets an id; a change notes a move here.
    @MainActor private func lookShape() {
        guard let c = NSCursor.currentSystem, let k = Self.look(c) else { return }
        var id = shapeIDs[k]
        if id == nil {
            guard (head.shapes?.count ?? 0) < Self.maxShapes, var a = Self.shape(c) else { return }
            a.name = shapeNames[k]
            id = lock.withLock { () -> Int in head.shapes?.append(a); return (head.shapes?.count ?? 1) - 1 }
            shapeIDs[k] = id
        }
        guard let id, id != shapeNow else { return }
        shapeNow = id
        let t = Self.now(), p = NSEvent.mouseLocation
        lock.withLock {
            raw.shapes.append((t, id))
            raw.moves.append((t, map.pixel(p)))
        }
    }

    /// The first frame's host time, from the stream. The first call wins.
    func frame(at t: Double) {
        lock.withLock { if first == nil { first = t } }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        // A take without the pointer in its video needs this file: write it every 5 s, not only at the end.
        if head.arrow != nil {
            let w = DispatchSource.makeTimerSource(queue: queue)
            w.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            w.setEventHandler { [weak self] in self?.write() }
            w.resume()
            saver = w
        }
        t.resume()
        timer = t
        DispatchQueue.main.async { [self] in
            guard !stopped else { return }
            let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.click(e) }) { monitors.append(g) }
            // Clicks on Takes' own windows (the screen pill) do not reach the global monitor.
            if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in self?.click(e); return e }) { monitors.append(l) }
            if raw.keys != nil { keyTap = KeyLog.tap(self); onKeys?(keyTap != nil) }
            if head.shapes != nil {
                if let k = MainActor.assumeIsolated({ Self.look(.arrow) }) { shapeIDs[k] = 0 }
                MainActor.assumeIsolated {
                    let known: [(NSCursor, String)] = [(.arrow, "arrow"), (.iBeam, "text"), (.iBeamCursorForVerticalLayout, "text"),
                                                       (.pointingHand, "hand"), (.openHand, "grab"), (.closedHand, "grab")]
                    for (c, n) in known { if let k = Self.look(c) { shapeNames[k] = n } }
                }
                let l = DispatchSource.makeTimerSource(queue: .main)
                l.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
                l.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.lookShape() } }
                l.resume()
                looker = l
            }
            if let a = NSWorkspace.shared.frontmostApplication { app(a) }
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.app(a) }
            }
        }
    }

    /// Stops listening and writes the file, atomically. Safe to call once; later calls do nothing.
    func finish() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        saver?.cancel()
        saver = nil
        let done = DispatchSemaphore(value: 0)
        let stop = { [self] in
            stopped = true
            looker?.cancel()
            looker = nil
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
            observer = nil
            if let (port, src) = keyTap {
                CGEvent.tapEnable(tap: port, enable: false)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                CFMachPortInvalidate(port)
            }
            keyTap = nil
            done.signal()
        }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.async(execute: stop); done.wait() }
        queue.sync {}  // the last tick and the last save
        write()
    }

    private func write() {
        let doc = lock.withLock { () -> CursorEvents in
            Self.events(head, raw: raw, start: first ?? began)
        }
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Samples

    private func tick() {
        ticks += 1
        // A window can move: look up where it is four times a second.
        if let id = windowID, ticks % 15 == 1, let r = Self.bounds(of: id) {
            lock.withLock { map.area = r }
        }
        let p = NSEvent.mouseLocation
        guard p != last else { return }
        last = p
        let t = Self.now()
        lock.withLock { raw.moves.append((t, map.pixel(p))) }
    }

    private func click(_ e: NSEvent) {
        let p = e.window.map { $0.convertPoint(toScreen: e.locationInWindow) } ?? e.locationInWindow
        let now = Self.now()
        let t = abs(e.timestamp - now) < 1 ? e.timestamp : now
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type)
        let button = e.buttonNumber == 0 ? "left" : e.buttonNumber == 1 ? "right" : "other"
        lock.withLock { raw.clicks.append((t, map.pixel(p), button, down)) }
    }

    /// A shortcut from the key tap (main thread).
    func key(_ s: String) {
        let t = Self.now()
        lock.withLock { raw.keys?.append((t, s)) }
    }

    /// Keys less than this apart are one run of typing.
    static let typingGap = 1.5

    /// A plain key press from the key tap (main thread): it starts a run of typing or makes the last one longer.
    func typed() {
        let t = Self.now()
        lock.withLock { raw.typing = Self.typed(raw.typing, at: t) }
    }

    static func typed(_ runs: [[Double]]?, at t: Double) -> [[Double]]? {
        guard var runs else { return nil }
        if let last = runs.last, t - last[1] < typingGap { runs[runs.count - 1][1] = max(last[1], t) } else { runs.append([t, t]) }
        return runs
    }

    /// macOS turns a slow tap off; it goes back on.
    func reenableKeys() {
        if let port = keyTap?.0 { CGEvent.tapEnable(tap: port, enable: true) }
    }

    private func app(_ a: NSRunningApplication) {
        let t = Self.now()
        lock.withLock {
            if raw.apps.last?.1 == (a.bundleIdentifier ?? "") { return }
            raw.apps.append((t, a.bundleIdentifier ?? "", a.localizedName ?? ""))
        }
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let b = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    // MARK: The file

    /// Host times to the video's clock. What came before the first frame starts it at 0: the last
    /// position and the app in front. Clicks before it are dropped.
    static func events(_ head: CursorEvents, raw: (moves: [(Double, CGPoint)], clicks: [(Double, CGPoint, String, Bool)], apps: [(Double, String, String)]),
                       start: Double) -> CursorEvents {
        func ms(_ t: Double) -> Double { (max(0, t - start) * 1000).rounded() / 1000 }
        func px(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        var e = head
        let moves = raw.moves[(raw.moves.lastIndex { $0.0 <= start } ?? 0)...]
        e.moves = moves.map { [ms($0.0), px($0.1.x), px($0.1.y)] }
        e.clicks = raw.clicks.filter { $0.0 >= start }.map { .init(t: ms($0.0), x: px($0.1.x), y: px($0.1.y), button: $0.2, down: $0.3) }
        let apps = raw.apps[(raw.apps.lastIndex { $0.0 <= start } ?? 0)...]
        e.apps = apps.map { .init(t: ms($0.0), id: $0.1, name: $0.2) }
        return e
    }

    private static func events(_ head: CursorEvents, raw: Raw, start: Double) -> CursorEvents {
        // Moves come from two threads (the timer, a shape change): in time order first.
        let moves = raw.moves.sorted { $0.0 < $1.0 }
        var e = events(head, raw: (moves, raw.clicks, raw.apps), start: start)
        if head.shapes != nil {
            let from = moves.lastIndex { $0.0 <= start } ?? 0
            e.moves = zip(e.moves, shapes(at: moves[from...].map(\.0), raw.shapes)).map { $0 + [Double($1)] }
        }
        e.keys = raw.keys.map { keys in keys.filter { $0.0 >= start }.map { .init(t: ms($0.0, start), keys: $0.1) } }
        e.typing = raw.typing.map { runs in runs.filter { $0[1] >= start }.map { [ms($0[0], start), ms($0[1], start)] } }
        return e
    }

    /// The shape id at each host time (sorted): the last change at or before it, else the arrow (0).
    static func shapes(at times: [Double], _ changes: [(Double, Int)]) -> [Int] {
        var i = 0, now = 0
        return times.map { t in
            while i < changes.count, changes[i].0 <= t + 1e-9 { now = changes[i].1; i += 1 }
            return now
        }
    }

    private static func ms(_ t: Double, _ start: Double) -> Double { (max(0, t - start) * 1000).rounded() / 1000 }
}
