struct SessionSearchState {
    static func showsNoMatch(query: String, hasLiveMatches: Bool, hasArchivedMatches: Bool) -> Bool {
        !query.isEmpty && !hasLiveMatches && !hasArchivedMatches
    }
}
