import Foundation

/// Keeps the effect time inside the selected video's known bounds.
struct PlaceEffectTiming {
    private static let unknownDurationLimit = 3600.0
    private(set) var seconds: Double

    init(seconds: Double = 0) {
        self.seconds = Self.clamped(seconds, duration: nil)
    }

    mutating func earlier() {
        seconds = Self.clamped(seconds - 0.5, duration: nil)
    }

    mutating func later(duration: Double?) {
        seconds = Self.clamped(seconds + 0.5, duration: duration)
    }

    mutating func selected(duration: Double?) {
        seconds = Self.clamped(seconds, duration: duration)
    }

    mutating func submission(duration: Double?) -> Double {
        selected(duration: duration)
        return seconds
    }

    private static func clamped(_ seconds: Double, duration: Double?) -> Double {
        guard seconds.isFinite else { return 0 }
        // Older Macs can omit the duration; a supplied invalid duration is unsafe to use.
        let maximum: Double
        if let duration {
            maximum = duration.isFinite && duration >= 0 ? duration : 0
        } else {
            maximum = unknownDurationLimit
        }
        return min(maximum, max(0, seconds))
    }
}

/// Keeps the chosen video and its timing bound together when the target changes.
struct PlaceEffectSelection<Target> {
    private(set) var target: Target?
    private var duration: Double?
    private var timing: PlaceEffectTiming

    var seconds: Double { timing.seconds }

    init(seconds: Double = 0) {
        timing = PlaceEffectTiming(seconds: seconds)
    }

    mutating func earlier() {
        timing.earlier()
    }

    mutating func later() {
        timing.later(duration: duration)
    }

    mutating func select(_ target: Target, duration: Double?) {
        self.target = target
        self.duration = duration
        timing.selected(duration: duration)
    }

    mutating func submission() -> Double {
        timing.submission(duration: duration)
    }
}
