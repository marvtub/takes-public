import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The whole suite can share one stand-in (ios/check.sh with no mode). Each test starts from the
// stand-in's first state, so a fixture, a rename or a log line from one test never reaches the
// next (2026-10-28: ten tests failed only in a full run).

private final class StandinAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func standinAnswers(
    server: String,
    path: String,
    session: URLSession = .shared,
    timeout: TimeInterval = 5
) -> Bool {
    guard let url = URL(string: server + path) else { return false }
    let done = DispatchSemaphore(value: 0)
    let answer = StandinAnswer()
    session.dataTask(with: url) { _, response, error in
        if error == nil, let response = response as? HTTPURLResponse {
            answer.set((200..<300).contains(response.statusCode))
        }
        done.signal()
    }.resume()
    guard done.wait(timeout: .now() + timeout) == .success else { return false }
    return answer.value
}

extension XCTestCase {
    /// Waits for the stand-in to be up (the last test may have sent it away for up to 40 s), then
    /// resets it. Set TAKES_REAL_MAC for an explicit run where the server has no reset fixture.
    func freshStandin() {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        let ready = eventually(timeout: 60, every: 1) {
            standinAnswers(server: server, path: "/api/ping")
        }
        XCTAssertTrue(ready, "the stand-in never came back")
        guard ready, environment["TAKES_REAL_MAC"] != "1" else { return }
        XCTAssertTrue(
            standinAnswers(server: server, path: "/test/reset"),
            "the stand-in could not reset"
        )
    }
}
