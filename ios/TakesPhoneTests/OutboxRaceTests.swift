import Combine
import Foundation
import XCTest
@testable import Takes  // the app target's PRODUCT_NAME (and so its module) is Takes

final class OutboxRaceTests: XCTestCase {
    @MainActor
    func testConflictingOnlineChangesReachServerInSubmissionOrder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "OutboxRaceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstArrived = expectation(description: "archive-on reached the server")
        let secondArrived = expectation(description: "archive-off reached the server")
        let server = ArchiveServer { count in
            if count == 1 { firstArrived.fulfill() }
            if count == 2 { secondArrived.fulfill() }
        }
        let model = Model(outboxDirectory: folder)
        model.outbox.rawForTesting = { request in try await server.receive(request) }
        model.prepareOutboxTest()

        let first = Outbox.Op(.archive, session: "Tests/video", path: "/api/archive",
                              query: ["id": "Tests/video", "on": "1"])
        let second = Outbox.Op(.archive, session: "Tests/video", path: "/api/archive",
                               query: ["id": "Tests/video", "on": "0"])

        let firstSend = Task { try await model.outbox.send(first) }
        await fulfillment(of: [firstArrived], timeout: 10)
        XCTAssertEqual(model.outbox.ops.map(\.id), [first.id], "The in-flight change must already be durable")

        let secondResult = try await model.outbox.send(second)
        guard case .queued(let queued) = secondResult else {
            return XCTFail("The conflicting change must wait behind the first request")
        }
        XCTAssertEqual(queued.id, second.id)
        XCTAssertEqual(model.outbox.ops.map(\.id), [first.id, second.id])
        let beforeRelease = await server.snapshot()
        XCTAssertEqual(beforeRelease.arrivals, [first.id], "The second request reached the server before the first finished")

        let drained = expectation(description: "both durable changes left the outbox")
        let drain = model.outbox.$ops.dropFirst().sink { ops in
            if ops.isEmpty { drained.fulfill() }
        }
        await server.releaseFirst()
        guard case .now = try await firstSend.value else {
            drain.cancel()
            return XCTFail("The first online change should finish immediately")
        }
        await fulfillment(of: [secondArrived, drained], timeout: 10)
        drain.cancel()

        let finished = await server.snapshot()
        XCTAssertEqual(finished.arrivals, [first.id, second.id])
        XCTAssertFalse(finished.archived, "The later archive-off change must own the final state")
        XCTAssertTrue(model.outbox.ops.isEmpty)
    }
}

private actor ArchiveServer {
    struct Snapshot {
        var arrivals: [UUID]
        var archived: Bool
    }

    private var arrivals: [UUID] = []
    private var archived = false
    private var firstResponse: CheckedContinuation<Void, Never>?
    private let arrived: @Sendable (Int) -> Void

    init(arrived: @escaping @Sendable (Int) -> Void) {
        self.arrived = arrived
    }

    func receive(_ request: URLRequest) async throws -> Data {
        guard let value = request.value(forHTTPHeaderField: "X-Takes-Op"), let id = UUID(uuidString: value),
              let url = request.url,
              let on = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "on" })?.value else {
            throw URLError(.badURL)
        }
        let position = arrivals.count
        arrivals.append(id)
        arrived(arrivals.count)
        // Hold archive-on before applying it. Without serialization archive-off can apply first,
        // then this late request wrongly leaves the video archived (issue #41).
        if position == 0 {
            await withCheckedContinuation { firstResponse = $0 }
        }
        archived = on == "1"
        return Data("{}".utf8)
    }

    func releaseFirst() {
        firstResponse?.resume()
        firstResponse = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(arrivals: arrivals, archived: archived)
    }
}
