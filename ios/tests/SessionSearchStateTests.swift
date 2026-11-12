// Runs without UIKit: swiftc TakesPhone/SessionSearchState.swift tests/SessionSearchStateTests.swift.
@main
struct SessionSearchStateTests {
    static func main() {
        precondition(
            !SessionSearchState.showsNoMatch(
                query: "Archived video", hasLiveMatches: false, hasArchivedMatches: true
            ),
            "An archived-only result is still a matching session"
        )
        precondition(
            SessionSearchState.showsNoMatch(
                query: "Missing video", hasLiveMatches: false, hasArchivedMatches: false
            )
        )
        precondition(
            !SessionSearchState.showsNoMatch(query: "", hasLiveMatches: false, hasArchivedMatches: false)
        )
        print("Session search state: all checks passed")
    }
}
