import Foundation

// Runs without UIKit: swiftc TakesPhone/SearchState.swift tests/SearchStateTests.swift.
@main
struct SearchStateTests {
    static func main() {
        let first = SearchRequest(query: "first", filter: "all", project: nil, sort: "best")
        let second = SearchRequest(query: "second", filter: "all", project: nil, sort: "best")
        var state = SearchRequestState<[String]>()

        state.begin(first)
        state.succeed(["first result"], for: first)
        precondition(state.value(for: first) == ["first result"])
        precondition(state.value(for: second) == nil, "Controls must only render their own response")

        state.begin(second)
        precondition(state.value(for: second) == nil, "A new search must hide the previous search's rows")
        state.fail(second)
        precondition(state.value(for: second) == nil, "A failed search must not restore stale rows")
        precondition(state.didFail(second))

        state.succeed(["late first result"], for: first)
        precondition(state.value(for: second) == nil, "A superseded request must not replace the current state")
        precondition(state.didFail(second))
        print("Search state: all checks passed")
    }
}
