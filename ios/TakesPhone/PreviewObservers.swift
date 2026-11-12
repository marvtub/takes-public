import Foundation

/// Keeps the two registrations for a video preview together so teardown cannot leave one behind.
final class PreviewObservers {
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private let removeTimeObserver: (Any) -> Void
    private let removeEndObserver: (NSObjectProtocol) -> Void

    init(timeObserver: Any, endObserver: NSObjectProtocol,
         removeTimeObserver: @escaping (Any) -> Void,
         removeEndObserver: @escaping (NSObjectProtocol) -> Void) {
        self.timeObserver = timeObserver
        self.endObserver = endObserver
        self.removeTimeObserver = removeTimeObserver
        self.removeEndObserver = removeEndObserver
    }

    func dismantle() {
        if let timeObserver {
            removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            removeEndObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit { dismantle() }
}
