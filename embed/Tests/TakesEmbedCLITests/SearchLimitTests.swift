import Foundation
import XCTest
@testable import TakesEmbedCLI

final class SearchLimitTests: XCTestCase {
    func testMissingLimitUsesDefault() {
        XCTAssertEqual(parseSearchLimit(nil), 20)
    }

    func testZeroLimitIsAllowed() {
        XCTAssertEqual(parseSearchLimit("0"), 0)
    }

    func testPositiveLimitIsAllowed() {
        XCTAssertEqual(parseSearchLimit("40"), 40)
    }

    func testNegativeLimitIsRejected() {
        XCTAssertNil(parseSearchLimit("-1"))
    }

    func testNonNumericLimitIsRejected() {
        XCTAssertNil(parseSearchLimit("many"))
    }

    func testServeMissingLimitUsesProtocolDefault() {
        XCTAssertEqual(parseServeSearchLimit(nil), 40)
    }

    func testServePositiveLimitIsAllowed() {
        XCTAssertEqual(parseServeSearchLimit(12), 12)
    }

    func testServeNegativeLimitIsRejected() throws {
        let data = Data(#"{"op":"search","query":"hello","limit":-1}"#.utf8)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(parseServeSearchLimit(message["limit"]))
    }
}
