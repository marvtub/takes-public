/// Identifies Copilot reloads so only the newest response can change the screen and cache.
struct CopilotLoadOrder {
    private var newest = 0

    mutating func start() -> Int {
        newest += 1
        return newest
    }

    func accepts(_ load: Int) -> Bool { load == newest }
}
