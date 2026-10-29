import XCTest

// The whole suite can share one stand-in (ios/check.sh with no mode). Each test starts from the
// stand-in's first state, so a fixture, a rename or a log line from one test never reaches the
// next (2026-10-28: ten tests failed only in a full run).

extension XCTestCase {
    /// Waits for the stand-in to be up (the last test may have sent it away for up to 40 s), then
    /// resets it. A real Mac answers /test/reset with 404: nothing changes there.
    func freshStandin() {
        let server = ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        func answers(_ path: String) -> Bool {
            let done = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: URL(string: server + path)!) { _, r, _ in
                ok = (r as? HTTPURLResponse) != nil
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 5)
            return ok
        }
        XCTAssertTrue(eventually(timeout: 60, every: 1) { answers("/api/ping") }, "the stand-in never came back")
        _ = answers("/test/reset")
    }
}
