// Runs without UIKit: swiftc TakesPhone/ChatUploadState.swift tests/ChatUploadStateTests.swift.
@main
struct ChatUploadStateTests {
    static func main() {
        var state = ChatUploadState()
        state.begin(11, in: "session-a")
        state.begin(22, in: "session-b")

        // Session B appearing must not replace session A's route.
        precondition(state.complete(11, path: "session-a/first.mov"))
        precondition(state.attachments(in: "session-a") == ["session-a/first.mov"])
        precondition(state.attachments(in: "session-b").isEmpty)
        precondition(state.waiting(in: "session-b") == [22])

        precondition(state.complete(22, path: "session-b/second.mov"))
        precondition(state.attachments(in: "session-b") == ["session-b/second.mov"])

        // A repeated completion cannot attach the same upload twice.
        precondition(!state.complete(11, path: "session-a/first.mov"))
        precondition(state.attachments(in: "session-a") == ["session-a/first.mov"])

        // Sending one draft clears only that session. An unfinished file follows the sent message.
        precondition(state.sent(in: "session-a").isEmpty)
        precondition(state.attachments(in: "session-a").isEmpty)
        precondition(state.attachments(in: "session-b") == ["session-b/second.mov"])
        state.begin(33, in: "session-a")
        precondition(state.sent(in: "session-a") == [33])
        precondition(!state.complete(33, path: "session-a/third.mov"))

        print("Chat upload state: all checks passed")
    }
}
