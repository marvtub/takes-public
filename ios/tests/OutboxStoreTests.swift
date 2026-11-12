import Foundation

// Runs without UIKit: swiftc TakesPhone/OutboxStore.swift tests/OutboxStoreTests.swift.
@main
struct OutboxStoreTests {
    enum Failure: Error { case full }

    static func main() throws {
        var values = ["kept"]
        do {
            try OutboxStore.change(&values, persist: { _ in throw Failure.full }) { $0.append("lost") }
            preconditionFailure("A failed save must be reported")
        } catch Failure.full {
            precondition(values == ["kept"], "A failed save must not change the in-memory queue")
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "outbox-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let list = root.appending(path: "saved/ops.json")
        try OutboxStore.change(&values, persist: { try OutboxStore.write($0, to: list) }) { $0.append("durable") }
        let restored = try JSONDecoder().decode([String].self, from: Data(contentsOf: list))
        precondition(values == restored, "A reported change must survive reconstruction")

        let blocked = root.appending(path: "blocked")
        try Data().write(to: blocked)
        do {
            try OutboxStore.write(values, to: blocked.appending(path: "ops.json"))
            preconditionFailure("An unwritable queue must fail")
        } catch {
            precondition(FileManager.default.fileExists(atPath: blocked.path))
        }

        let reply = OutboxAcknowledgement.reply(sent: false, draft: "Keep this draft")
        precondition(reply == .init(draft: "Keep this draft", editing: true, accepted: false),
                     "A failed reply must stay open with its draft")
        precondition(!OutboxAcknowledgement.keeper(sent: false, previous: false, optimistic: true),
                     "A failed keeper change must restore its star")
        precondition(!OutboxAcknowledgement.dismissRecording(kept: false),
                     "A failed take must leave its recording screen open")

        // Recorder leftovers in tmp/outbox: only old take-* and upright-* files go.
        let tmp = root.appending(path: "tmp-outbox")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-2 * 24 * 3600)
        for name in ["take-a.mov", "upright-take-b.mov", "take-new.mov", "1234-phone-take.mov", "send-take-c.mov"] {
            let f = tmp.appending(path: name)
            try Data().write(to: f)
            if name != "take-new.mov" { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path) }
        }
        RecorderLeftovers.remove(in: tmp)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        precondition(left == ["take-new.mov", "1234-phone-take.mov", "send-take-c.mov"],
                     "Only recorder takes older than a day are removed: \(left)")

        print("Outbox store: all checks passed")
    }
}
