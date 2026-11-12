import Foundation

// Runs without UIKit: swiftc TakesPhone/PreviewObservers.swift tests/PreviewObserversTests.swift.
@main
struct PreviewObserversTests {
    static func main() {
        var removedTimeObservers = 0
        var removedEndObservers = 0
        var activeTimeObservers = Set<ObjectIdentifier>()
        var activeEndObservers = Set<ObjectIdentifier>()

        for _ in 0..<50 {
            let timeObserver = NSObject()
            let endObserver = NSObject()
            activeTimeObservers.insert(ObjectIdentifier(timeObserver))
            activeEndObservers.insert(ObjectIdentifier(endObserver))
            let preview = PreviewObservers(
                timeObserver: timeObserver,
                endObserver: endObserver,
                removeTimeObserver: {
                    activeTimeObservers.remove(ObjectIdentifier($0 as AnyObject))
                    removedTimeObservers += 1
                },
                removeEndObserver: {
                    activeEndObservers.remove(ObjectIdentifier($0))
                    removedEndObservers += 1
                }
            )
            preview.dismantle()
            preview.dismantle()
            precondition(activeTimeObservers.isEmpty, "The preview leaves no time observer registered")
            precondition(activeEndObservers.isEmpty, "The preview leaves no end observer registered")
        }

        precondition(removedTimeObservers == 50, "Every preview removes its time observer once")
        precondition(removedEndObservers == 50, "Every preview removes its end observer once")
        print("Preview observer lifecycle: all checks passed")
    }
}
