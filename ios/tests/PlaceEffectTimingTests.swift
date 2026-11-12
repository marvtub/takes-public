import Foundation

// Runs without UIKit: swiftc TakesPhone/PlaceEffectTiming.swift tests/PlaceEffectTimingTests.swift.
@main
struct PlaceEffectTimingTests {
    static func main() {
        var selection = PlaceEffectSelection<String>(seconds: 60)
        selection.select("long", duration: 120)
        selection.select("short", duration: 10)
        precondition(selection.target == "short")
        precondition(selection.seconds == 10, "Switching targets invokes the timing clamp")

        var timing = PlaceEffectTiming(seconds: 60)
        timing.selected(duration: 10)
        precondition(timing.seconds == 10, "A shorter duration clamps the effect time")

        timing = PlaceEffectTiming(seconds: 60)
        precondition(timing.submission(duration: 10) == 10, "Submission checks the selected video again")

        timing = PlaceEffectTiming(seconds: 4000)
        precondition(timing.seconds == 3600, "A missing duration keeps the existing one-hour limit")
        timing.selected(duration: .nan)
        precondition(timing.seconds == 0, "An invalid supplied duration cannot submit a later time")

        timing = PlaceEffectTiming(seconds: -1)
        precondition(timing.seconds == 0, "Effect times cannot be negative")
        print("Place effect timing: all checks passed")
    }
}
