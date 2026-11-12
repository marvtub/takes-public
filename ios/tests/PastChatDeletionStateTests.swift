// Runs without UIKit: swiftc TakesPhone/PastChatDeletionState.swift tests/PastChatDeletionStateTests.swift.
@main
struct PastChatDeletionStateTests {
    struct Chat: Equatable {
        let id: String
    }

    static func main() {
        var state = PastChatDeletionState()
        var items: [Chat]? = [Chat(id: "keep"), Chat(id: "delete")]

        precondition(state.begin("delete"))
        precondition(!state.begin("delete"), "A pending deletion cannot be sent twice")
        state.finish("delete", succeeded: false, items: &items, itemID: \.id)
        precondition(items == [Chat(id: "keep"), Chat(id: "delete")], "A failed deletion stays visible")

        precondition(state.begin("delete"), "A failed deletion can be retried")
        state.finish("delete", succeeded: true, items: &items, itemID: \.id)
        precondition(items == [Chat(id: "keep")], "Only a successful deletion hides the conversation")
        print("Past chat deletion state: all checks passed")
    }
}
