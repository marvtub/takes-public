import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StandinTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandinURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testOnlySuccessfulResponsesAnswer() {
        XCTAssertTrue(standinAnswers(server: "https://x.test", path: "/ok", session: session))
        XCTAssertFalse(standinAnswers(server: "https://x.test", path: "/error", session: session))
        XCTAssertFalse(standinAnswers(server: "https://x.test", path: "/missing", session: session))
    }
}

private final class StandinURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        switch request.url?.path {
        case "/ok": status = 204
        case "/error": status = 500
        default: status = 404
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
