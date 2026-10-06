import Foundation

/// Only a user's scroll changes whether the chat follows replies. Layout changes (including
/// the keyboard) must not mistake a growing reply for a request to read older messages.
struct ChatScrollState {
    private(set) var following = true
    private(set) var browsing = false

    mutating func userScrollStarted() { browsing = true }

    mutating func userScrolled(distanceFromBottom: CGFloat) {
        following = distanceFromBottom <= 44
    }

    mutating func userScrollEnded(distanceFromBottom: CGFloat) {
        userScrolled(distanceFromBottom: distanceFromBottom)
        browsing = false
    }

    mutating func layoutChanged(distanceFromBottom: CGFloat) -> Bool {
        if browsing { userScrolled(distanceFromBottom: distanceFromBottom) }
        return following && !browsing
    }

    mutating func latest() {
        following = true
        browsing = false
    }

    var showsLatest: Bool { !following }
}
