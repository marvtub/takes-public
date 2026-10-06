import Foundation

// Runs without UIKit: swiftc TakesPhone/ChatScrollState.swift tests/ChatScrollStateTests.swift.
@main
struct ChatScrollStateTests {
    static func main() {
        var state = ChatScrollState()
        precondition(state.layoutChanged(distanceFromBottom: 0))
        // A tall reply, keyboard opening/closing, wrapping and a working row are layout changes,
        // not a user's scroll. Stay pinned even when the old offset is now far from the bottom.
        for gap: CGFloat in [600, 340, 0, 1200, 24] {
            precondition(state.layoutChanged(distanceFromBottom: gap))
            precondition(!state.showsLatest)
        }

        state.userScrollStarted()
        precondition(!state.layoutChanged(distanceFromBottom: 0), "Never fight an active drag")
        precondition(!state.layoutChanged(distanceFromBottom: 350))
        precondition(state.showsLatest)
        state.userScrollEnded(distanceFromBottom: 350)
        for gap: CGFloat in [1000, 20, 0, 300] {
            precondition(!state.layoutChanged(distanceFromBottom: gap), "Keep the reader's place")
            precondition(state.showsLatest, "Only the user can resume following")
        }

        state.userScrollStarted()
        precondition(!state.layoutChanged(distanceFromBottom: 44))
        state.userScrollEnded(distanceFromBottom: 44)
        precondition(state.layoutChanged(distanceFromBottom: 400), "Resume at the bottom")
        precondition(!state.showsLatest)
        state.userScrollStarted()
        state.userScrollEnded(distanceFromBottom: 45)
        precondition(state.showsLatest)

        // Latest and sending a message opt back in, including during deceleration.
        state.userScrollStarted()
        state.latest()
        precondition(!state.browsing)
        precondition(state.layoutChanged(distanceFromBottom: 900))
        precondition(!state.showsLatest)
        state.userScrollStarted()
        state.userScrollEnded(distanceFromBottom: -20) // bottom rubber-band
        precondition(state.layoutChanged(distanceFromBottom: 300))
        print("Chat scroll state: all checks passed")
    }
}
