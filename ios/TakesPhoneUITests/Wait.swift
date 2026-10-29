import XCTest

// Waits on something the test can see, in place of a fixed sleep: an element's state, the
// stand-in's log, or the screen coming to rest before a screenshot.

extension XCUIElement {
    /// Waits until the element matches a predicate on its own properties, e.g. "label != %@".
    @discardableResult
    func wait(until format: String, _ args: CVarArg..., timeout: TimeInterval = 10) -> Bool {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: self)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    /// Taps the element once it is there and can take the tap.
    func tapWhenReady(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) never showed", file: file, line: line)
        _ = wait(for: \.isHittable, toEqual: true, timeout: timeout)
        tap()
    }
}

/// Polls a check that lives outside the app (the stand-in's log, the server coming back) until it
/// holds or the time is up. Returns whether it held.
@discardableResult
func eventually(timeout: TimeInterval = 10, every: TimeInterval = 0.25, _ check: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !check() {
        if Date() > end { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(every))
    }
    return true
}

extension XCUIApplication {
    /// Waits until the screen stops moving (an animation, a scroll, a picture loading): two
    /// screenshots a quarter second apart look the same. Use it before a screenshot when no one
    /// element marks the end. A screen that never rests (a playing video, a loading shimmer) waits
    /// out the timeout, so keep it at the fixed sleep it replaced: never slower than before.
    func settle(timeout: TimeInterval = 2) {
        var last = Self.thumb()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let now = Self.thumb()
            if Self.same(last, now) { return }
            last = now
        }
    }

    /// The screen at a quarter of its size, as RGBA bytes: small enough to compare fast.
    private static func thumb() -> [UInt8] {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return [] }
        let w = max(cg.width / 4, 1), h = max(cg.height / 4, 1)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Two thumbs match when at most a few pixels differ (a text cursor's blink).
    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        if a == b { return true }
        var off = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var i = 0
                while i < pa.count {
                    if abs(Int(pa[i]) - Int(pb[i])) > 8 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 8
                        || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 8 { off += 1 }
                    i += 4
                }
            }
        }
        return off <= 16
    }
}
